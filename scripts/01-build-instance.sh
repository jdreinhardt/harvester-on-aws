#!/bin/bash
set -euo pipefail

# =============================================================================
# Phase 1: Build a "pre-installed" Harvester raw disk image with QEMU
#
# This produces the exact artifact Harvester itself calls a pre-installed disk
# image: a fully laid out set of partitions with the OS images written, but
# with NO cluster configuration -- no rancherd config, no bootstrap resources,
# no NetworkManager profiles, no hostname.
#
# That is what `harvester.install.mode=install` means. From harvester-installer
# pkg/config/cos.go:
#
#     if cfg.Install.Mode != ModeInstall {
#         initRancherdStage(...)              // rancherd cfg + bootstrap resources
#         initramfs.Hostname = ...
#         UpdateManagementInterfaceConfig(...) // mgmt-bo bond + mgmt-br bridge
#     }
#
# On first boot the installer notices `mode: install` in /oem/harvester.config,
# sets alreadyInstalled=true, reads /oem/userdata.yaml, and -- if that file sets
# `install.automatic: true` -- non-interactively runs configureInstalledNode(),
# which generates the rancherd config and every bootstrap resource and restarts
# rancherd. That is the supported path to a real cluster, and it is what phases
# 2 and 3 wire up for EC2.
#
# Do NOT "fix" this by switching to mode=create here. mode=create bakes the VIP,
# hostname and token into the image at build time, which makes the AMI
# single-use.
#
# Prerequisites:
#   - qemu-system-x86_64 (amd64) or qemu-system-aarch64 (arm64), with KVM
#   - UEFI firmware: OVMF on amd64, AAVMF/edk2-aarch64 on arm64. UEFI only --
#     Harvester dropped legacy BIOS support, and AWS needs an ESP at
#     /EFI/BOOT/BOOTX64.EFI (amd64) or /EFI/BOOT/BOOTAA64.EFI (arm64) to boot
#     the AMI. Phase 2 normalises that name.
#   - Harvester ISO, vmlinuz and initrd for the target arch in ./artifacts/
#   - openssl (to hash the OS password -- see note below)
#
# Architecture is taken from the host, because --enable-kvm cannot cross-
# emulate: an arm64 image has to be built on an arm64 machine. On AWS that
# means a Graviton *bare metal* instance, since no virtualized Graviton type
# offers nested virtualization.
#
# While QEMU is running the terminal belongs to the guest serial console.
# Ctrl-C goes to the guest; to abort the build press Ctrl-A then X.
# =============================================================================

HARVESTER_VERSION="${HARVESTER_VERSION:-v1.9.0}"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-./artifacts}"

# --- Architecture ---------------------------------------------------------
# KVM cannot cross-emulate, so the guest arch is the host arch. ARCH exists as
# an override only so the failure is a clear message rather than a confusing
# QEMU error.
HOST_ARCH="$(uname -m)"
case "$HOST_ARCH" in
    x86_64|amd64)  HOST_ARCH="amd64" ;;
    aarch64|arm64) HOST_ARCH="arm64" ;;
    *) echo "ERROR: unsupported host architecture: ${HOST_ARCH}" >&2; exit 1 ;;
esac
ARCH="${ARCH:-$HOST_ARCH}"

if [ "$ARCH" != "$HOST_ARCH" ]; then
    echo "ERROR: ARCH=${ARCH} but this host is ${HOST_ARCH}." >&2
    echo "       The install runs under KVM, which cannot emulate a foreign" >&2
    echo "       architecture. Build ${ARCH} images on an ${ARCH} machine." >&2
    exit 1
fi

# Per-architecture QEMU and firmware settings.
#
#   machine   aarch64 has no q35. Its `virt` machine also cannot fall back to
#             GICv2 on a Graviton host -- the host kernel reports
#             "GICv3: no GICV resource entry / disabling GICv2 emulation" --
#             so gic-version=3 is required, not preferred.
#   cpu       +topoext is an AMD SMT topology flag with no aarch64 equivalent.
#   tty       QEMU's `virt` machine provides a PL011 at ttyAMA0; q35 provides a
#             16550 at ttyS0. This is the BUILD console only. The installed
#             system's console is set by phase 2, and on EC2 that is ttyS0 for
#             both architectures -- Nitro presents a 16550 even on Graviton.
#   pflash    See the padding note further down.
case "$ARCH" in
    amd64)
        QEMU_BIN="qemu-system-x86_64"
        QEMU_MACHINE="q35,smm=off"
        QEMU_CPU="host,+topoext"
        GUEST_TTY="ttyS0"
        # biosdevname is a Dell x86 NIC-naming scheme; no aarch64 equivalent.
        EXTRA_KARGS="biosdevname=0"
        # OVMF paths -- adjust for your distro
        #   openSUSE:  /usr/share/qemu/ovmf-x86_64-code.bin  or  /usr/share/OVMF/x64/OVMF_CODE.4m.fd
        #   Fedora:    /usr/share/edk2/ovmf/OVMF_CODE.fd
        #   Debian:    /usr/share/OVMF/OVMF_CODE_4M.fd
        FW_CODE_DEFAULT="/usr/share/OVMF/x64/OVMF_CODE.4m.fd"
        FW_VARS_DEFAULT="/usr/share/OVMF/x64/OVMF_VARS.4m.fd"
        FW_PFLASH_SIZE=0
        ;;
    arm64)
        QEMU_BIN="qemu-system-aarch64"
        QEMU_MACHINE="virt,gic-version=3"
        QEMU_CPU="host"
        GUEST_TTY="ttyAMA0"
        EXTRA_KARGS=""
        # AAVMF paths -- adjust for your distro
        #   AL2023/Fedora: /usr/share/edk2/aarch64/QEMU_EFI.fd
        #   Debian/Ubuntu: /usr/share/AAVMF/AAVMF_CODE.fd
        FW_CODE_DEFAULT="/usr/share/edk2/aarch64/QEMU_EFI.fd"
        FW_VARS_DEFAULT="/usr/share/edk2/aarch64/QEMU_VARS.fd"
        FW_PFLASH_SIZE=67108864   # 64 MiB, exactly
        ;;
    *)
        echo "ERROR: unsupported ARCH: ${ARCH} (expected amd64 or arm64)" >&2
        exit 1
        ;;
esac

# The INSTALLED system's console, which is NOT the same as GUEST_TTY above.
#
#   GUEST_TTY   where the build-time installer TUI and kernel messages go,
#               under QEMU. Per-arch: q35 gives a 16550 at ttyS0, virt gives a
#               PL011 at ttyAMA0.
#   TARGET_TTY  what harvester.install.tty becomes -- HARVESTER_TTY, which
#               harv-install's update_grub_settings() writes into
#               /etc/cos/bootargs.cfg on the installed system. That system
#               boots on EC2, not under QEMU, and Nitro presents a 16550 as
#               ttyS0 on Graviton as well as x86 (confirmed from /proc/cmdline
#               on a c6g.metal instance). So this is ttyS0 for both arches.
#
# These coincide on amd64, which is why a single value worked until arm64.
# Passing GUEST_TTY here bakes ttyAMA0 into /oem/harvester.config, which then
# disagrees with the bootargs phase 2 writes -- harmless until something
# regenerates them from the config, at which point the console disappears.
TARGET_TTY="ttyS0"

PROJECT_PREFIX="harvester-${HARVESTER_VERSION}"
RAW_IMAGE_NAME="${PROJECT_PREFIX}-${ARCH}.raw"
ISO_PATH="${ARTIFACTS_DIR}/${PROJECT_PREFIX}-${ARCH}.iso"
VMLINUZ_PATH="${ARTIFACTS_DIR}/${PROJECT_PREFIX}-vmlinuz-${ARCH}"
INITRD_PATH="${ARTIFACTS_DIR}/${PROJECT_PREFIX}-initrd-${ARCH}"
RAW_IMAGE_PATH="${ARTIFACTS_DIR}/${RAW_IMAGE_NAME}"
INSTALL_LOG="${ARTIFACTS_DIR}/harvester-install-console.log"

# The Makefile passes these in as OVMF_* for both architectures; on arm64 they
# point at AAVMF/edk2-aarch64 images despite the name.
OVMF_CODE="${OVMF_CODE:-$FW_CODE_DEFAULT}"
OVMF_VARS_TEMPLATE="${OVMF_VARS_TEMPLATE:-$FW_VARS_DEFAULT}"
# Per-arch so amd64 and arm64 builds can share an artifacts directory.
OVMF_LOCAL_VARS="${ARTIFACTS_DIR}/uefi-vars-${ARCH}.fd"

# 250 GiB is the minimum Harvester accepts for a single-disk install
# (config.SingleDiskMinSizeGiB). Keep this EXACTLY equal to the EBS volume size
# you register the AMI with: dd'ing a smaller image onto a larger volume leaves
# the GPT backup header stranded mid-disk, which is the "partition corruption"
# the old readme worked around by padding the volume by 1 GiB.
DISK_SIZE_GIB="${DISK_SIZE_GIB:-250}"

# COS_PERSISTENT size. Whatever is left over becomes HARV_LH_DEFAULT, the
# Longhorn data partition.
PERSISTENT_SIZE="${PERSISTENT_SIZE:-150Gi}"

# The install is not a light workload: harv-install's preload_rke2_images()
# starts a real RKE2 server in a chroot and imports several GB of container
# images through containerd. Harvester's own CI sizes these VMs at 8 vCPU /
# 16 GiB (ipxe-examples/vagrant-pxe-harvester/settings.yml). Less than that
# tends to fail during "Load images from ..." with soft lockups rather than a
# clean error.
MEMORY_MIB="${MEMORY_MIB:-16384}"
SMP="${SMP:-cores=8,threads=1,sockets=1}"

# Abort rather than hang forever if the install wedges. A healthy run is well
# under 30 minutes. Set to 0 to disable.
QEMU_TIMEOUT="${QEMU_TIMEOUT:-3600}"

# NOTE: os.password is written verbatim into /etc/shadow. Nothing in the
# non-interactive install path hashes it -- harvester-installer only calls
# util.GetEncryptedPasswd() from the interactive TUI, and yip's user plugin
# assigns schema.User.PasswordHash straight through. Passing a plaintext
# password here silently produces an unusable shadow entry. So hash it.
OS_PASSWORD="${OS_PASSWORD:-rancher}"
OS_PASSWORD_HASH="${OS_PASSWORD_HASH:-}"

FORCE="false"
DEVICE=""

usage() {
    cat <<USAGE
Usage: $0 [--force] [--device /dev/nvmeXn1]

  --force       Rebuild even if ${RAW_IMAGE_PATH} already exists.
  --device DEV  Install straight onto a block device instead of a raw file.
                This is what the Makefile does on the helper instance: QEMU
                writes the install directly to the EBS volume that will be
                snapshotted, so there is no image file, no zstd, and no S3
                round trip -- phases 1 and 1.5 collapse into one step.
                Requires root, and the device must be at least
                ${DISK_SIZE_GIB} GiB. --force is not needed (and is ignored):
                the device is written unconditionally.
                Without this the script refuses to overwrite a previous build.

Environment overrides:
  HARVESTER_VERSION   default ${HARVESTER_VERSION}
  ARCH                default ${ARCH} (from the host; amd64 or arm64)
  ARTIFACTS_DIR       default ${ARTIFACTS_DIR}
  DISK_SIZE_GIB       default ${DISK_SIZE_GIB}
  PERSISTENT_SIZE     default ${PERSISTENT_SIZE}
  MEMORY_MIB          default ${MEMORY_MIB}
  SMP                 default ${SMP}
  QEMU_TIMEOUT        default ${QEMU_TIMEOUT} seconds (0 disables)
  OS_PASSWORD         default ${OS_PASSWORD}
  OS_PASSWORD_HASH    a SHA-512 crypt hash, used instead of hashing OS_PASSWORD
  OVMF_CODE           default ${OVMF_CODE}
  OVMF_VARS_TEMPLATE  default ${OVMF_VARS_TEMPLATE}
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --force|-f) FORCE="true"; shift ;;
        --device)   DEVICE="$2"; shift 2 ;;
        -h|--help)  usage; exit 0 ;;
        *)          echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
done

echo "=== Phase 1: Build pre-installed Harvester raw image (${HARVESTER_VERSION}, ${ARCH}) ==="
echo ""

# --- Validation ---
for f in "$ISO_PATH" "$VMLINUZ_PATH" "$INITRD_PATH" "$OVMF_CODE"; do
    if [ ! -f "$f" ]; then
        echo "ERROR: Required file not found: $f" >&2
        exit 1
    fi
done

command -v "$QEMU_BIN" >/dev/null || { echo "ERROR: ${QEMU_BIN} not found" >&2; exit 1; }
command -v qemu-img          >/dev/null || { echo "ERROR: qemu-img not found" >&2; exit 1; }
[ -n "$DEVICE" ] || command -v zstd >/dev/null || { echo "ERROR: zstd not found" >&2; exit 1; }

if [ ! -w /dev/kvm ]; then
    echo "ERROR: /dev/kvm is not writable. The Harvester installer preloads" >&2
    echo "       container images by running RKE2 in a chroot; it needs KVM." >&2
    exit 1
fi

# Do not silently destroy a previous build. A failed *script* does not
# necessarily mean a failed *install* -- if the installer powered the VM off,
# the image on disk is good even if a later step errored out.
if [ -n "$DEVICE" ]; then
    # --- installing straight onto a block device --------------------------
    [ "$(id -u)" -eq 0 ] || { echo "ERROR: --device needs root." >&2; exit 1; }
    [ -b "$DEVICE" ] || { echo "ERROR: $DEVICE is not a block device." >&2; exit 1; }

    # Never scribble on the machine doing the building.
    ROOT_SRC="$(findmnt -no SOURCE / 2>/dev/null || true)"
    if [ -n "$ROOT_SRC" ]; then
        ROOT_DISK="/dev/$(lsblk -no pkname "$ROOT_SRC" 2>/dev/null || true)"
        if [ "$ROOT_DISK" = "$DEVICE" ]; then
            echo "ERROR: $DEVICE is this machine's root disk. Refusing." >&2
            exit 1
        fi
    fi
    if lsblk -no MOUNTPOINT "$DEVICE" 2>/dev/null | grep -q .; then
        echo "ERROR: $DEVICE has mounted partitions. Unmount them first." >&2
        exit 1
    fi

    DEV_BYTES="$(lsblk --bytes --nodeps --noheadings --output SIZE "$DEVICE" | tr -d ' ')"
    NEED_BYTES=$(( DISK_SIZE_GIB * 1073741824 ))
    if [ "${DEV_BYTES:-0}" -lt "$NEED_BYTES" ]; then
        echo "ERROR: $DEVICE is $(( DEV_BYTES / 1073741824 )) GiB; need at least ${DISK_SIZE_GIB}." >&2
        exit 1
    fi

    TARGET="$DEVICE"
    echo "Installing directly onto ${DEVICE} ($(( DEV_BYTES / 1073741824 )) GiB)."
    echo "Everything currently on it will be destroyed."
    echo ""
elif [ -e "$RAW_IMAGE_PATH" ] && [ "$FORCE" != "true" ]; then
    echo "ERROR: $RAW_IMAGE_PATH already exists." >&2
    echo "" >&2
    echo "       If the previous run got as far as 'Powering off.' on the guest" >&2
    echo "       console, that image is a completed install and you can just" >&2
    echo "       compress it:" >&2
    echo "         zstd -T0 --force $RAW_IMAGE_PATH" >&2
    echo "" >&2
    echo "       To discard it and rebuild from scratch, re-run with --force." >&2
    exit 1
fi

# --- Resource sanity ---
if [ -r /proc/meminfo ]; then
    HOST_MIB="$(awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo)"
    echo "Host memory: ${HOST_MIB} MiB; guest will use ${MEMORY_MIB} MiB"
    if [ "$MEMORY_MIB" -gt $(( HOST_MIB * 3 / 4 )) ]; then
        echo "  WARNING: the guest is asking for more than 3/4 of host RAM." >&2
        echo "           Lower MEMORY_MIB, or expect swapping." >&2
    fi
    if [ "$MEMORY_MIB" -lt 12288 ]; then
        echo "  WARNING: below ~12 GiB the image preload step tends to fail with" >&2
        echo "           'Importing elapsed: ... 0.0 B (0.0 B/s)' and soft lockups." >&2
    fi
fi

if [ -z "$OS_PASSWORD_HASH" ]; then
    if ! command -v openssl >/dev/null; then
        echo "ERROR: openssl not found and OS_PASSWORD_HASH not set." >&2
        echo "       Set OS_PASSWORD_HASH to a SHA-512 crypt hash, e.g." >&2
        echo "         OS_PASSWORD_HASH=\$(mkpasswd -m sha-512 'yourpassword')" >&2
        exit 1
    fi
    OS_PASSWORD_HASH="$(openssl passwd -6 "$OS_PASSWORD")"
    echo "Generated SHA-512 crypt hash for the '${OS_PASSWORD}' console password."
fi

case "$OS_PASSWORD_HASH" in
    '$6$'*) : ;;
    *)
        echo "ERROR: OS_PASSWORD_HASH does not look like a SHA-512 crypt hash." >&2
        echo "       It is written straight to /etc/shadow; a plaintext value" >&2
        echo "       disables password login rather than setting it." >&2
        exit 1
        ;;
esac

mkdir -p "${ARTIFACTS_DIR}"

# --- UEFI firmware images -------------------------------------------------
#
# The variable store always needs a writable copy. On aarch64 BOTH pflash
# images additionally have to be padded to exactly 64 MiB, because the `virt`
# machine declares two fixed-size flash banks and refuses anything else:
#
#   cfi.pflash01 device '/machine/virt.flash0' requires 67108864 bytes,
#   pflash0 block backend provides 3145728 bytes
#
# Distro edk2-aarch64 packages ship a 3 MiB code image and a 768 KiB variable
# store, so both are rejected as shipped. x86's q35 sizes its pflash to the
# backing file, which is why the amd64 path never needed this.
#
# The padded copies live in ARTIFACTS_DIR rather than overwriting the packaged
# files, which a package update would revert anyway.
install_pflash() {
    # $1 = source, $2 = destination. Pads when FW_PFLASH_SIZE is non-zero.
    local src="$1" dst="$2"
    cp "$src" "$dst"
    if [ "$FW_PFLASH_SIZE" -gt 0 ]; then
        truncate -s "$FW_PFLASH_SIZE" "$dst"
    fi
}

# A copy left over from an interrupted run may be the wrong size; regenerate
# rather than handing QEMU something it will reject.
pflash_ok() {
    [ -f "$1" ] || return 1
    [ "$FW_PFLASH_SIZE" -eq 0 ] && return 0
    [ "$(wc -c < "$1" 2>/dev/null || echo 0)" -eq "$FW_PFLASH_SIZE" ]
}

if [ "$FW_PFLASH_SIZE" -gt 0 ]; then
    command -v truncate >/dev/null || {
        echo "ERROR: truncate not found; needed to pad ${ARCH} pflash images." >&2
        exit 1
    }
    FW_CODE="${ARTIFACTS_DIR}/uefi-code-${ARCH}.fd"
    pflash_ok "$FW_CODE" || install_pflash "$OVMF_CODE" "$FW_CODE"
else
    FW_CODE="$OVMF_CODE"
fi

if ! pflash_ok "$OVMF_LOCAL_VARS"; then
    if [ ! -f "$OVMF_VARS_TEMPLATE" ]; then
        echo "ERROR: UEFI variable store template not found at $OVMF_VARS_TEMPLATE" >&2
        echo "       Set OVMF_VARS_TEMPLATE for your distro." >&2
        exit 1
    fi
    install_pflash "$OVMF_VARS_TEMPLATE" "$OVMF_LOCAL_VARS"
fi

# QEMU puts the terminal into raw mode for the guest serial console. If the
# script dies or is interrupted, put it back -- otherwise the shell is left
# unusable and the only way out is closing the terminal.
restore_tty() { [ -t 0 ] && stty sane 2>/dev/null || true; }
trap restore_tty EXIT

if [ -z "$DEVICE" ]; then
    echo "Creating ${DISK_SIZE_GIB}GiB raw disk..."
    rm -f "$RAW_IMAGE_PATH"
    qemu-img create -f raw -o size="${DISK_SIZE_GIB}G" "$RAW_IMAGE_PATH"
    TARGET="$RAW_IMAGE_PATH"
fi

cat <<BANNER

Starting Harvester install (UEFI, install-mode-only).
  arch:    ${ARCH} on ${QEMU_BIN}, -machine ${QEMU_MACHINE}
  guest:   ${SMP}, ${MEMORY_MIB} MiB
  console: below, and copied to ${INSTALL_LOG}
  abort:   Ctrl-A then X   (plain Ctrl-C goes to the guest)

The VM powers itself off when the install succeeds. If it fails, the installer
leaves the VM running so you can log in on this console as rancher/rancher and
read /var/log/console.log.
---
BANNER

# Kernel arguments, and why:
#
#   console=<tty>,115200n8   Installer TUI and kernel messages on the serial
#                            port. /sys/class/tty/console/active lists the
#                            *preferred* console last, and both
#                            setup-installer.sh and console.isFirstConsoleTTY()
#                            key off the FIRST entry -- so the serial console
#                            must come before any tty1 for the installer to
#                            land on it. Here there is no tty1 at all.
#                            ttyS0 on amd64 (q35's 16550), ttyAMA0 on arm64
#                            (virt's PL011). BUILD console only -- phase 2
#                            rewrites the installed system's console to ttyS0,
#                            which is what EC2 presents on both arches.
#   net.ifnames=0            Predictable eth0. AWS ENA would otherwise be ens5,
#                            and the management interface is named in config.
#   rd.cos.disable           Don't run the cOS/elemental initrd logic for the
#                            live medium.
#   harvester.install.mode=install
#                            Build a pre-installed image (see header).
#   harvester.install.device=/dev/vda
#                            The QEMU virtio disk. Phase 2 / first boot resolve
#                            the real device on EC2.
#   harvester.install.automatic=true
#                            Non-interactive.
#   harvester.install.skipchecks=true
#                            The build VM is virtualized and under-specced
#                            relative to Harvester's production preflight.
#   harvester.install.tty=${TARGET_TTY}
#                            Becomes HARVESTER_TTY, which harv-install's
#                            update_grub_settings() uses to patch
#                            /etc/cos/bootargs.cfg on the installed system.
#                            Deliberately TARGET_TTY, not GUEST_TTY: this
#                            describes where the node's console will be on
#                            EC2, not where the installer is drawing right
#                            now. See the TARGET_TTY note above.
#
# Disk options:
#   cache=none    O_DIRECT. With cache=writeback a 250 GiB image fills the host
#                 page cache with dirty pages while the installer writes ~10 GiB
#                 of container images, which starves the guest and shows up as
#                 stalled imports and khugepaged soft lockups.
#   discard=unmap Keep the sparse file sparse.
QEMU_ARGS=(
    --enable-kvm -nographic
    -machine "${QEMU_MACHINE}"
    -cpu "${QEMU_CPU}" -smp "${SMP}" -m "${MEMORY_MIB}"
    # Equivalent to -serial mon:stdio, but also copies the console to a file so
    # a failed install can be read after the fact instead of scraped out of
    # terminal scrollback.
    -chardev "stdio,id=char0,mux=on,signal=off,logfile=${INSTALL_LOG}"
    -serial chardev:char0
    -mon chardev=char0,mode=readline
    -nic none
    -drive file="$TARGET",if=virtio,cache=none,discard=unmap,format=raw
    -drive file="${ISO_PATH}",if=virtio,media=cdrom,readonly=on
    -drive if=pflash,format=raw,readonly=on,file="${FW_CODE}"
    -drive if=pflash,format=raw,file="${OVMF_LOCAL_VARS}"
    -kernel "${VMLINUZ_PATH}"
    -initrd "${INITRD_PATH}"
    -append "root=live:CDLABEL=COS_LIVE rd.live.dir=/ rd.live.ram=1 rd.live.squashimg=rootfs.squashfs \
console=${GUEST_TTY},115200n8 net.ifnames=0 ${EXTRA_KARGS} rd.cos.disable \
harvester.install.mode=install \
harvester.install.device=/dev/vda \
harvester.install.automatic=true \
harvester.install.powerOff=true \
harvester.install.skipchecks=true \
harvester.install.tty=${TARGET_TTY} \
harvester.install.persistentPartitionSize=${PERSISTENT_SIZE} \
harvester.os.password=${OS_PASSWORD_HASH} \
harvester.scheme_version=1"
)

QEMU_RC=0
if [ "${QEMU_TIMEOUT}" -gt 0 ] && command -v timeout >/dev/null; then
    timeout --foreground -k 30 "${QEMU_TIMEOUT}" \
        "$QEMU_BIN" "${QEMU_ARGS[@]}" || QEMU_RC=$?
else
    "$QEMU_BIN" "${QEMU_ARGS[@]}" || QEMU_RC=$?
fi
restore_tty

echo ""
echo "---"

if [ "$QEMU_RC" -eq 124 ]; then
    echo "ERROR: QEMU was killed after ${QEMU_TIMEOUT}s. The install hung." >&2
    echo "       Console log: ${INSTALL_LOG}" >&2
    if [ -n "$DEVICE" ]; then
        echo "       ${DEVICE} now holds a partial install; just re-run." >&2
    else
        echo "       The partial image is left at ${RAW_IMAGE_PATH}; re-run with" >&2
        echo "       --force once you have addressed the cause." >&2
    fi
    exit 1
fi

if [ "$QEMU_RC" -ne 0 ]; then
    echo "ERROR: QEMU exited with status ${QEMU_RC}." >&2
    if [ ! -s "$INSTALL_LOG" ]; then
        echo "       The console log is empty, so the guest never started. If the" >&2
        echo "       complaint was about '-chardev ... logfile=', your QEMU is too" >&2
        echo "       old; replace the -chardev/-serial/-mon trio in this script" >&2
        echo "       with a plain '-serial mon:stdio'." >&2
    else
        echo "       Console log: ${INSTALL_LOG}" >&2
    fi
    exit 1
fi

# =============================================================================
# Verify -- without root.
#
# The previous version of this script loop-mounted the image to check it, which
# needed sudo. That prompted for a password after QEMU had already put the
# terminal in raw mode, so the prompt was invisible, and `set -e` then killed
# the script even though the install itself had succeeded. Everything below
# reads the console log and the partition table instead.
# =============================================================================
echo "Verifying the install..."

if [ ! -f "$INSTALL_LOG" ]; then
    echo "  WARNING: no console log at ${INSTALL_LOG}; skipping log checks" >&2
elif grep -qF '** Installation Failed **' "$INSTALL_LOG"; then
    echo "" >&2
    echo "ERROR: the Harvester installer reported a failure." >&2
    echo "" >&2
    echo "Last 40 lines of ${INSTALL_LOG}:" >&2
    tail -40 "$INSTALL_LOG" | sed 's/^/  /' >&2
    echo "" >&2
    echo "Common causes:" >&2
    echo "  - Too little guest memory. The 'Load images from ...' step runs RKE2" >&2
    echo "    and containerd; 'Importing elapsed: ... 0.0 B (0.0 B/s)' followed by" >&2
    echo "    a soft lockup means thrashing. Raise MEMORY_MIB (16384 is what" >&2
    echo "    Harvester's own CI uses) or free host RAM." >&2
    echo "  - Host disk full. The image is sparse but the install writes ~10 GiB;" >&2
    echo "    zstd -d of the image tarballs fails with ENOSPC." >&2
    exit 1
else
    echo "  console log shows no installer failure"
fi

# harvester.install.powerOff=true means a successful install powers the guest
# off by itself. A failed one leaves the installer sitting on the console.
if grep -qE 'reboot: Power down|Powering off' "$INSTALL_LOG" 2>/dev/null; then
    echo "  guest powered itself off, as a completed install does"
else
    echo "  WARNING: no clean power-off in the console log" >&2
fi

# Partition table check. sfdisk reads image files fine without root.
if command -v sfdisk >/dev/null; then
    PART_COUNT="$(sfdisk --json "$TARGET" 2>/dev/null \
        | grep -c '"node"' || true)"
    if [ "${PART_COUNT:-0}" -ge 6 ]; then
        echo "  partition table has ${PART_COUNT} partitions (expected 6)"
    else
        echo "" >&2
        echo "ERROR: expected 6 partitions, found ${PART_COUNT:-0}." >&2
        echo "       The install did not lay out the disk. See ${INSTALL_LOG}." >&2
        exit 1
    fi
else
    echo "  sfdisk not available; skipping partition table check"
fi

if [ -n "$DEVICE" ]; then
    echo ""
    echo "Phase 1 complete (installed directly onto ${DEVICE})."
    echo "  Console log: ${INSTALL_LOG}"
    echo ""
    echo "Next: ./scripts/02-customize-instance.sh ${DEVICE}"
    echo "      No compression, upload or 01b step is needed -- the volume this"
    echo "      device belongs to is what gets snapshotted."
else
    echo ""
    echo "Compressing with zstd (this reads the whole ${DISK_SIZE_GIB} GiB image)..."
    zstd -T0 --force "$RAW_IMAGE_PATH"

    echo ""
    echo "Phase 1 complete."
    echo "  Raw image:   ${RAW_IMAGE_PATH}  (${DISK_SIZE_GIB} GiB)"
    echo "  Compressed:  ${RAW_IMAGE_PATH}.zst"
    echo "  Console log: ${INSTALL_LOG}"
    echo ""
    echo "Next: upload the .zst to S3, write it to a ${DISK_SIZE_GIB} GiB EBS volume on a"
    echo "      helper instance, then run 02-customize-instance.sh against that volume."
fi

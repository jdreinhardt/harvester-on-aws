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
#   - qemu-system-x86_64 with KVM
#   - OVMF UEFI firmware (UEFI only -- Harvester dropped legacy BIOS support,
#     and AWS needs an ESP at /EFI/BOOT/BOOTX64.EFI to boot the AMI)
#   - Harvester ISO, vmlinuz and initrd in ./artifacts/
#   - openssl (to hash the OS password -- see note below)
#
# While QEMU is running the terminal belongs to the guest serial console.
# Ctrl-C goes to the guest; to abort the build press Ctrl-A then X.
# =============================================================================

HARVESTER_VERSION="${HARVESTER_VERSION:-v1.8.2}"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-./artifacts}"

PROJECT_PREFIX="harvester-${HARVESTER_VERSION}"
RAW_IMAGE_NAME="${PROJECT_PREFIX}-amd64.raw"
ISO_PATH="${ARTIFACTS_DIR}/${PROJECT_PREFIX}-amd64.iso"
VMLINUZ_PATH="${ARTIFACTS_DIR}/${PROJECT_PREFIX}-vmlinuz-amd64"
INITRD_PATH="${ARTIFACTS_DIR}/${PROJECT_PREFIX}-initrd-amd64"
RAW_IMAGE_PATH="${ARTIFACTS_DIR}/${RAW_IMAGE_NAME}"
INSTALL_LOG="${ARTIFACTS_DIR}/harvester-install-console.log"

# OVMF paths -- adjust for your distro
#   openSUSE:  /usr/share/qemu/ovmf-x86_64-code.bin  or  /usr/share/OVMF/x64/OVMF_CODE.4m.fd
#   Fedora:    /usr/share/edk2/ovmf/OVMF_CODE.fd
#   Debian:    /usr/share/OVMF/OVMF_CODE_4M.fd
OVMF_CODE="${OVMF_CODE:-/usr/share/OVMF/x64/OVMF_CODE.4m.fd}"
OVMF_VARS_TEMPLATE="${OVMF_VARS_TEMPLATE:-/usr/share/OVMF/x64/OVMF_VARS.4m.fd}"
OVMF_LOCAL_VARS="${ARTIFACTS_DIR}/OVMF_VARS.4m.fd"

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

usage() {
    cat <<USAGE
Usage: $0 [--force]

  --force       Rebuild even if ${RAW_IMAGE_PATH} already exists.
                Without this the script refuses to overwrite a previous build.

Environment overrides:
  HARVESTER_VERSION   default ${HARVESTER_VERSION}
  ARTIFACTS_DIR       default ${ARTIFACTS_DIR}
  DISK_SIZE_GIB       default ${DISK_SIZE_GIB}
  PERSISTENT_SIZE     default ${PERSISTENT_SIZE}
  MEMORY_MIB          default ${MEMORY_MIB}
  SMP                 default ${SMP}
  QEMU_TIMEOUT        default ${QEMU_TIMEOUT} seconds (0 disables)
  OS_PASSWORD         default ${OS_PASSWORD}
  OS_PASSWORD_HASH    a SHA-512 crypt hash, used instead of hashing OS_PASSWORD
  OVMF_CODE, OVMF_VARS_TEMPLATE
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --force|-f) FORCE="true"; shift ;;
        -h|--help)  usage; exit 0 ;;
        *)          echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
done

echo "=== Phase 1: Build pre-installed Harvester raw image (${HARVESTER_VERSION}) ==="
echo ""

# --- Validation ---
for f in "$ISO_PATH" "$VMLINUZ_PATH" "$INITRD_PATH" "$OVMF_CODE"; do
    if [ ! -f "$f" ]; then
        echo "ERROR: Required file not found: $f" >&2
        exit 1
    fi
done

command -v qemu-system-x86_64 >/dev/null || { echo "ERROR: qemu-system-x86_64 not found" >&2; exit 1; }
command -v qemu-img          >/dev/null || { echo "ERROR: qemu-img not found" >&2; exit 1; }
command -v zstd              >/dev/null || { echo "ERROR: zstd not found" >&2; exit 1; }

if [ ! -w /dev/kvm ]; then
    echo "ERROR: /dev/kvm is not writable. The Harvester installer preloads" >&2
    echo "       container images by running RKE2 in a chroot; it needs KVM." >&2
    exit 1
fi

# Do not silently destroy a previous build. A failed *script* does not
# necessarily mean a failed *install* -- if the installer powered the VM off,
# the image on disk is good even if a later step errored out.
if [ -e "$RAW_IMAGE_PATH" ] && [ "$FORCE" != "true" ]; then
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

# Writable copy of the OVMF variable store
if [ ! -f "$OVMF_LOCAL_VARS" ]; then
    if [ ! -f "$OVMF_VARS_TEMPLATE" ]; then
        echo "ERROR: OVMF_VARS template not found at $OVMF_VARS_TEMPLATE" >&2
        echo "       Set OVMF_VARS_TEMPLATE for your distro." >&2
        exit 1
    fi
    cp "$OVMF_VARS_TEMPLATE" "$OVMF_LOCAL_VARS"
fi

# QEMU puts the terminal into raw mode for the guest serial console. If the
# script dies or is interrupted, put it back -- otherwise the shell is left
# unusable and the only way out is closing the terminal.
restore_tty() { [ -t 0 ] && stty sane 2>/dev/null || true; }
trap restore_tty EXIT

echo "Creating ${DISK_SIZE_GIB}GiB raw disk..."
rm -f "$RAW_IMAGE_PATH"
qemu-img create -f raw -o size="${DISK_SIZE_GIB}G" "$RAW_IMAGE_PATH"

cat <<BANNER

Starting Harvester install (UEFI, install-mode-only).
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
#   console=ttyS0,115200n8   Installer TUI and kernel messages on the serial
#                            port. /sys/class/tty/console/active lists the
#                            *preferred* console last, and both
#                            setup-installer.sh and console.isFirstConsoleTTY()
#                            key off the FIRST entry -- so ttyS0 must come
#                            before any tty1 for the installer to land on
#                            serial. Here there is no tty1 at all.
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
#   harvester.install.tty=ttyS0
#                            Becomes HARVESTER_TTY, which harv-install's
#                            update_grub_settings() uses to patch
#                            /etc/cos/bootargs.cfg on the installed system.
#
# Disk options:
#   cache=none    O_DIRECT. With cache=writeback a 250 GiB image fills the host
#                 page cache with dirty pages while the installer writes ~10 GiB
#                 of container images, which starves the guest and shows up as
#                 stalled imports and khugepaged soft lockups.
#   discard=unmap Keep the sparse file sparse.
QEMU_ARGS=(
    --enable-kvm -nographic
    -machine q35,smm=off
    -cpu host,+topoext -smp "${SMP}" -m "${MEMORY_MIB}"
    # Equivalent to -serial mon:stdio, but also copies the console to a file so
    # a failed install can be read after the fact instead of scraped out of
    # terminal scrollback.
    -chardev "stdio,id=char0,mux=on,signal=off,logfile=${INSTALL_LOG}"
    -serial chardev:char0
    -mon chardev=char0,mode=readline
    -nic none
    -drive file="$RAW_IMAGE_PATH",if=virtio,cache=none,discard=unmap,format=raw
    -drive file="${ISO_PATH}",if=virtio,media=cdrom,readonly=on
    -drive if=pflash,format=raw,readonly=on,file="${OVMF_CODE}"
    -drive if=pflash,format=raw,file="${OVMF_LOCAL_VARS}"
    -kernel "${VMLINUZ_PATH}"
    -initrd "${INITRD_PATH}"
    -append "root=live:CDLABEL=COS_LIVE rd.live.dir=/ rd.live.ram=1 rd.live.squashimg=rootfs.squashfs \
console=ttyS0,115200n8 net.ifnames=0 biosdevname=0 rd.cos.disable \
harvester.install.mode=install \
harvester.install.device=/dev/vda \
harvester.install.automatic=true \
harvester.install.powerOff=true \
harvester.install.skipchecks=true \
harvester.install.tty=ttyS0 \
harvester.install.persistentPartitionSize=${PERSISTENT_SIZE} \
harvester.os.password=${OS_PASSWORD_HASH} \
harvester.scheme_version=1"
)

QEMU_RC=0
if [ "${QEMU_TIMEOUT}" -gt 0 ] && command -v timeout >/dev/null; then
    timeout --foreground -k 30 "${QEMU_TIMEOUT}" \
        qemu-system-x86_64 "${QEMU_ARGS[@]}" || QEMU_RC=$?
else
    qemu-system-x86_64 "${QEMU_ARGS[@]}" || QEMU_RC=$?
fi
restore_tty

echo ""
echo "---"

if [ "$QEMU_RC" -eq 124 ]; then
    echo "ERROR: QEMU was killed after ${QEMU_TIMEOUT}s. The install hung." >&2
    echo "       Console log: ${INSTALL_LOG}" >&2
    echo "       The partial image is left at ${RAW_IMAGE_PATH}; re-run with" >&2
    echo "       --force once you have addressed the cause." >&2
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
    PART_COUNT="$(sfdisk --json "$RAW_IMAGE_PATH" 2>/dev/null \
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

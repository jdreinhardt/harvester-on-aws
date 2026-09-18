#!/bin/bash
set -euo pipefail

# =============================================================================
# Phase 2: Customize the pre-installed Harvester disk for AWS
#
# Run this as root on an EC2 helper instance, against the EBS volume you wrote
# the phase 1 raw image to.
#
#   sudo ./scripts/02-customize-instance.sh /dev/nvme1n1
#
# What it does, and why each piece is needed:
#
#   1. Repair the GPT backup header if the volume is larger than the image.
#   2. Force the ESP boot path to /EFI/BOOT/BOOTX64.EFI, which is the removable
#      media path AWS firmware boots for an AMI registered from a snapshot.
#   3. Point the installed system's console at ttyS0 only, so the EC2 serial
#      console shows GRUB, the kernel, systemd, the Harvester installer and
#      later the Harvester dashboard. Also force net.ifnames=0 so the ENA
#      device is eth0.
#   4. Install the AWS first-boot glue on COS_OEM. This is the part that
#      actually makes the cluster bootstrap:
#
#        - a temporary NetworkManager profile for eth0, because the image ships
#          `no-auto-default=*` (os2 files/etc/NetworkManager/conf.d/harvester.conf)
#          and a mode=install image has no connection profiles at all, so
#          without this there is NO network on first boot and IMDS is
#          unreachable;
#        - a systemd unit, ordered before the installer's getty, that reads EC2
#          user-data over IMDSv2 and writes /oem/userdata.yaml.
#
#      /oem/userdata.yaml is the file harvester-installer reads in
#      mergeCloudInit() when it detects an already-installed disk. If it
#      contains `install.automatic: true` the installer skips the TUI and runs
#      configureInstalledNode(), which generates /etc/rancher/rancherd/config.yaml
#      plus every rancherd bootstrap resource (ManagedCharts for harvester and
#      harvester-crd, monitoring/logging/kube-ovn CRDs, harvester settings,
#      addons, the rancher ingress) and restarts rancherd.
#
#      This is why the old harvester-post-bootstrap.sh could never finish: a
#      bare `helm install harvester` skips the Fleet ManagedChart machinery and
#      every one of those prerequisites.
#
# Partition layout (GPT), as created by harv-install:
#   p1 COS_GRUB        EFI System Partition, FAT
#   p2 COS_OEM         ext4, cloud-init configs + harvester.config
#   p3 COS_RECOVERY    ext4
#   p4 COS_STATE       ext4, grub.cfg + cOS/{active,passive}.img
#   p5 COS_PERSISTENT  ext4, /usr/local
#   p6 HARV_LH_DEFAULT ext4, Longhorn default disk
# =============================================================================

DISK=""
GROW_DATA_DISK="false"
SERIAL_CONSOLE="true"

usage() {
    cat <<USAGE
Usage: $0 <block-device> [options]

  <block-device>        The EBS volume holding the Harvester image, e.g. /dev/nvme1n1

Options:
  --grow-data-disk      Expand HARV_LH_DEFAULT (p6) to fill the volume. Only
                        useful when the volume is larger than the raw image.
  --no-serial-console   Leave the console configuration as the installer left
                        it (console=ttyS0 console=tty1) instead of forcing
                        serial-only.
  -h, --help            Show this help.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --grow-data-disk)    GROW_DATA_DISK="true"; shift ;;
        --no-serial-console) SERIAL_CONSOLE="false"; shift ;;
        -h|--help)           usage; exit 0 ;;
        -*)                  echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
        *)                   DISK="$1"; shift ;;
    esac
done

if [ -z "$DISK" ]; then
    usage >&2
    exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Must run as root" >&2
    exit 1
fi

if [ ! -b "$DISK" ]; then
    echo "ERROR: $DISK is not a block device" >&2
    exit 1
fi

for tool in blkid lsblk mount umount sed awk; do
    command -v "$tool" >/dev/null || { echo "ERROR: $tool not found" >&2; exit 1; }
done

# Refuse to touch the helper instance's own root disk.
ROOT_SRC="$(findmnt -no SOURCE / 2>/dev/null || true)"
if [ -n "$ROOT_SRC" ]; then
    ROOT_DISK="/dev/$(lsblk -no pkname "$ROOT_SRC" 2>/dev/null || true)"
    if [ "$ROOT_DISK" = "$DISK" ]; then
        echo "ERROR: $DISK is this instance's root disk. Refusing." >&2
        exit 1
    fi
fi

# nvme partitions are <dev>p<N>, everything else is <dev><N>
if [[ "$DISK" == *nvme* || "$DISK" == *loop* ]]; then
    P="${DISK}p"
else
    P="${DISK}"
fi

PART_GRUB="${P}1"
PART_OEM="${P}2"
PART_STATE="${P}4"
PART_DATA="${P}6"

MNT_GRUB="/mnt/harv_cos_grub"
MNT_OEM="/mnt/harv_cos_oem"
MNT_STATE="/mnt/harv_cos_state"
MNT_IMG="/mnt/harv_os_image"

echo "=== Phase 2: Customize Harvester disk for AWS ==="
echo ""
echo "Target disk: $DISK"
echo "  COS_GRUB:        $PART_GRUB"
echo "  COS_OEM:         $PART_OEM"
echo "  COS_STATE:       $PART_STATE"
echo "  HARV_LH_DEFAULT: $PART_DATA"
echo ""

cleanup() {
    umount "$MNT_IMG"   2>/dev/null || true
    umount "$MNT_GRUB"  2>/dev/null || true
    umount "$MNT_OEM"   2>/dev/null || true
    umount "$MNT_STATE" 2>/dev/null || true
    rmdir "$MNT_IMG" "$MNT_GRUB" "$MNT_OEM" "$MNT_STATE" 2>/dev/null || true
}
trap cleanup EXIT

# =============================================================================
# 1. Repair the GPT backup header (and optionally grow the data partition)
# =============================================================================
echo "[1/7] Checking partition table..."

DISK_BYTES="$(lsblk --bytes --nodeps --noheadings --output SIZE "$DISK" | tr -d ' ')"
echo "  Volume size: $((DISK_BYTES / 1024 / 1024 / 1024)) GiB"

# When the raw image is smaller than the volume, the GPT backup header sits in
# the middle of the device rather than in the last sector. That is the
# "partition corruption" the old workflow avoided by padding the volume; the
# correct fix is to relocate the header. Harvester's own stream-disk does the
# same thing with `echo w | fdisk`.
if command -v sgdisk >/dev/null; then
    echo "  Relocating GPT backup header with sgdisk..."
    sgdisk --move-second-header "$DISK" >/dev/null
elif command -v fdisk >/dev/null; then
    echo "  Relocating GPT backup header with fdisk..."
    printf 'w\n' | fdisk "$DISK" >/dev/null 2>&1 || true
else
    echo "  WARNING: neither sgdisk nor fdisk found; skipping GPT repair" >&2
fi
partprobe "$DISK" 2>/dev/null || true
udevadm settle 2>/dev/null || true

if [ "$GROW_DATA_DISK" = "true" ]; then
    if [ ! -b "$PART_DATA" ]; then
        echo "  WARNING: $PART_DATA not found; skipping data disk growth" >&2
    elif ! command -v parted >/dev/null; then
        echo "  WARNING: parted not found; skipping data disk growth" >&2
    else
        echo "  Growing HARV_LH_DEFAULT to fill the volume..."
        if parted -s "$DISK" resizepart 6 100%; then
            partprobe "$DISK" 2>/dev/null || true
            udevadm settle 2>/dev/null || true
            e2fsck -fp "$PART_DATA" >/dev/null 2>&1 || true
            # Non-fatal: the partition is already grown, and Longhorn works
            # fine on the original filesystem size.
            resize2fs "$PART_DATA" || \
                echo "  WARNING: resize2fs failed; p6 grew but the filesystem did not" >&2
        else
            echo "  WARNING: parted resizepart failed; leaving p6 as-is" >&2
        fi
    fi
fi

for part in "$PART_GRUB" "$PART_OEM" "$PART_STATE"; do
    [ -b "$part" ] || { echo "ERROR: $part not found. Is the image written?" >&2; exit 1; }
done

echo "Mounting partitions..."
mkdir -p "$MNT_GRUB" "$MNT_OEM" "$MNT_STATE" "$MNT_IMG"
mount "$PART_GRUB"  "$MNT_GRUB"
mount "$PART_OEM"   "$MNT_OEM"
mount "$PART_STATE" "$MNT_STATE"

if [ ! -f "$MNT_OEM/harvester.config" ]; then
    echo "ERROR: $MNT_OEM/harvester.config is missing." >&2
    echo "       This does not look like a Harvester install. Check the dd step." >&2
    exit 1
fi

if ! grep -qE '^\s*mode:\s*install\s*$' "$MNT_OEM/harvester.config"; then
    echo "ERROR: /oem/harvester.config does not contain 'mode: install'." >&2
    echo "       Phase 2 expects an image built by 01-build-instance.sh with" >&2
    echo "       harvester.install.mode=install. Found:" >&2
    grep -E '^\s*mode:' "$MNT_OEM/harvester.config" >&2 || true
    exit 1
fi

# =============================================================================
# 2. Normalise the EFI boot path
# =============================================================================
echo "[2/7] Normalising EFI boot path..."

# elemental writes EFI/BOOT/bootx64.efi (see elemental-toolkit
# pkg/utils/grub.go: writeShim := "bootx64.efi"). UEFI is supposed to match
# FAT paths case-insensitively, but AWS's firmware boots the removable media
# path and there is no NVRAM boot entry in an AMI registered from a snapshot,
# so make the name exactly what the spec calls for. FAT cannot rename in place
# across case, hence the copy-out/copy-back.
EFI_DIR="$MNT_GRUB/EFI"

normalize_name() {
    # $1 = parent dir, $2 = wanted name
    local parent="$1" want="$2" found=""
    local entry base
    for entry in "$parent"/*; do
        [ -e "$entry" ] || continue
        base="$(basename "$entry")"
        if [ "$base" = "$want" ]; then
            echo "  $parent/$want already correct"
            return 0
        fi
        if [ "$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]')" = \
             "$(printf '%s' "$want" | tr '[:upper:]' '[:lower:]')" ]; then
            found="$entry"
            break
        fi
    done
    if [ -z "$found" ]; then
        echo "  WARNING: nothing matching $want under $parent" >&2
        return 0
    fi
    # Plain -r, not -a: the ESP is FAT and cannot store ownership or the full
    # permission bits, so -a fails on the copy back.
    local tmp
    tmp="$(mktemp -d)"
    cp -r "$found" "$tmp/payload"
    rm -rf "$found"
    sync
    cp -r "$tmp/payload" "$parent/$want"
    rm -rf "$tmp"
    sync
    echo "  Renamed $(basename "$found") -> $want"
}

if [ -d "$EFI_DIR" ]; then
    normalize_name "$EFI_DIR" "BOOT"
    if [ -d "$EFI_DIR/BOOT" ]; then
        normalize_name "$EFI_DIR/BOOT" "BOOTX64.EFI"
    fi
    echo "  ESP contents:"
    ls -la "$EFI_DIR/BOOT/" | sed 's/^/    /'
else
    echo "  ERROR: no EFI directory on COS_GRUB" >&2
    exit 1
fi

# =============================================================================
# 3. Console and interface naming
# =============================================================================
echo "[3/7] Configuring console and interface naming..."

# The installed system's kernel command line comes from /etc/cos/bootargs.cfg
# inside the OS image, combined by GRUB as:
#     linux $kernel $kernelcmd ${extra_cmdline} ${extra_active_cmdline}
# harv-install's update_grub_settings() already set
#     console_params="console=ttyS0 console=tty1"
# from harvester.install.tty. We want ttyS0 to be the ONLY console:
#
#   - /sys/class/tty/console/active lists the preferred console LAST, and both
#     setup-installer.sh and console.isFirstConsoleTTY() key off the FIRST
#     entry. With ttyS0 alone there is no ambiguity: the installer and later
#     the Harvester dashboard run on the serial console, which is what EC2
#     Serial Console attaches to.
#   - /dev/console also becomes ttyS0, so systemd and rancherd output shows up
#     there too, which is the only way to watch a bootstrap without SSH.
#
# bootargs.cfg also hardcodes net.ifnames=1; AWS ENA would then be ens5 and the
# eth0 named in the management interface config would not exist.
patch_bootargs() {
    local img="$1"
    [ -f "$img" ] || return 0
    if ! mount -o loop "$img" "$MNT_IMG" 2>/dev/null; then
        echo "  WARNING: could not mount $(basename "$img"); skipping" >&2
        return 0
    fi
    local cfg="$MNT_IMG/etc/cos/bootargs.cfg"
    if [ -f "$cfg" ]; then
        if [ "$SERIAL_CONSOLE" = "true" ]; then
            sed -i 's|^set console_params=.*|set console_params="console=ttyS0,115200n8"|' "$cfg"
        fi
        sed -i 's|net\.ifnames=1|net.ifnames=0|g' "$cfg"
        echo "  Patched $(basename "$img"): $(grep '^set console_params=' "$cfg")"
    else
        echo "  WARNING: $(basename "$img") has no /etc/cos/bootargs.cfg" >&2
    fi
    sync
    umount "$MNT_IMG"
}

patch_bootargs "$MNT_STATE/cOS/active.img"
patch_bootargs "$MNT_STATE/cOS/passive.img"

# Belt and braces: grubcustom lives on COS_STATE and survives an OS upgrade
# (which replaces active.img and therefore reverts bootargs.cfg). GRUB sources
# it at the end of grub.cfg, which is still before any menuentry body is
# evaluated, so setting extra_cmdline there works.
#
# harv-install already wrote a "(debug)" menuentry into this file, so prepend
# rather than overwrite.
GRUB_CUSTOM="$MNT_STATE/grubcustom"
AWS_MARKER="# --- AWS overrides (02-customize-instance.sh) ---"

if [ -f "$GRUB_CUSTOM" ] && grep -qF "$AWS_MARKER" "$GRUB_CUSTOM"; then
    echo "  grubcustom already carries the AWS overrides"
else
    TMPFILE="$(mktemp)"
    {
        echo "$AWS_MARKER"
        echo 'set extra_cmdline="console=ttyS0,115200n8 net.ifnames=0 biosdevname=0"'
        echo "$AWS_MARKER"
        echo ""
        # harv-install's add_debug_grub_entry() already put a menuentry here.
        [ -f "$GRUB_CUSTOM" ] && cat "$GRUB_CUSTOM" || true
    } > "$TMPFILE"
    mv "$TMPFILE" "$GRUB_CUSTOM"
    chmod 0644 "$GRUB_CUSTOM"
    echo "  Wrote AWS overrides to COS_STATE/grubcustom"
fi

# =============================================================================
# 4. AWS first-boot glue on COS_OEM
# =============================================================================
echo "[4/7] Installing AWS first-boot glue..."

rm -rf "$MNT_OEM/aws"
mkdir -p "$MNT_OEM/aws"

# ---------------------------------------------------------------------------
# stage-initramfs.sh -- runs from the yip `initramfs` stage, i.e. inside the
# initrd against the real root, before switch-root and therefore before any
# getty. No network here; this only stages files.
# ---------------------------------------------------------------------------
cat > "$MNT_OEM/aws/stage-initramfs.sh" <<'STAGEEOF'
#!/bin/bash
# Staged by 02-customize-instance.sh. Invoked from /oem/99_aws.yaml at the yip
# `initramfs` stage, which runs after /system/oem/91_installer.yaml (yip
# processes /system/oem before /oem) and therefore after setup-installer.sh has
# created the installer's getty drop-in.
set -uo pipefail

log() { echo "[harvester-aws/stage] $*"; }

NM_DIR=/etc/NetworkManager/system-connections
SYSTEMD_DIR=/etc/systemd/system

# Both /etc/NetworkManager and /etc/systemd are PERSISTENT_STATE_BIND paths
# (os2 files/system/oem/00_rootfs.yaml), so writes here survive reboots.

# Once the node has been configured by the installer it owns the network:
# bond-mgmt + bridge-mgmt + bond-slave-eth0. Never re-add the bootstrap profile
# on top of that.
if [ -f "$NM_DIR/bridge-mgmt.nmconnection" ] || [ -f /etc/rancher/rancherd/config.yaml ]; then
    log "node already configured; nothing to stage"
    exit 0
fi

# --- Bootstrap NetworkManager profile -------------------------------------
# The Harvester image sets no-auto-default=* so NetworkManager will not bring
# up an interface without a profile, and a mode=install image ships none. This
# profile exists purely so the first-boot unit can reach IMDS. It is named
# *.nmconnection so that the installer's wipeNMConnectionProfiles() (glob
# "*nmconnection") deletes it when it lays down the real bond/bridge.
mkdir -p "$NM_DIR"
cat > "$NM_DIR/aws-bootstrap-eth0.nmconnection" <<'NMEOF'
[connection]
id=aws-bootstrap-eth0
type=ethernet
interface-name=eth0
autoconnect=true
autoconnect-priority=-999

[ipv4]
method=auto

[ipv6]
method=disabled
NMEOF
# NetworkManager refuses to load profiles that are group- or world-readable.
chmod 0600 "$NM_DIR/aws-bootstrap-eth0.nmconnection"
log "wrote bootstrap NetworkManager profile for eth0"

# --- First-boot configuration unit ----------------------------------------
cat > "$SYSTEMD_DIR/harvester-aws-config.service" <<'UNITEOF'
[Unit]
Description=Fetch EC2 user-data and stage /oem/userdata.yaml for harvester-installer
Documentation=https://docs.harvesterhci.io/latest/install/harvester-configuration/
Wants=NetworkManager.service
After=NetworkManager.service dbus.service
Before=getty.target
ConditionPathExists=!/etc/rancher/rancherd/config.yaml

[Service]
Type=oneshot
RemainAfterExit=yes
TimeoutStartSec=600
ExecStart=/bin/bash /oem/aws/configure.sh
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
UNITEOF
mkdir -p "$SYSTEMD_DIR/multi-user.target.wants"
ln -sf ../harvester-aws-config.service \
    "$SYSTEMD_DIR/multi-user.target.wants/harvester-aws-config.service"
log "installed harvester-aws-config.service"

# --- Order the installer's getty after us ---------------------------------
# elemental-setup-boot.service is only `Before=getty.target`, which does not
# order it before the getty units themselves -- they are Before=getty.target
# too, so they can start in parallel. The installer reads /oem/userdata.yaml
# the moment it starts, so we need a hard ordering edge. Wants= rather than
# Requires= so that a failed fetch still gives you the interactive installer on
# the serial console instead of no console at all.
staged_getty=0
for d in "$SYSTEMD_DIR"/getty@*.service.d "$SYSTEMD_DIR"/serial-getty@*.service.d; do
    [ -d "$d" ] || continue
    grep -qs 'start-installer.sh' "$d"/*.conf || continue
    cat > "$d/10-harvester-aws.conf" <<'DROPEOF'
[Unit]
Wants=harvester-aws-config.service
After=harvester-aws-config.service
DROPEOF
    log "ordered $(basename "$d") after harvester-aws-config.service"
    staged_getty=1
done
if [ "$staged_getty" -eq 0 ]; then
    log "WARNING: no installer getty drop-in found; ordering not guaranteed"
fi

exit 0
STAGEEOF
chmod 0755 "$MNT_OEM/aws/stage-initramfs.sh"

# ---------------------------------------------------------------------------
# configure.sh -- runs from systemd once the network is up, before the
# installer's getty.
# ---------------------------------------------------------------------------
cat > "$MNT_OEM/aws/configure.sh" <<'CONFEOF'
#!/bin/bash
# Staged by 02-customize-instance.sh. Run by harvester-aws-config.service.
#
# Reads EC2 user-data (which must be a Harvester configuration file --
# https://docs.harvesterhci.io/latest/install/harvester-configuration/), fills
# in the values that can only be known at runtime, and writes
# /oem/userdata.yaml.
#
# harvester-installer picks that file up in mergeCloudInit() when it detects an
# already-installed disk, and if install.automatic is true it runs
# configureInstalledNode() non-interactively: rancherd config + bootstrap
# resources + restart rancherd. That is the whole bootstrap.
set -uo pipefail

LOG=/var/log/harvester-aws-config.log
mkdir -p /var/log
touch "$LOG"; chmod 0600 "$LOG"
exec > >(tee -a "$LOG") 2>&1

say()  { echo "[harvester-aws] $*"; }
die()  { echo "[harvester-aws] ERROR: $*" >&2; exit 1; }

say "=== starting at $(date -Is) ==="

if [ -f /etc/rancher/rancherd/config.yaml ]; then
    say "node already configured; nothing to do"
    exit 0
fi

command -v yq >/dev/null || die "yq not found in the image; cannot merge configuration"

# --- 0. Longhorn data partition: grow, then mount ---------------------------
# Deferred until after the user-data fetch so `aws.data_disk_size` can be read;
# see grow_data_partition() below. Both steps happen on the FIRST boot only.
#
# Why the mount is needed at all: the first boot uses os2's stock rootfs layout,
#     VOLUMES: "LABEL=COS_OEM:/oem LABEL=COS_PERSISTENT:/usr/local"
# and the entry that mounts HARV_LH_DEFAULT at Longhorn's defaultDataPath lives
# in the rootfs stage of /oem/99_custom.yaml, which configureInstalledNode()
# writes during this very boot -- and rootfs stages only run in the initrd.
# configureInstalledNode() then finishes with harv-restart-services (restart
# rancherd; no reboot), so without this Longhorn comes up with its data path on
# the /var tmpfs overlay and every volume ends up `faulted`:
#
#   NAME           STATE      ROBUSTNESS   SCHEDULED   SIZE
#   pvc-b022fae4   detached   faulted                  25769803776
#
# Later boots do not need any of this -- by then /oem/99_custom.yaml exists and
# the rootfs stage handles the mount -- which is why it all sits below the
# already-configured check.
LH_PATH=/var/lib/harvester/defaultdisk

# HARV_LH_DEFAULT is the LAST partition, so it is the only one that can be grown
# in place. COS_PERSISTENT sits before it and would need the data partition
# relocated, so its size is fixed at image build time by PERSISTENT_SIZE.
grow_data_partition() {
    local disk="$1" want="$2" part part_num

    part="$(blkid -L HARV_LH_DEFAULT 2>/dev/null || true)"
    if [ -z "$part" ]; then
        say "WARNING: no HARV_LH_DEFAULT partition; Longhorn will have no data disk"
        return 1
    fi
    part_num="$(printf '%s' "$part" | grep -oE '[0-9]+$')"

    for t in parted partprobe resize2fs; do
        command -v "$t" >/dev/null || {
            say "WARNING: $t not found; leaving the data partition at its built size"
            return 1
        }
    done

    # The image is smaller than the volume, so the GPT backup header is stranded
    # mid-disk and parted will not extend past it.
    if command -v sgdisk >/dev/null; then
        sgdisk --move-second-header "$disk" >/dev/null 2>&1 || true
    else
        printf 'w\n' | fdisk "$disk" >/dev/null 2>&1 || true
    fi
    partprobe "$disk" >/dev/null 2>&1 || true
    udevadm settle >/dev/null 2>&1 || true

    say "growing $part to ${want}..."
    if ! parted -s "$disk" resizepart "$part_num" "$want" >/dev/null 2>&1; then
        if [ "$want" != "100%" ]; then
            say "  could not resize to ${want}; falling back to the whole disk"
            parted -s "$disk" resizepart "$part_num" 100% >/dev/null 2>&1 || {
                say "WARNING: resizepart failed; leaving the data partition as-is"
                return 1
            }
        else
            say "WARNING: resizepart failed; leaving the data partition as-is"
            return 1
        fi
    fi
    partprobe "$disk" >/dev/null 2>&1 || true
    udevadm settle >/dev/null 2>&1 || true

    e2fsck -fp "$part" >/dev/null 2>&1 || true
    if ! resize2fs "$part" >/dev/null 2>&1; then
        say "WARNING: resize2fs failed; the partition grew but the filesystem did not"
        return 1
    fi
    return 0
}

mount_data_partition() {
    local part
    part="$(blkid -L HARV_LH_DEFAULT 2>/dev/null || true)"
    [ -n "$part" ] || return 1
    if findmnt -n "$LH_PATH" >/dev/null 2>&1; then
        say "Longhorn data partition already mounted at $LH_PATH"
        return 0
    fi
    mkdir -p "$LH_PATH"
    if mount "$part" "$LH_PATH"; then
        say "mounted $part at $LH_PATH ($(df -h --output=size "$LH_PATH" 2>/dev/null | tail -1 | tr -d ' ') for Longhorn)"
        return 0
    fi
    say "WARNING: could not mount $part at $LH_PATH. Longhorn volumes will fault."
    say "         Reboot once the installer finishes to pick up the rootfs stage."
    return 1
}


# --- 1. Network ------------------------------------------------------------
say "waiting for eth0 to get an address..."
for i in $(seq 1 60); do
    if ip -4 -br addr show dev eth0 2>/dev/null | grep -qE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'; then
        break
    fi
    if [ "$i" -eq 15 ]; then
        say "still no address; nudging NetworkManager"
        nmcli connection up aws-bootstrap-eth0 >/dev/null 2>&1 || true
    fi
    sleep 2
done
ip -4 -br addr show dev eth0 || true
ip -4 -br addr show dev eth0 2>/dev/null | grep -qE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' \
    || die "eth0 never got an IPv4 address; cannot reach IMDS"

# --- 2. IMDSv2 -------------------------------------------------------------
IMDS="http://169.254.169.254/latest"
IMDS_TOKEN=""
for i in $(seq 1 30); do
    IMDS_TOKEN="$(curl -sf -m 5 -X PUT "$IMDS/api/token" \
        -H 'X-aws-ec2-metadata-token-ttl-seconds: 21600' 2>/dev/null || true)"
    [ -n "$IMDS_TOKEN" ] && break
    sleep 2
done
[ -n "$IMDS_TOKEN" ] || die "could not obtain an IMDSv2 token"

imds() { curl -sf -m 5 -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" "$IMDS/$1" 2>/dev/null; }

INSTANCE_ID="$(imds meta-data/instance-id || true)"
LOCAL_IPV4="$(imds meta-data/local-ipv4 || true)"
say "instance-id=${INSTANCE_ID:-unknown} local-ipv4=${LOCAL_IPV4:-unknown}"

USER_DATA="$(imds user-data || true)"
if [ -z "$USER_DATA" ]; then
    die "no EC2 user-data. Launch the instance with a Harvester configuration
       as user-data (03-launch-instance.sh does this for you). Without it the
       interactive installer will come up on the serial console instead."
fi

# --- 3. Runtime-derived defaults -------------------------------------------
# INSTALL_DISK was resolved above. checkDevice() in the installer stats this
# path and requires the disk to be at least 250 GiB -- note that check is NOT
# gated by skipchecks, so the launched volume must meet it even though the AMI
# can be built smaller.

# Hostname must be a valid RFC 1123 subdomain (validator.go). Derive a stable,
# clean one from the instance id; user-data can override it.
if [ -n "$INSTANCE_ID" ]; then
    DEFAULT_HOSTNAME="harvester-${INSTANCE_ID#i-}"
else
    DEFAULT_HOSTNAME="harvester-$(head -c 6 /etc/machine-id)"
fi
DEFAULT_HOSTNAME="$(printf '%s' "$DEFAULT_HOSTNAME" | tr '[:upper:]' '[:lower:]')"

# A token is mandatory in create/join mode (checkToken). Derive a stable one
# from machine-id if user-data does not supply it.
DEFAULT_TOKEN="harvester-$(cat /etc/machine-id 2>/dev/null | head -c 16)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Strip a cloud-config marker line if someone pasted one in; readUserData()
# does the same, but we parse the file with yq first.
printf '%s\n' "$USER_DATA" \
    | grep -v -E '^#!?cloud-config[[:space:]]*$' > "$WORK/user-data.yaml" || true

yq -e '.' "$WORK/user-data.yaml" >/dev/null 2>&1 \
    || die "EC2 user-data is not valid YAML. Expected a Harvester configuration file."
[ "$(yq -r 'type' "$WORK/user-data.yaml" 2>/dev/null)" = "!!map" ] \
    || die "EC2 user-data parsed but is not a YAML mapping. Expected a Harvester
       configuration file, not a shell script or cloud-init document."

# --- 3a. Size and mount the Longhorn data partition -------------------------
# `aws.data_disk_size` is this repo's own key, not part of the Harvester schema;
# it is stripped again before /oem/userdata.yaml is written. "max" fills the
# volume, otherwise give a size such as "200Gi".
DATA_DISK_SIZE="$(yq -r '.aws.data_disk_size // "max"' "$WORK/user-data.yaml")"
case "$DATA_DISK_SIZE" in
    max|MAX|"")      PARTED_SIZE="100%" ;;
    *[Gg]i|*[Gg]iB)  PARTED_SIZE="$(printf '%s' "$DATA_DISK_SIZE" | grep -oE '^[0-9]+')GiB" ;;
    *)
        say "WARNING: unrecognised aws.data_disk_size '${DATA_DISK_SIZE}'"
        say "         expected 'max' or a size like '200Gi'; filling the volume"
        PARTED_SIZE="100%"
        ;;
esac

STATE_PART="$(blkid -L COS_STATE || true)"
[ -n "$STATE_PART" ] || die "could not locate the COS_STATE partition"
INSTALL_DISK="/dev/$(lsblk -no pkname "$STATE_PART" | head -1)"
[ -b "$INSTALL_DISK" ] || die "resolved install disk $INSTALL_DISK is not a block device"
say "install disk: $INSTALL_DISK"

grow_data_partition "$INSTALL_DISK" "$PARTED_SIZE" || true
mount_data_partition || true

# fail_over_mac is not optional on EC2. UpdateManagementInterfaceConfig always
# builds a bond (mgmt-bo) under the bridge, and in active-backup mode with
# fail_over_mac=none the bonding driver rewrites each slave's MAC to the bond's:
#
#   if (!bond->params.fail_over_mac ||
#       BOND_MODE(bond) != BOND_MODE_ACTIVEBACKUP) {
#           res = dev_set_mac_address(slave_dev, ...);
#           if (res) { slave_err(... "Error %d calling set_mac_address");
#                      goto err_restore_mtu; }      <-- enslavement ABORTS
#   }
#
# ENA returns -EOPNOTSUPP (-95), so eth0 never joins the bond, mgmt-br never
# gets carrier, and the node has no network at all:
#
#   mgmt-bo: (slave eth0): Error -95 calling set_mac_address
#
# With fail_over_mac=active that call is skipped and the bond instead takes its
# MAC from the active slave, which is the ENI MAC -- exactly what AWS requires,
# since the VPC drops frames with any other source MAC.
#
# All three options have to be given together: updateBond() only injects its
# mode/miimon defaults when bond_options is absent entirely.
DEFAULT_HOSTNAME="$DEFAULT_HOSTNAME" DEFAULT_TOKEN="$DEFAULT_TOKEN" \
INSTALL_DISK="$INSTALL_DISK" yq -n '
  .scheme_version = 1 |
  .token = strenv(DEFAULT_TOKEN) |
  .os.hostname = strenv(DEFAULT_HOSTNAME) |
  .install.automatic = true |
  .install.mode = "create" |
  .install.device = strenv(INSTALL_DISK) |
  .install.vip_mode = "static" |
  .install.management_interface.interfaces = [{"name": "eth0"}] |
  .install.management_interface.method = "dhcp" |
  .install.management_interface.bond_options.mode = "active-backup" |
  .install.management_interface.bond_options.miimon = "100" |
  .install.management_interface.bond_options.fail_over_mac = "active"
' > "$WORK/defaults.yaml"

# Deep merge, user-data wins.
yq ea '. as $item ireduce ({}; . * $item)' "$WORK/defaults.yaml" "$WORK/user-data.yaml" \
    > "$WORK/merged.yaml" || die "failed to merge user-data with defaults"

# --- 4. Values we always force ---------------------------------------------
# Without install.automatic the installer shows the TUI and waits forever.
# scheme_version must be exactly 1 or Validate() rejects the config.
yq -i '.install.automatic = true | .scheme_version = 1' "$WORK/merged.yaml"

# Guard against user-data supplying partial bond_options and losing the one
# option that makes bonding work on ENA at all. See the comment on the defaults.
BOND_MODE="$(yq -r '.install.management_interface.bond_options.mode // "active-backup"' "$WORK/merged.yaml")"
FOM="$(yq -r '.install.management_interface.bond_options.fail_over_mac // ""' "$WORK/merged.yaml")"
if [ "$BOND_MODE" != "active-backup" ]; then
    # The kernel consults fail_over_mac only in active-backup mode:
    #   if (!bond->params.fail_over_mac || BOND_MODE(bond) != BOND_MODE_ACTIVEBACKUP)
    # so any other mode still tries to rewrite the slave MAC and still fails on
    # ENA. EC2 offers no switch-side LAG either, so this cannot work.
    say "WARNING: bond mode is '${BOND_MODE}', not active-backup. On EC2 the bond"
    say "         will try to rewrite eth0's MAC, which ENA rejects with"
    say "         -EOPNOTSUPP, and the node will come up with no network."
elif [ -z "$FOM" ] || [ "$FOM" = "none" ] || [ "$FOM" = "0" ]; then
    yq -i '.install.management_interface.bond_options.fail_over_mac = "active"' "$WORK/merged.yaml"
    say "forced bond_options.fail_over_mac=active (was '${FOM:-unset}'); ENA cannot"
    say "  have its MAC rewritten, so the bond would reject eth0 with -EOPNOTSUPP"
fi

# The SSH key from the launch keypair, unless user-data supplied keys.
if [ "$(yq '.os.ssh_authorized_keys // [] | length' "$WORK/merged.yaml")" = "0" ]; then
    EC2_KEY="$(imds meta-data/public-keys/0/openssh-key || true)"
    if [ -n "$EC2_KEY" ]; then
        EC2_KEY="$EC2_KEY" yq -i '.os.ssh_authorized_keys = [strenv(EC2_KEY)]' "$WORK/merged.yaml"
        say "added the EC2 keypair public key to os.ssh_authorized_keys"
    fi
fi

# --- 5. Validate what the installer will reject -----------------------------
MODE="$(yq -r '.install.mode // ""' "$WORK/merged.yaml")"
VIP="$(yq -r '.install.vip // ""'  "$WORK/merged.yaml")"
TOKEN="$(yq -r '.token // ""'      "$WORK/merged.yaml")"
PASSWD="$(yq -r '.os.password // ""' "$WORK/merged.yaml")"
NKEYS="$(yq '.os.ssh_authorized_keys // [] | length' "$WORK/merged.yaml")"

[ -n "$TOKEN" ] || die "token is empty"
if [ "$MODE" = "create" ] && [ -z "$VIP" ]; then
    die "install.mode is 'create' but install.vip is not set.
       Harvester needs a VIP for the management plane. On EC2 this must be a
       secondary private IP assigned to the instance's ENI -- see
       03-launch-instance.sh."
fi
if [ "$MODE" = "join" ] && [ -z "$(yq -r '.server_url // ""' "$WORK/merged.yaml")" ]; then
    die "install.mode is 'join' but server_url is not set"
fi
if [ -z "$PASSWD" ] && [ "$NKEYS" = "0" ]; then
    # commonCheck() rejects a config with neither. mergo fills os.password from
    # the hash baked into /oem/harvester.config at build time, so only complain
    # if that is empty too.
    BAKED_PASSWD="$(yq -r '.os.password // ""' /oem/harvester.config 2>/dev/null || echo "")"
    [ -n "$BAKED_PASSWD" ] || die "neither os.password nor os.ssh_authorized_keys is set,
       and no password was baked in at build time. The installer refuses a
       configuration with no credentials. Launch with --key-name, or set
       os.password to a crypt hash in user-data."
    say "no credentials in user-data; falling back to the password baked in at build time"
fi
case "$PASSWD" in
    ''|'$'*) : ;;
    *)
        say "WARNING: os.password does not look like a crypt hash. It is written"
        say "         verbatim to /etc/shadow, so a plaintext value disables"
        say "         password login rather than setting it."
        ;;
esac

# --- 6. Extra TLS SANs for every node --------------------------------------
# harvester-installer writes the RKE2 server config carrying tls-san ONLY on the
# bootstrap node:
#
#   if config.ServerURL == "" { ...write 90-harvester-server.yaml... }
#
# so a node that joined and was later promoted serves an API certificate without
# any of the extra names on it. Putting a load balancer in front of 6443 then
# fails certificate verification whenever it does not pick node 1 -- verified on
# a live cluster.
#
# Writing the drop-in here fixes that: it runs on EVERY node, before RKE2 has
# ever started, so the certificate is generated correctly the first time and no
# cert deletion or restart is needed.
#
# The VIP must be in the list explicitly. An explicit tls-san REPLACES whatever
# implicitly supplied it on a joined node -- measured: adding only the load
# balancer names silently dropped the VIP from that node's certificate. RKE2's
# own additions (localhost, the node name and IP, the service IP, the
# kubernetes.* names) are unaffected.
TLS_SANS="$(yq -r '.aws.tls_sans // [] | .[]' "$WORK/user-data.yaml" 2>/dev/null || true)"
if [ -n "$TLS_SANS" ]; then
    mkdir -p /etc/rancher/rke2/config.yaml.d
    {
        echo "tls-san:"
        printf '%s\n' "$TLS_SANS" | while IFS= read -r san; do
            [ -n "$san" ] && echo "  - ${san}"
        done
    } > /etc/rancher/rke2/config.yaml.d/95-aws-tls-san.yaml
    chmod 0600 /etc/rancher/rke2/config.yaml.d/95-aws-tls-san.yaml
    say "wrote 95-aws-tls-san.yaml ($(printf '%s' "$TLS_SANS" | tr '\n' ' '))"
fi

# --- 7. Stage it -----------------------------------------------------------
# `aws.*` is ours, not Harvester's. Remove it so the installer only ever sees a
# clean Harvester configuration file.
yq -i 'del(.aws)' "$WORK/merged.yaml"

install -o root -g root -m 0600 "$WORK/merged.yaml" /oem/userdata.yaml
say "wrote /oem/userdata.yaml (mode=$MODE vip=${VIP:-none} hostname=$(yq -r '.os.hostname' /oem/userdata.yaml))"

# /oem/harvester.config was written at image build time and still says
# device: /dev/vda. mergo.Merge only fills EMPTY fields, so userdata.yaml
# cannot override it -- patch it here or checkDevice() fails.
if [ -f /oem/harvester.config ]; then
    CURRENT_DEV="$(yq -r '.install.device // ""' /oem/harvester.config)"
    if [ "$CURRENT_DEV" != "$INSTALL_DISK" ]; then
        INSTALL_DISK="$INSTALL_DISK" yq -i '.install.device = strenv(INSTALL_DISK)' /oem/harvester.config
        say "patched /oem/harvester.config install.device: $CURRENT_DEV -> $INSTALL_DISK"
    fi
    # Built with powerOff=true so the QEMU install VM would shut down. Leaving
    # it set is harmless on this path but misleading.
    yq -i '.install.poweroff = false' /oem/harvester.config 2>/dev/null || true
fi

say "=== done at $(date -Is); handing over to harvester-installer ==="
exit 0
CONFEOF
chmod 0755 "$MNT_OEM/aws/configure.sh"

cat > "$MNT_OEM/aws/README" <<'READMEEOF'
AWS first-boot glue, installed by 02-customize-instance.sh.

  stage-initramfs.sh  yip `initramfs` stage: bootstrap NetworkManager profile,
                      harvester-aws-config.service, getty ordering.
  configure.sh        harvester-aws-config.service: IMDSv2 -> /oem/userdata.yaml.

Logs:
  journalctl -u harvester-aws-config
  /var/log/harvester-aws-config.log
  /var/log/console.log            (harvester-installer)
  journalctl -u rancherd
READMEEOF

# yip only loads *.yaml / *.yml, and only /oem/*.yaml at the top level matter,
# so the scripts above are invisible to it. This is the only yaml we add.
cat > "$MNT_OEM/99_aws.yaml" <<'AWSEOF'
name: "Harvester on AWS EC2"
stages:
  initramfs:
    - name: "Stage AWS first-boot configuration"
      commands:
        - /bin/bash /oem/aws/stage-initramfs.sh
AWSEOF
chmod 0600 "$MNT_OEM/99_aws.yaml"
echo "  Wrote /oem/99_aws.yaml, /oem/aws/stage-initramfs.sh, /oem/aws/configure.sh"

# =============================================================================
# 5. Remove artefacts from the previous approach
# =============================================================================
echo "[5/7] Removing superseded files..."
for stale in harvester-post-bootstrap.sh 90_custom.yaml; do
    if [ -e "$MNT_OEM/$stale" ]; then
        rm -f "$MNT_OEM/$stale"
        echo "  Removed /oem/$stale"
    fi
done
# A userdata.yaml left over from an earlier run would be picked up verbatim.
if [ -e "$MNT_OEM/userdata.yaml" ]; then
    rm -f "$MNT_OEM/userdata.yaml"
    echo "  Removed stale /oem/userdata.yaml"
fi

# =============================================================================
# 6. Check the runtime dependencies the first-boot script needs
# =============================================================================
echo "[6/7] Checking the OS image for required tools..."
MISSING=""
if mount -o loop,ro "$MNT_STATE/cOS/active.img" "$MNT_IMG" 2>/dev/null; then
    for tool in usr/bin/yq usr/bin/curl usr/bin/nmcli usr/bin/lsblk \
                usr/sbin/parted usr/sbin/partprobe usr/sbin/resize2fs; do
        [ -e "$MNT_IMG/$tool" ] || MISSING="$MISSING $tool"
    done
    umount "$MNT_IMG"
    if [ -n "$MISSING" ]; then
        echo "  WARNING: not found in the OS image:$MISSING" >&2
        echo "           /oem/aws/configure.sh depends on these." >&2
    else
        echo "  yq, curl, nmcli, lsblk, parted, partprobe and resize2fs are present"
    fi
else
    echo "  WARNING: could not inspect active.img; skipping tool check" >&2
fi

# =============================================================================
# 7. Summary
# =============================================================================
echo "[7/7] Verifying..."
echo ""
echo "  /oem/harvester.config (must stay mode: install):"
yq_bin="$(command -v yq || true)"
if [ -n "$yq_bin" ]; then
    "$yq_bin" '{"mode": .install.mode, "device": .install.device, "tty": .install.tty, "automatic": .install.automatic}' \
        "$MNT_OEM/harvester.config" 2>/dev/null | sed 's/^/    /' || \
        grep -E '^\s*(mode|device|tty|automatic):' "$MNT_OEM/harvester.config" | sed 's/^/    /'
else
    grep -E '^\s*(mode|device|tty|automatic):' "$MNT_OEM/harvester.config" | sed 's/^/    /'
fi
echo ""
echo "  COS_OEM contents:"
ls -la "$MNT_OEM" | sed 's/^/    /'
echo ""

cat <<SUMMARY
=============================================
Phase 2 complete
=============================================

COS_GRUB   EFI/BOOT/BOOTX64.EFI
COS_STATE  active.img + passive.img -> console=ttyS0 only, net.ifnames=0
           grubcustom -> same, as an upgrade-proof fallback
COS_OEM    99_aws.yaml            -> runs aws/stage-initramfs.sh each boot
           aws/stage-initramfs.sh -> eth0 NM profile + first-boot unit + getty ordering
           aws/configure.sh       -> IMDSv2 -> /oem/userdata.yaml
           harvester.config       -> untouched (mode: install is required)

First boot sequence:
  1. GRUB -> kernel on ttyS0, eth0 naming
  2. yip initramfs: 91_installer.yaml creates the installer getty,
                    99_aws.yaml stages the AWS glue
  3. harvester-aws-config.service: eth0 up -> IMDSv2 -> /oem/userdata.yaml
  4. harvester-installer: alreadyInstalled + install.automatic
                          -> configureInstalledNode()
                          -> /etc/rancher/rancherd/config.yaml
                             + /var/lib/rancher/rancherd/bootstrap/*
                          -> restart rancherd
  5. rancherd: RKE2 + Rancher + harvester/harvester-crd ManagedCharts

Next:
  1. Detach the volume from this helper instance
  2. Create a snapshot
  3. Register the AMI with --boot-mode uefi and a volume size equal to the
     raw image size
  4. Launch with 03-launch-instance.sh
SUMMARY

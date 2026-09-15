#!/bin/bash
set -euo pipefail

# =============================================================================
# Step 1: Build Harvester Raw Disk Image via QEMU
#
# This creates a raw disk with Harvester installed in UEFI mode.
# The disk is a "bare install" — no cluster bootstrap, no VIP, no token.
# All AWS-specific customization happens in Phase 2.
#
# Prerequisites:
#   - qemu-system-x86_64 with KVM support
#   - OVMF UEFI firmware
#   - Harvester ISO, vmlinuz, and initrd in ./artifacts/
# =============================================================================

# --- Configuration ---
HARVESTER_VERSION="v1.8.0"
PROJECT_PREFIX="harvester-${HARVESTER_VERSION}"
ARTIFACTS_DIR="./artifacts"
RAW_IMAGE_NAME="${PROJECT_PREFIX}-amd64.raw"
ISO_PATH="${ARTIFACTS_DIR}/${PROJECT_PREFIX}-amd64.iso"
VMLINUZ_PATH="${ARTIFACTS_DIR}/${PROJECT_PREFIX}-vmlinuz-amd64"
INITRD_PATH="${ARTIFACTS_DIR}/${PROJECT_PREFIX}-initrd-amd64"

# OVMF paths — adjust for your distro
# openSUSE:      /usr/share/OVMF/x64/OVMF_CODE.4m.fd
OVMF_CODE="/usr/share/OVMF/x64/OVMF_CODE.4m.fd"
OVMF_VARS_TEMPLATE="/usr/share/OVMF/x64/OVMF_VARS.4m.fd"
OVMF_LOCAL_VARS="${ARTIFACTS_DIR}/OVMF_VARS.4m.fd"

DISK_SIZE="250G"
PERSISTENT_SIZE="150Gi"
OS_PASSWORD="rancher"

# --- Validation ---
echo "=== Phase 1: Build Harvester Raw Image ==="
echo ""

for f in "$ISO_PATH" "$VMLINUZ_PATH" "$INITRD_PATH" "$OVMF_CODE"; do
    if [ ! -f "$f" ]; then
        echo "ERROR: Required file not found: $f"
        exit 1
    fi
done

mkdir -p "${ARTIFACTS_DIR}"

# Create a writable copy of OVMF vars
if [ ! -f "$OVMF_LOCAL_VARS" ]; then
    if [ -f "$OVMF_VARS_TEMPLATE" ]; then
        cp "$OVMF_VARS_TEMPLATE" "$OVMF_LOCAL_VARS"
    else
        echo "ERROR: OVMF_VARS template not found at $OVMF_VARS_TEMPLATE"
        echo "Please set OVMF_VARS_TEMPLATE to the correct path for your distro."
        exit 1
    fi
fi

echo "Creating ${DISK_SIZE} raw disk..."
qemu-img create -f raw -o size=${DISK_SIZE} "${ARTIFACTS_DIR}/${RAW_IMAGE_NAME}"

echo ""
echo "Starting Harvester installation in UEFI mode..."
echo "This will run the installer and power off when complete."
echo "Monitor output on the serial console below."
echo "---"

# Key changes from the original script:
#   1. net.ifnames=0: Forces predictable eth0 naming for AWS compatibility
#   2. biosdevname=0: Disables BIOS-based device naming
#   3. harvester.install.tty=ttyS0: Ensures installer targets serial console
#   4. console=ttyS0,115200n8: Serial console with explicit baud rate
#   5. Still using -nic none: No network during build (all images come from ISO)
qemu-system-x86_64 --enable-kvm -nographic \
    -cpu host,+topoext -smp cores=2,threads=2,sockets=1 -m 8192 \
    -serial mon:stdio -serial file:"${ARTIFACTS_DIR}/harvester-installer.log" \
    -nic none \
    -drive file="${ARTIFACTS_DIR}/${RAW_IMAGE_NAME}",if=virtio,cache=writeback,format=raw \
    -drive file="${ISO_PATH}",if=virtio,media=cdrom,readonly=on \
    -drive if=pflash,format=raw,readonly=on,file="${OVMF_CODE}" \
    -drive if=pflash,format=raw,file="${OVMF_LOCAL_VARS}" \
    -kernel "${VMLINUZ_PATH}" \
    -initrd "${INITRD_PATH}" \
    -append "root=live:CDLABEL=COS_LIVE rd.live.dir=/ rd.live.ram=1 rd.live.squashimg=rootfs.squashfs \
console=ttyS0,115200n8 console=tty1 net.ifnames=0 biosdevname=0 rd.cos.disable \
harvester.install.mode=install \
harvester.install.device=/dev/vda \
harvester.install.automatic=true \
harvester.install.powerOff=true \
harvester.install.skipchecks=true \
harvester.install.tty=ttyS0 \
harvester.install.persistentPartitionSize=${PERSISTENT_SIZE} \
harvester.os.password=${OS_PASSWORD} \
harvester.scheme_version=1"

echo ""
echo "---"
echo "QEMU installation complete. Raw image: ${ARTIFACTS_DIR}/${RAW_IMAGE_NAME}"
echo ""
echo "Compressing with zstd..."
zstd -T0 --force "${ARTIFACTS_DIR}/${RAW_IMAGE_NAME}"

echo ""
echo "Step 1 complete!"
echo "  Raw image: ${ARTIFACTS_DIR}/${RAW_IMAGE_NAME}"
echo "  Compressed: ${ARTIFACTS_DIR}/${RAW_IMAGE_NAME}.zst"
echo ""
echo "Next: Run Step 2 to customize for AWS."

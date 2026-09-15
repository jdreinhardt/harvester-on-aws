#!/bin/bash
set -euo pipefail

# =============================================================================
# Phase 2: Customize Harvester Disk for AWS
#
# Run this on an EC2 helper instance after writing the raw image to an EBS
# volume. This script mounts the Harvester partitions and applies all
# AWS-specific modifications.
#
# Usage:
#   sudo ./02-customize-for-aws.sh /dev/nvme1n1
#
# Prerequisites:
#   - An EBS volume with the raw Harvester image written to it
#   - The volume attached to this instance (e.g., /dev/nvme1n1)
#   - Run as root
#
# Partition layout (GPT):
#   p1 = COS_GRUB   (EFI System Partition, FAT16)
#   p2 = COS_OEM    (ext4, OEM cloud-init configs)
#   p3 = COS_RECOVERY
#   p4 = COS_STATE  (ext4, GRUB config, OS images)
#   p5 = COS_PERSISTENT
#   p6 = HARV_LH_DEFAULT (Longhorn default disk)
# =============================================================================

DISK="${1:-}"
if [ -z "$DISK" ]; then
    echo "Usage: $0 <block-device>"
    echo "Example: $0 /dev/nvme1n1"
    exit 1
fi

if [ ! -b "$DISK" ]; then
    echo "ERROR: $DISK is not a block device"
    exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Must run as root"
    exit 1
fi

# Detect partition naming style (nvme uses 'p' prefix)
if [[ "$DISK" == *"nvme"* ]]; then
    P="${DISK}p"
else
    P="${DISK}"
fi

PART_GRUB="${P}1"
PART_OEM="${P}2"
PART_STATE="${P}4"

MNT_GRUB="/mnt/cos_grub"
MNT_OEM="/mnt/cos_oem"
MNT_STATE="/mnt/cos_state"

echo "=== Phase 2: Customize Harvester Disk for AWS ==="
echo ""
echo "Target disk: $DISK"
echo "  COS_GRUB:  $PART_GRUB"
echo "  COS_OEM:   $PART_OEM"
echo "  COS_STATE: $PART_STATE"
echo ""

# --- Cleanup function ---
cleanup() {
    echo ""
    echo "Cleaning up mounts..."
    umount "$MNT_GRUB" 2>/dev/null || true
    umount "$MNT_OEM" 2>/dev/null || true
    umount "$MNT_STATE" 2>/dev/null || true
    rmdir "$MNT_GRUB" "$MNT_OEM" "$MNT_STATE" 2>/dev/null || true
}
trap cleanup EXIT

# --- Mount partitions ---
echo "Mounting partitions..."
mkdir -p "$MNT_GRUB" "$MNT_OEM" "$MNT_STATE"
mount "$PART_GRUB" "$MNT_GRUB"
mount "$PART_OEM" "$MNT_OEM"
mount "$PART_STATE" "$MNT_STATE"

# =============================================================================
# 1. Fix EFI boot path for AWS
# =============================================================================
echo "[1/7] Fixing EFI boot path..."

# AWS UEFI firmware expects /EFI/BOOT/BOOTX64.EFI with exact uppercase.
# FAT is case-insensitive for lookups but preserves the original case in
# directory entries. Since FAT won't let you rename to a different case
# directly, we do a two-step rename through a temp name.
EFI_DIR="$MNT_GRUB/EFI"

if [ -d "$EFI_DIR" ]; then
    # Fix "boot" -> "BOOT" directory case
    if [ -d "$EFI_DIR/BOOT" ] && [ ! -d "$EFI_DIR/boot" ] && [ ! -d "$EFI_DIR/Boot" ]; then
        echo "  EFI/BOOT already correct, skipping"
    else
        cp -r "$EFI_DIR/boot" /tmp/BOOTtmp 2>/dev/null || \
        cp -r "$EFI_DIR/Boot" /tmp/BOOTtmp 2>/dev/null || true
        rm -rf "$EFI_DIR/boot" "$EFI_DIR/Boot" 2>/dev/null || true
        cp -r /tmp/BOOTtmp "$EFI_DIR/BOOT"
        rm -rf /tmp/BOOTtmp
        echo "  Renamed EFI/boot -> EFI/BOOT"
    fi

    # Fix "bootx64.efi" -> "BOOTX64.EFI" filename case
    if [ -d "$EFI_DIR/BOOT" ]; then
        BOOT_DIR="$EFI_DIR/BOOT"
        if [ -f "$BOOT_DIR/BOOTX64.EFI" ] && [ ! -f "$BOOT_DIR/bootx64.efi" ]; then
            echo "  EFI/BOOT/BOOTX64.EFI already correct, skipping"
        else
            cp "$BOOT_DIR/bootx64.efi" "$BOOT_DIR/BOOTX64tmp.EFI" 2>/dev/null || \
            cp "$BOOT_DIR/BOOTX64.EFI" "$BOOT_DIR/BOOTX64tmp.EFI" 2>/dev/null ||true
            rm "$BOOT_DIR/bootx64.efi" 2>/dev/null || true
            cp "$BOOT_DIR/BOOTX64tmp.EFI" "$BOOT_DIR/BOOTX64.EFI"
            rm "$BOOT_DIR/BOOTX64tmp.EFI"
            echo "  Renamed EFI/BOOT/bootx64.efi -> EFI/BOOT/BOOTX64.EFI"
        fi
    fi

    echo "  EFI boot path:"
    ls -la "$EFI_DIR/BOOT/" 2>/dev/null || true
else
    echo "  WARNING: No EFI directory found on COS_GRUB"
fi

# =============================================================================
# 2. Configure GRUB for serial console and AWS kernel params
# =============================================================================
echo "[2/7] Configuring GRUB for serial console..."

GRUB_CUSTOM="$MNT_STATE/grubcustom"
AWS_MARKER="# --- AWS overrides ---"

if [ -f "$GRUB_CUSTOM" ] && grep -q "$AWS_MARKER" "$GRUB_CUSTOM"; then
    echo "  AWS GRUB overrides already present, skipping"
else
    TMPFILE=$(mktemp)
    cat > "$TMPFILE" << GRUBEOF
${AWS_MARKER}
set extra_cmdline="console=ttyS0,115200n8 console=tty1 net.ifnames=0 biosdevname=0"
set extra_active_cmdline="systemd.mount_timeout_sec=300"
${AWS_MARKER}

GRUBEOF

    if [ -f "$GRUB_CUSTOM" ]; then
        cat "$GRUB_CUSTOM" >> "$TMPFILE"
        echo "  Prepended AWS overrides to existing grubcustom"
    else
        echo "  Created new grubcustom with AWS overrides"
    fi
    mv "$TMPFILE" "$GRUB_CUSTOM"
fi

# =============================================================================
# 3. Write 99_aws.yaml cloud-init config
# =============================================================================
echo "[3/7] Writing 99_aws.yaml..."

cat > "$MNT_OEM/99_aws.yaml" << 'AWSEOF'
name: "AWS Nitro Platform Support"
stages:
  initramfs:
    - name: "Load AWS drivers"
      modules:
        - ena
        - nvme
  boot:
    - name: "AWS Network and Config Prep"
      commands:
        - |
          #!/bin/bash
          set -e
          LOGFILE="/var/log/harvester-aws-prep.log"
          exec > >(tee -a "$LOGFILE") 2>&1
          echo "=== AWS Prep started at $(date) ==="

          # 1. Hardware & Network Handshake
          echo "Bringing up eth0 via NetworkManager..."
          for i in $(seq 1 30); do
            if systemctl -q is-active NetworkManager.service; then
              nmcli device set eth0 autoconnect yes || true
              nmcli device connect eth0 || true
              break
            fi
            echo "Waiting for NetworkManager..."
            sleep 2
          done

          # 2. Wait for Primary DHCP (Required to talk to IMDS)
          echo "Waiting for Primary IP..."
          for i in $(seq 1 30); do
            if nmcli -g IP4.ADDRESS device show eth0 | grep -q '\.'; then
              echo "Primary IP is active."
              break
            fi
            sleep 2
          done

          # 3. Fetch IMDSv2 Token
          IMDS_TOKEN=$(curl -sf -X PUT \
            "http://169.254.169.254/latest/api/token" \
            -H "X-aws-ec2-metadata-token-ttl-seconds: 300" 2>/dev/null || true)

          if [ -z "$IMDS_TOKEN" ]; then
            echo "ERROR: Could not get IMDS token"
            exit 1
          fi

          IMDS_HEADER="X-aws-ec2-metadata-token: $IMDS_TOKEN"

          # Fetch user-data
          USERDATA=$(curl -sf -H "$IMDS_HEADER" \
            "http://169.254.169.254/latest/user-data" 2>/dev/null || true)

          if [ -z "$USERDATA" ]; then
            echo "ERROR: No user-data found"
            exit 1
          fi

          # Parse values from user-data
          VIP=$(echo "$USERDATA" | grep -E '^vip:' | awk '{print $2}' | tr -d '"' | tr -d "'")
          TOKEN=$(echo "$USERDATA" | grep -E '^token:' | awk '{print $2}' | tr -d '"' | tr -d "'")
          REPLICA_COUNT=$(echo "$USERDATA" | grep -E '^replica_count:' | awk '{print $2}' | tr -d '"' | tr -d "'")

          TOKEN="${TOKEN:-harvester-aws-$(cat /etc/machine-id | head -c 12)}"
          REPLICA_COUNT="${REPLICA_COUNT:-1}"

          if [ -z "$VIP" ]; then
            echo "ERROR: 'vip' not found in user-data"
            exit 1
          fi

          # 4. Patch Harvester Config ONLY
          HVST_CFG="/oem/harvester.config"
          if [ -f "$HVST_CFG" ]; then
            #sed -i "s|serverurl: \".*\"|serverurl: https://${VIP}:443|" "$HVST_CFG"
            sed -i "s|vip: \".*\"|vip: \"${VIP}\"|" "$HVST_CFG"
            sed -i "s|sans: \[\]|sans: \"[${VIP}]\"|" "$HVST_CFG"
            sed -i "s|vipmode: \".*\"|vip_mode: static|" "$HVST_CFG"
            sed -i "s|mode: .*|mode: create|" "$HVST_CFG"
            sed -i "s|token: \".*\"|token: \"${TOKEN}\"|" "$HVST_CFG"
            sed -i "s|replicacount: .*|replicacount: ${REPLICA_COUNT}|" "$HVST_CFG"
            echo "Successfully patched $HVST_CFG with VIP: $VIP"
          fi

          # Copy post-bootstrap script from OEM partition
          cp /oem/harvester-post-bootstrap.sh /usr/local/bin/harvester-post-bootstrap.sh
          chmod +x /usr/local/bin/harvester-post-bootstrap.sh

          echo "Bootstrap triggered successfully"
AWSEOF

echo "  Wrote 99_aws.yaml to COS_OEM"

# =============================================================================
# 4. Write post-bootstrap script
# =============================================================================
echo "[4/7] Writing harvester-post-bootstrap.sh..."

cat > "$MNT_OEM/harvester-post-bootstrap.sh" << 'POSTEOF'
#!/bin/bash
# =============================================================================
# Harvester Post-Bootstrap for AWS
#
# Runs in the background after rancherd starts. Waits for RKE2 + Rancher,
# then installs the Harvester CRDs and chart via helm.
# =============================================================================
set -euo pipefail

LOGFILE="/var/log/harvester-aws-bootstrap.log"
touch "$LOGFILE"
chmod 600 "$LOGFILE"
exec > >(tee -a "$LOGFILE") 2>&1

export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
export PATH=$PATH:/var/lib/rancher/rke2/bin

echo "=== Post-bootstrap started at $(date) ==="

# ---- Wait for RKE2 API server ----
echo "Waiting for RKE2 API server..."
for i in $(seq 1 120); do
  if kubectl get nodes >/dev/null 2>&1; then
    echo "  API server is ready"
    break
  fi
  [ "$i" -eq 120 ] && { echo "ERROR: Timed out"; exit 1; }
  sleep 10
done

# ---- Wait for Rancher ----
echo "Waiting for Rancher..."
for i in $(seq 1 60); do
  if kubectl -n cattle-system get deploy/rancher >/dev/null 2>&1; then
    kubectl -n cattle-system rollout status deploy/rancher --timeout=300s && break
  fi
  sleep 10
done

# ---- Wait for harvester-cluster-repo ----
echo "Waiting for harvester-cluster-repo..."
for i in $(seq 1 60); do
  if kubectl -n cattle-system get deploy/harvester-cluster-repo >/dev/null 2>&1; then
    kubectl -n cattle-system rollout status deploy/harvester-cluster-repo --timeout=300s && break
  fi
  sleep 10
done

# ---- Create fleet-default namespace ----
echo "Creating fleet-default namespace..."
kubectl create namespace fleet-default 2>/dev/null || true

# ---- Apply monitoring CRD stubs (Longhorn subchart requires these) ----
echo "Applying monitoring CRD stubs..."
kubectl apply -f - << 'CRDEOF'
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: prometheusrules.monitoring.coreos.com
spec:
  group: monitoring.coreos.com
  names:
    kind: PrometheusRule
    listKind: PrometheusRuleList
    plural: prometheusrules
    singular: prometheusrule
  scope: Namespaced
  versions:
  - name: v1
    served: true
    storage: true
    schema:
      openAPIV3Schema:
        type: object
        x-kubernetes-preserve-unknown-fields: true
---
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: servicemonitors.monitoring.coreos.com
spec:
  group: monitoring.coreos.com
  names:
    kind: ServiceMonitor
    listKind: ServiceMonitorList
    plural: servicemonitors
    singular: servicemonitor
  scope: Namespaced
  versions:
  - name: v1
    served: true
    storage: true
    schema:
      openAPIV3Schema:
        type: object
        x-kubernetes-preserve-unknown-fields: true
CRDEOF

# ---- Relabel VolumeSnapshot CRDs ----
echo "Relabeling VolumeSnapshot CRDs for harvester-crd..."
for crd in volumesnapshotclasses.snapshot.storage.k8s.io \
           volumesnapshotcontents.snapshot.storage.k8s.io \
           volumesnapshots.snapshot.storage.k8s.io; do
  kubectl annotate crd "$crd" \
    meta.helm.sh/release-name=harvester-crd \
    meta.helm.sh/release-namespace=harvester-system \
    --overwrite 2>/dev/null || true
  kubectl label crd "$crd" \
    app.kubernetes.io/managed-by=Helm \
    --overwrite 2>/dev/null || true
done

sleep 5

# ---- Get chart repo ClusterIP ----
REPO_IP=$(kubectl get svc -n cattle-system harvester-cluster-repo \
  -o jsonpath='{.spec.clusterIP}')
echo "Chart repo at: ${REPO_IP}"
for i in $(seq 1 10); do
  helm repo add harvester-local "http://${REPO_IP}/charts" && break
  sleep 15
done

# ---- Read VIP from rancherd config ----
VIP=$(grep 'tls-san' -A1 /etc/rancher/rancherd/config.yaml \
  | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)
echo "VIP: ${VIP}"
PREFIX=$(nmcli -g IP4.ADDRESS con show eth0 | grep "${VIP}" | grep -oE '/[0-9]+' | tr -d '/')
if [ -z "$PREFIX" ]; then
  echo "ERROR: Could not determine prefix length for VIP ${VIP} on eth0"
  exit 1
fi
echo "VIP: ${VIP}/${PREFIX}"

# ---- Install Harvester CRDs ----
echo "Installing harvester-crd..."
helm install harvester-crd harvester-local/harvester-crd \
  -n harvester-system --create-namespace \
  --wait --timeout 5m

sleep 10

# ---- Install Harvester ----
echo "Installing harvester..."
helm install harvester harvester-local/harvester \
  -n harvester-system \
  --set longhorn.defaultSettings.defaultReplicaCount=1 \
  --set kube-vip.enabled=true \
  --set kube-vip.config.vip_interface=eth0 \
  --set kube-vip.config.vip_address="${VIP}" \
  --set service.vip.enabled=true \
  --set service.vip.ip="${VIP}" \
  --set harvester-node-disk-manager.enabled=true \
  --set harvester-network-controller.enabled=true \
  --set harvester-load-balancer.enabled=true \
  --wait --timeout 10m

sleep 30

# ---- Patch kube-vip ----
echo "Patching kube-vip..."
DS_ITR=$(kubectl get daemonset kube-vip -n harvester-system \
  -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}{"\n"}{end}' \
  | grep -n vip_interface | cut -d: -f1)

if [[ -z "$DS_ITR" ]]; then
  echo "vip_interface not found, adding it..."
  VIP_INTERFACE_PATCH='{"op": "add", "path": "/spec/template/spec/containers/0/env/-", "value": {"name": "vip_interface", "value": "eth0"}}'
else
  DS_OFFSET=$((DS_ITR - 1))
  VIP_INTERFACE_PATCH="{\"op\": \"replace\", \"path\": \"/spec/template/spec/containers/0/env/${DS_OFFSET}/value\", \"value\": \"eth0\"}"
fi

kubectl patch daemonset kube-vip -n harvester-system --type='json' -p="[
  {
    \"op\": \"add\",
    \"path\": \"/spec/template/spec/containers/0/env/-\",
    \"value\": {\"name\": \"vip_address\", \"value\": \"${VIP}\"}
  },
  ${VIP_INTERFACE_PATCH}
]"

echo "=== Harvester installation complete at $(date) ==="
echo "Management UI: https://${VIP}"
POSTEOF

chmod +x "$MNT_OEM/harvester-post-bootstrap.sh"
echo "  Wrote harvester-post-bootstrap.sh to COS_OEM"

# =============================================================================
# 5. Update harvester.config with AWS defaults
# =============================================================================
echo "[5/7] Updating harvester.config..."

HVST_CONFIG="$MNT_OEM/harvester.config"

if [ -f "$HVST_CONFIG" ]; then
    # Set install device to NVMe (AWS EBS)
    sed -i 's|device: /dev/vda|device: /dev/nvme0n1|' "$HVST_CONFIG"

    # Set mode to create (install phase is already done)
    sed -i 's|mode: install|mode: create|' "$HVST_CONFIG"

    # Set management infterface name
    sed -i 's|interfaces: .*|interfaces: [name: eth0]|' "$HVST_CFG"

    # Set management infterface method
    sed -i 's|method: .*|method: dhcp|' "$HVST_CFG"

    # Set TTY to serial console
    sed -i 's|tty: .*|tty: ttyS0|' "$HVST_CONFIG"

    # Enable silent mode (skip interactive TUI)
    sed -i 's|silent: .*|silent: true|' "$HVST_CONFIG"

    # Set storage class replica count for single-node
    sed -i 's|replicacount: .*|replicacount: 1|' "$HVST_CONFIG"

    # Clear hostname so it can be set dynamically
    if grep -q "hostname:" "$HVST_CONFIG"; then
        sed -i '/hostname:/d' "$HVST_CONFIG"
    fi

    echo "  Patched harvester.config"
else
    echo "  WARNING: harvester.config not found"
fi

# =============================================================================
# 6. Remove stale hostname from 90_custom.yaml
# =============================================================================
echo "[6/7] Cleaning up 90_custom.yaml..."

CUSTOM_YAML="$MNT_OEM/90_custom.yaml"
if [ -f "$CUSTOM_YAML" ]; then
    if grep -q "hostname:" "$CUSTOM_YAML"; then
        sed -i '/- hostname:/d' "$CUSTOM_YAML"
        echo "  Removed hostname from 90_custom.yaml"
    else
        echo "  No hostname found in 90_custom.yaml"
    fi
else
    echo "  No 90_custom.yaml found (this is fine)"
fi

# =============================================================================
# 7. Verify
# =============================================================================
echo "[7/7] Verifying changes..."

echo ""
echo "  harvester.config key values:"
grep -E "mode:|device:|tty:|silent:|replicacount:|vip:|vipmode:" \
    "$MNT_OEM/harvester.config" 2>/dev/null | head -10
echo ""

# --- Summary ---
echo "============================================="
echo "Phase 2 complete!"
echo "============================================="
echo ""
echo "COS_GRUB: EFI boot path fixed (uppercase)"
echo "COS_STATE: grubcustom with serial console + net.ifnames=0"
echo "COS_OEM:"
echo "  - 99_aws.yaml: drivers, NM profile, rancherd config from user-data"
echo "  - harvester-post-bootstrap.sh: CRD stubs, helm chart installs"
echo "  - harvester.config: mode=create, nvme, ttyS0, silent, replica=1"
echo "  - 90_custom.yaml: stale hostname removed"
echo ""
echo "Files on COS_OEM:"
ls -la "$MNT_OEM"/*.yaml "$MNT_OEM"/*.sh "$MNT_OEM"/harvester.config 2>/dev/null || true
echo ""
echo "Boot sequence on first launch:"
echo "  1. initramfs: load ena/nvme, create NM profile"
echo "  2. boot: read EC2 user-data, create rancherd config"
echo "  3. rancherd: bootstrap RKE2 v1.34.3+rke2r3 + Rancher v2.13.1"
echo "  4. post-bootstrap (bg): monitoring CRDs, harvester-crd, harvester chart"
echo ""
echo "Next steps:"
echo "  1. Detach the EBS volume"
echo "  2. Create a snapshot"
echo "  3. Register AMI (UEFI boot mode)"
echo "  4. Launch with user-data: vip: <secondary-ip>"
echo ""

#!/bin/bash
set -euo pipefail

# =============================================================================
# Phase 3: Launch a Harvester node on EC2
#
#   1. Sanity-check the AMI (must be UEFI) and the instance type (must support
#      nested virtualization, or Harvester has no /dev/kvm and KubeVirt cannot
#      run guests)
#   2. Pick a VIP from the subnet if one was not given
#   3. Build the Harvester configuration and pass it as EC2 user-data
#   4. Launch with nested virtualization enabled
#   5. Assign the VIP as a secondary private IP on the instance's ENI
#
# The user-data is a Harvester configuration file:
#   https://docs.harvesterhci.io/latest/install/harvester-configuration/
#
# /oem/aws/configure.sh on the instance fetches it over IMDSv2, fills in
# os.hostname, install.device and os.ssh_authorized_keys, forces
# install.automatic, and writes /oem/userdata.yaml -- which is what
# harvester-installer reads to configure an already-installed disk.
# =============================================================================

INSTANCE_TYPE="m8i.4xlarge"
REPLICA_COUNT="1"
TOKEN=""
VIP=""
AMI=""
SUBNET=""
SG=""
KEY_NAME=""
VOLUME_SIZE="250"
PASSWORD_HASH=""
HOSTNAME_OVERRIDE=""
USER_DATA_FILE=""
DATA_DISK_SIZE="max"
DRY_RUN="false"
NAME_TAG="harvester-node"

usage() {
    cat <<USAGE
Usage: $0 --ami <ami-id> --subnet <subnet-id> --sg <sg-id> [options]

Required:
  --ami            AMI built by phases 1 and 2 (must be boot-mode uefi)
  --subnet         Subnet to launch into
  --sg             Security group

Options:
  --vip            Management VIP. Must be a free address in the subnet; it is
                   assigned to the instance's ENI as a secondary private IP.
                   Auto-selected from the subnet if omitted.
  --token          Cluster token (generated if omitted)
  --instance-type  Default: ${INSTANCE_TYPE}. Must support nested virtualization.
  --key-name       EC2 key pair. Its public key is added to the rancher user.
  --replica-count  Longhorn replica count. Default: ${REPLICA_COUNT} (single node)
  --volume-size    Root volume size in GiB. Default: ${VOLUME_SIZE}, which is also
                   the minimum -- the installer's disk check is not gated by
                   skipchecks. May be larger than the AMI; the Longhorn data
                   partition is grown to match on first boot.
  --data-disk-size How much of the volume to give Longhorn. Default: ${DATA_DISK_SIZE}
                   (everything left over). Or a size such as 200Gi.
  --password-hash  SHA-512 crypt hash for the rancher user. If omitted, the
                   password baked in during phase 1 is kept.
                   Generate one with:  mkpasswd -m sha-512
  --hostname       Node hostname. Default: harvester-<instance-id>
  --user-data-file Use this file as the Harvester configuration verbatim
                   instead of generating one.
  --name           Name tag. Default: ${NAME_TAG}
  --dry-run        Print the configuration and the launch parameters, then stop.
  -h, --help       Show this help.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ami)            AMI="$2"; shift 2 ;;
        --subnet)         SUBNET="$2"; shift 2 ;;
        --sg)             SG="$2"; shift 2 ;;
        --vip)            VIP="$2"; shift 2 ;;
        --token)          TOKEN="$2"; shift 2 ;;
        --instance-type)  INSTANCE_TYPE="$2"; shift 2 ;;
        --key-name)       KEY_NAME="$2"; shift 2 ;;
        --replica-count)  REPLICA_COUNT="$2"; shift 2 ;;
        --volume-size)    VOLUME_SIZE="$2"; shift 2 ;;
        --password-hash)  PASSWORD_HASH="$2"; shift 2 ;;
        --hostname)       HOSTNAME_OVERRIDE="$2"; shift 2 ;;
        --user-data-file) USER_DATA_FILE="$2"; shift 2 ;;
        --data-disk-size) DATA_DISK_SIZE="$2"; shift 2 ;;
        --name)           NAME_TAG="$2"; shift 2 ;;
        --dry-run)        DRY_RUN="true"; shift ;;
        -h|--help)        usage; exit 0 ;;
        *)                echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
done

if [ -z "$AMI" ] || [ -z "$SUBNET" ] || [ -z "$SG" ]; then
    echo "ERROR: --ami, --subnet and --sg are required" >&2
    echo "" >&2
    usage >&2
    exit 1
fi

command -v aws >/dev/null || { echo "ERROR: aws CLI not found" >&2; exit 1; }

echo "=== Phase 3: Launch Harvester on EC2 ==="
echo ""

# -----------------------------------------------------------------------------
# Preflight
# -----------------------------------------------------------------------------
echo "Checking the AMI..."
BOOT_MODE="$(aws ec2 describe-images --image-ids "$AMI" \
    --query 'Images[0].BootMode' --output text 2>/dev/null || echo "None")"
if [ "$BOOT_MODE" != "uefi" ]; then
    echo "ERROR: AMI $AMI has boot mode '${BOOT_MODE}', not 'uefi'." >&2
    echo "       Harvester no longer supports legacy BIOS (preflight.BIOSCheck)." >&2
    echo "       Re-register the snapshot with --boot-mode uefi." >&2
    exit 1
fi
echo "  boot mode: uefi"

AMI_VOLUME_SIZE="$(aws ec2 describe-images --image-ids "$AMI" \
    --query 'Images[0].BlockDeviceMappings[0].Ebs.VolumeSize' --output text 2>/dev/null || echo 0)"
echo "  AMI snapshot volume: ${AMI_VOLUME_SIZE} GiB"

# harvester-installer's checkDevice() -> validateDiskSize() compares the install
# disk against config.SingleDiskMinSizeGiB, and unlike the preflight checks it is
# NOT gated by harvester.install.skipchecks. The AMI may be built smaller, but
# the volume it is launched on cannot be.
if [ "$VOLUME_SIZE" -lt 250 ]; then
    echo "ERROR: --volume-size ${VOLUME_SIZE} is below the 250 GiB the installer requires." >&2
    echo "       validateDiskSize() in harvester-installer is unconditional, so the" >&2
    echo "       node would refuse to configure itself. Build a smaller AMI if you" >&2
    echo "       want faster snapshots, but launch it on 250 GiB or more." >&2
    exit 1
fi
if [ "${AMI_VOLUME_SIZE:-0}" -gt 0 ] && [ "$VOLUME_SIZE" -lt "$AMI_VOLUME_SIZE" ]; then
    echo "ERROR: --volume-size ${VOLUME_SIZE} is smaller than the AMI's snapshot (${AMI_VOLUME_SIZE} GiB)." >&2
    echo "       EBS cannot shrink a volume below its snapshot size." >&2
    exit 1
fi

echo "Checking the instance type..."
NESTED="$(aws ec2 describe-instance-types --instance-types "$INSTANCE_TYPE" \
    --query 'InstanceTypes[0].ProcessorInfo.SupportedFeatures' --output text 2>/dev/null || true)"
if [[ "$NESTED" != *"nested-virtualization"* ]]; then
    echo "ERROR: $INSTANCE_TYPE does not support nested virtualization." >&2
    echo "       Harvester requires /dev/kvm (preflight.KVMHostCheck) and" >&2
    echo "       KubeVirt cannot run guests without it." >&2
    echo "       List supported types with:" >&2
    echo "         aws ec2 describe-instance-types \\" >&2
    echo "           --filters Name=processor-info.supported-features,Values=nested-virtualization \\" >&2
    echo "           --query 'InstanceTypes[].InstanceType' --output text" >&2
    exit 1
fi
echo "  $INSTANCE_TYPE supports nested virtualization"

SUBNET_CIDR="$(aws ec2 describe-subnets --subnet-ids "$SUBNET" \
    --query 'Subnets[0].CidrBlock' --output text)"
echo "  subnet $SUBNET is $SUBNET_CIDR"

# -----------------------------------------------------------------------------
# VIP selection
# -----------------------------------------------------------------------------
# Harvester's management plane lives on a VIP served by kube-vip. Inside a VPC
# an address only reaches the instance if it is registered on the ENI, so the
# VIP has to be a secondary private IP of this instance. It must be chosen
# before launch because it goes into user-data.
if [ -z "$VIP" ]; then
    echo "No --vip given; selecting a free address from $SUBNET_CIDR..."
    command -v python3 >/dev/null || {
        echo "ERROR: python3 not found, cannot auto-select a VIP. Pass --vip." >&2
        exit 1
    }
    USED_IPS="$(aws ec2 describe-network-interfaces \
        --filters "Name=subnet-id,Values=$SUBNET" \
        --query 'NetworkInterfaces[].PrivateIpAddresses[].PrivateIpAddress' \
        --output text | tr '\t' '\n' | sed '/^$/d')"
    VIP="$(SUBNET_CIDR="$SUBNET_CIDR" USED_IPS="$USED_IPS" python3 <<'PY'
import ipaddress, os, sys
net = ipaddress.ip_network(os.environ["SUBNET_CIDR"])
used = {l.strip() for l in os.environ["USED_IPS"].splitlines() if l.strip()}
# AWS reserves the first four addresses and the last one in every subnet.
for ip in reversed(list(net.hosts())[3:-1]):
    if str(ip) not in used:
        print(ip)
        break
else:
    sys.exit("no free address found in the subnet")
PY
)" || { echo "ERROR: could not auto-select a VIP" >&2; exit 1; }
    echo "  selected VIP: $VIP"
else
    if command -v python3 >/dev/null; then
        SUBNET_CIDR="$SUBNET_CIDR" VIP="$VIP" python3 <<'PY' || exit 1
import ipaddress, os, sys
net = ipaddress.ip_network(os.environ["SUBNET_CIDR"])
vip = ipaddress.ip_address(os.environ["VIP"])
if vip not in net:
    sys.exit(f"ERROR: VIP {vip} is not inside subnet {net}")
PY
    fi
    echo "Using VIP: $VIP"
fi

if [ -z "$TOKEN" ]; then
    if command -v openssl >/dev/null; then
        TOKEN="harvester-aws-$(openssl rand -hex 8)"
    else
        TOKEN="harvester-aws-$(date +%s)-$RANDOM"
    fi
    echo "Generated cluster token: $TOKEN"
fi

if [ -n "$PASSWORD_HASH" ]; then
    case "$PASSWORD_HASH" in
        '$'*) : ;;
        *)
            echo "ERROR: --password-hash must be a crypt hash, not a plaintext password." >&2
            echo "       It is written verbatim to /etc/shadow; a plaintext value" >&2
            echo "       disables password login rather than setting it." >&2
            echo "       Generate one with:  mkpasswd -m sha-512" >&2
            exit 1
            ;;
    esac
fi

# -----------------------------------------------------------------------------
# Harvester configuration (EC2 user-data)
# -----------------------------------------------------------------------------
# Build the configuration in a temp file and hand the CLI a file:// reference.
# Not just tidier: a heredoc nested inside $( ... ) is mis-parsed by bash 3.2,
# which is what macOS still ships, and this script is the one that runs on a
# workstation rather than on Linux.
USERDATA_FILE="$(mktemp "${TMPDIR:-/tmp}/harvester-userdata.XXXXXX")"
cleanup_userdata() { rm -f "$USERDATA_FILE"; }
trap cleanup_userdata EXIT

if [ -n "$USER_DATA_FILE" ]; then
    [ -f "$USER_DATA_FILE" ] || { echo "ERROR: $USER_DATA_FILE not found" >&2; exit 1; }
    cat "$USER_DATA_FILE" > "$USERDATA_FILE"
else
    cat > "$USERDATA_FILE" <<EOF
# Harvester configuration, consumed by /oem/aws/configure.sh over IMDSv2 and
# written to /oem/userdata.yaml for harvester-installer.
# https://docs.harvesterhci.io/latest/install/harvester-configuration/
# aws.* is consumed by /oem/aws/configure.sh on the node and stripped before
# the file is handed to harvester-installer.
aws:
  data_disk_size: "${DATA_DISK_SIZE}"
scheme_version: 1
token: "${TOKEN}"
install:
  automatic: true
  mode: create
  management_interface:
    interfaces:
      - name: eth0
    method: dhcp
    # Harvester always puts a bond (mgmt-bo) under the management bridge. In
    # active-backup mode the bonding driver rewrites each slave's MAC to the
    # bond's, and ENA refuses with -EOPNOTSUPP, which aborts the enslavement:
    #   mgmt-bo: (slave eth0): Error -95 calling set_mac_address
    # fail_over_mac=active skips that; the bond takes the ENI's MAC instead.
    # All three must be set together -- the installer only supplies its own
    # mode/miimon defaults when bond_options is absent entirely.
    bond_options:
      mode: "active-backup"
      miimon: "100"
      fail_over_mac: "active"
  vip: "${VIP}"
  vip_mode: static
  harvester:
    storage_class:
      replica_count: ${REPLICA_COUNT}
EOF
    if [ -n "$HOSTNAME_OVERRIDE" ] || [ -n "$PASSWORD_HASH" ]; then
        echo "os:" >> "$USERDATA_FILE"
        if [ -n "$HOSTNAME_OVERRIDE" ]; then
            echo "  hostname: \"${HOSTNAME_OVERRIDE}\"" >> "$USERDATA_FILE"
        fi
        if [ -n "$PASSWORD_HASH" ]; then
            echo "  password: \"${PASSWORD_HASH}\"" >> "$USERDATA_FILE"
        fi
    fi
fi

echo ""
echo "Harvester configuration to be passed as user-data:"
echo "---"
sed 's/^/  /' "$USERDATA_FILE"
echo "---"
echo ""

# -----------------------------------------------------------------------------
# Launch
# -----------------------------------------------------------------------------
LAUNCH_ARGS=(
    --image-id "$AMI"
    --instance-type "$INSTANCE_TYPE"
    --subnet-id "$SUBNET"
    --security-group-ids "$SG"
    --block-device-mappings "[{\"DeviceName\":\"/dev/sda1\",\"Ebs\":{\"VolumeSize\":${VOLUME_SIZE},\"VolumeType\":\"gp3\",\"DeleteOnTermination\":true}}]"
    # Nested virtualization is opt-in per instance. Without this there is no
    # /dev/kvm even on a supported instance type.
    --cpu-options "NestedVirtualization=enabled"
    # IMDSv2 only. /oem/aws/configure.sh does the token handshake. Hop limit 2
    # so pods can reach IMDS if they need to.
    --metadata-options "HttpTokens=required,HttpPutResponseHopLimit=2,HttpEndpoint=enabled"
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${NAME_TAG}}]"
    --user-data "file://$USERDATA_FILE"
)
[ -n "$KEY_NAME" ] && LAUNCH_ARGS+=(--key-name "$KEY_NAME")

if [ "$DRY_RUN" = "true" ]; then
    echo "Dry run. Would launch with:"
    printf '  %q\n' "${LAUNCH_ARGS[@]}"
    echo ""
    echo "VIP to assign after launch: $VIP"
    exit 0
fi

echo "Launching instance..."
if ! INSTANCE_INFO="$(aws ec2 run-instances "${LAUNCH_ARGS[@]}" \
        --query 'Instances[0].[InstanceId,NetworkInterfaces[0].NetworkInterfaceId]' \
        --output text)"; then
    echo "" >&2
    echo "ERROR: run-instances failed." >&2
    echo "       If it rejected NestedVirtualization, your aws CLI predates the" >&2
    echo "       feature. Check with 'aws --version' and upgrade; nested" >&2
    echo "       virtualization is what gives Harvester /dev/kvm." >&2
    exit 1
fi

INSTANCE_ID="$(echo "$INSTANCE_INFO" | awk '{print $1}')"
ENI_ID="$(echo "$INSTANCE_INFO" | awk '{print $2}')"

echo "  Instance ID: $INSTANCE_ID"
echo "  ENI ID:      $ENI_ID"

# Assign the VIP straight away -- the ENI exists as soon as the instance is
# created, and this has to land before kube-vip starts advertising the address.
echo "Assigning VIP ${VIP} as a secondary private IP on ${ENI_ID}..."
if ! aws ec2 assign-private-ip-addresses \
        --network-interface-id "$ENI_ID" \
        --private-ip-addresses "$VIP" >/dev/null; then
    echo "" >&2
    echo "ERROR: failed to assign ${VIP} to ${ENI_ID}." >&2
    echo "       Without it the VPC will not route the VIP to this instance and" >&2
    echo "       the Harvester UI and API will be unreachable." >&2
    echo "       Fix it and re-run:" >&2
    echo "         aws ec2 assign-private-ip-addresses \\" >&2
    echo "           --network-interface-id $ENI_ID --private-ip-addresses $VIP" >&2
    echo "       Then reboot the instance." >&2
    exit 1
fi
echo "  assigned"

echo "Waiting for the instance to reach 'running'..."
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"

read -r PRIMARY_IP PUBLIC_IP AZ <<<"$(aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].[PrivateIpAddress,PublicIpAddress,Placement.AvailabilityZone]' \
    --output text)"
[ "$PUBLIC_IP" = "None" ] && PUBLIC_IP=""
SSH_TARGET="${PUBLIC_IP:-$PRIMARY_IP}"

SERIAL_ENABLED="$(aws ec2 get-serial-console-access-status \
    --query 'SerialConsoleAccessEnabled' --output text 2>/dev/null || echo "unknown")"

cat <<SUMMARY

=============================================
Harvester instance launched
=============================================

  Instance ID:    $INSTANCE_ID
  Instance type:  $INSTANCE_TYPE  (nested virtualization enabled)
  Availability:   $AZ
  Primary IP:     $PRIMARY_IP
  VIP:            $VIP
  Public IP:      ${PUBLIC_IP:-none}
  Cluster token:  $TOKEN
  Root volume:    ${VOLUME_SIZE} GiB (Longhorn data partition: ${DATA_DISK_SIZE})

First boot writes /oem/userdata.yaml from user-data, then the installer
configures the node and rancherd bootstraps RKE2, Rancher and the Harvester
charts. Expect 15-25 minutes.

Watch it:

  # Serial console (this is where everything is logged; serial console
  # access for this account is currently: ${SERIAL_ENABLED})
  aws ec2-instance-connect send-serial-console-ssh-public-key \\
    --instance-id $INSTANCE_ID --serial-port 0 \\
    --ssh-public-key file://~/.ssh/id_rsa.pub
  ssh ${INSTANCE_ID}.port0@serial-console.ec2-instance-connect.${AZ%?}.aws

  # Or just poll the console buffer
  aws ec2 get-console-output --instance-id $INSTANCE_ID --latest --output text

  # Once SSH is up
  ssh rancher@${SSH_TARGET}
  sudo journalctl -u harvester-aws-config      # user-data -> /oem/userdata.yaml
  sudo cat /var/log/console.log                # harvester-installer
  sudo journalctl -fu rancherd                 # cluster bootstrap
  sudo kubectl get managedchart -n fleet-local # harvester / harvester-crd

  # Harvester UI, once the bootstrap finishes
  https://${VIP}    admin / admin

Security group ${SG} needs at least:
  22    SSH
  443   Harvester UI and API (on the VIP)
  6443  Kubernetes API
  9345  RKE2 supervisor
and unrestricted traffic within the group itself for the single-node case.
SUMMARY

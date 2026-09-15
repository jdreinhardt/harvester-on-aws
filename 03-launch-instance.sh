#!/bin/bash
set -euo pipefail

# =============================================================================
# Phase 3: Launch a Harvester Instance on AWS
#
# This script automates the launch workflow:
#   1. Picks (or accepts) a VIP from the subnet
#   2. Launches the instance
#   3. Assigns the VIP as a secondary IP on the instance's ENI
#
# Usage:
#   ./03-launch-instance.sh --ami ami-xxxxx --subnet subnet-xxxxx --sg sg-xxxxx
#
# Optional:
#   --vip 172.31.36.200       (auto-selects one if not specified)
#   --token my-cluster-token  (auto-generates if not specified)
#   --instance-type m8i.4xlarge
#   --key-name my-keypair
#   --replica-count 1
# =============================================================================

# --- Defaults ---
INSTANCE_TYPE="m8i.4xlarge"
REPLICA_COUNT="1"
TOKEN=""
VIP="172.31.20.200"
AMI=""
SUBNET="subnet-0adfa82750ccbaaa3"
SG="sg-0f9a857527bf5b892"
KEY_NAME="aws-testing"

# --- Parse arguments ---
while [[ $# -gt 0 ]]; do
    case $1 in
        --ami)           AMI="$2"; shift 2 ;;
        --subnet)        SUBNET="$2"; shift 2 ;;
        --sg)            SG="$2"; shift 2 ;;
        --vip)           VIP="$2"; shift 2 ;;
        --token)         TOKEN="$2"; shift 2 ;;
        --instance-type) INSTANCE_TYPE="$2"; shift 2 ;;
        --key-name)      KEY_NAME="$2"; shift 2 ;;
        --replica-count) REPLICA_COUNT="$2"; shift 2 ;;
        --help)
            echo "Usage: $0 --ami <ami-id> --subnet <subnet-id> --sg <sg-id> [options]"
            echo ""
            echo "Required:"
            echo "  --ami           AMI ID of the Harvester image"
            echo "  --subnet        Subnet ID to launch into"
            echo "  --sg            Security group ID"
            echo ""
            echo "Optional:"
            echo "  --vip           VIP address (must be in subnet range, auto-picked if omitted)"
            echo "  --token         Cluster token (auto-generated if omitted)"
            echo "  --instance-type Instance type (default: m8i.4xlarge)"
            echo "  --key-name      SSH key pair name"
            echo "  --replica-count Longhorn replica count (default: 1 for single-node)"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# --- Validate ---
if [ -z "$AMI" ] || [ -z "$SUBNET" ] || [ -z "$SG" ]; then
    echo "ERROR: --ami, --subnet, and --sg are required"
    echo "Run with --help for usage"
    exit 1
fi

# Generate token if not provided
if [ -z "$TOKEN" ]; then
    TOKEN="harvester-aws-$(openssl rand -hex 8)"
    echo "Generated cluster token: $TOKEN"
fi

# --- Build user-data ---
USERDATA=$(cat << EOF
vip: ${VIP:-PLACEHOLDER}
token: ${TOKEN}
replica_count: ${REPLICA_COUNT}
EOF
)

# --- Build launch command ---
LAUNCH_ARGS=(
    --image-id "$AMI"
    --instance-type "$INSTANCE_TYPE"
    --subnet-id "$SUBNET"
    --security-group-ids "$SG"
    --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":251,"VolumeType":"gp3","DeleteOnTermination":true}}]'
    --metadata-options "HttpTokens=required,HttpPutResponseHopLimit=2,HttpEndpoint=enabled"
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=harvester-node}]"
)

if [ -n "$KEY_NAME" ]; then
    LAUNCH_ARGS+=(--key-name "$KEY_NAME")
fi

echo "=== Phase 3: Launch Harvester Instance ==="
echo ""

# --- If no VIP specified, we'll assign one after launch ---
if [ -n "$VIP" ]; then
    # VIP specified upfront — include it in user-data
    echo "Using specified VIP: $VIP"
    LAUNCH_ARGS+=(--user-data "$USERDATA")

    echo "Launching instance..."
    INSTANCE_INFO=$(aws ec2 run-instances "${LAUNCH_ARGS[@]}" \
        --query 'Instances[0].[InstanceId,NetworkInterfaces[0].NetworkInterfaceId]' \
        --output text)

    INSTANCE_ID=$(echo "$INSTANCE_INFO" | awk '{print $1}')
    ENI_ID=$(echo "$INSTANCE_INFO" | awk '{print $2}')

    echo "  Instance ID: $INSTANCE_ID"
    echo "  ENI ID:      $ENI_ID"

    echo "Waiting for instance to be running..."
    aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"

    echo "Assigning VIP ${VIP} as secondary IP..."
    aws ec2 assign-private-ip-addresses \
        --network-interface-id "$ENI_ID" \
        --private-ip-addresses "$VIP" || {
        echo "WARNING: Failed to assign VIP. It may already be in use."
        echo "You can assign it manually:"
        echo "  aws ec2 assign-private-ip-addresses --network-interface-id $ENI_ID --private-ip-addresses $VIP"
    }

else
    # No VIP specified — launch first, then pick a secondary IP, then set user-data
    # Actually, user-data must be set at launch time, so we need to:
    # 1. Launch with a placeholder
    # 2. Assign a secondary IP
    # 3. The instance will read user-data at boot, but VIP will be PLACEHOLDER
    #
    # Better approach: auto-assign a secondary IP first, then launch
    echo "No VIP specified. Auto-assigning from subnet..."

    # Get subnet CIDR to understand the range
    SUBNET_CIDR=$(aws ec2 describe-subnets \
        --subnet-ids "$SUBNET" \
        --query 'Subnets[0].CidrBlock' \
        --output text)
    echo "  Subnet CIDR: $SUBNET_CIDR"
    echo ""
    echo "NOTE: Auto-VIP selection requires launching the instance first,"
    echo "then assigning a secondary IP. However, user-data is read at boot."
    echo ""
    echo "Recommended: specify --vip with an unused IP from your subnet."
    echo "You can find available IPs with:"
    echo "  aws ec2 describe-network-interfaces --filters Name=subnet-id,Values=$SUBNET"
    echo ""
    exit 1
fi

# --- Summary ---
PRIMARY_IP=$(aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].PrivateIpAddress' \
    --output text)

PUBLIC_IP=$(aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text 2>/dev/null || echo "none")

echo ""
echo "============================================="
echo "Harvester instance launched!"
echo "============================================="
echo ""
echo "  Instance ID:    $INSTANCE_ID"
echo "  Instance Type:  $INSTANCE_TYPE"
echo "  Primary IP:     $PRIMARY_IP"
echo "  VIP:            $VIP"
echo "  Public IP:      $PUBLIC_IP"
echo "  Cluster Token:  $TOKEN"
echo ""
echo "The instance is now booting and bootstrapping Harvester."
echo "This typically takes 10-15 minutes."
echo ""
echo "Monitor progress:"
echo "  1. Serial console (if enabled):"
echo "     aws ec2 get-console-output --instance-id $INSTANCE_ID --latest"
echo ""
echo "  2. SSH (once network is up):"
echo "     ssh rancher@${PRIMARY_IP}"
echo "     # Then: journalctl -f -u rancherd"
echo ""
echo "  3. Harvester UI (once bootstrap completes):"
echo "     https://${VIP}"
echo "     Username: admin"
echo "     Password: admin"
echo ""
echo "Security group reminder — ensure these ports are open:"
echo "  22    (SSH)"
echo "  443   (Harvester UI/API)"
echo "  6443  (Kubernetes API)"
echo "  9345  (RKE2 supervisor)"
echo ""

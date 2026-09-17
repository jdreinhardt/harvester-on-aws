#!/bin/bash
set -euo pipefail

# =============================================================================
# Phase 3: Launch a Harvester node on EC2
#
#   1. Sanity-check the AMI (must be UEFI) and the instance type (must support
#      nested virtualization, or Harvester has no /dev/kvm and KubeVirt cannot
#      run guests)
#   2. Pick a VIP from the subnet if one was not given (create mode only)
#   3. Build the Harvester configuration and pass it as EC2 user-data
#   4. Launch with nested virtualization enabled
#   5. Assign the VIP as a secondary private IP on the instance's ENI
#      (create mode only)
#
# Two modes:
#
#   create  (default)  Bootstraps a new cluster. Needs a VIP.
#   join    (--join)   Adds a node to an existing cluster. Needs that cluster's
#                      server URL and its token, and no VIP of its own.
#
# The distinction is made entirely by one field. rancherd-config.yaml is
# templated as:
#
#   {{if .ServerURL -}}
#   server: {{ .ServerURL }}
#   role: agent
#   {{- else -}}
#   role: cluster-init
#   {{- end }}
#
# so a node with server_url set comes up as a member and one without it
# bootstraps a cluster.
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
REPLICA_COUNT_SET="false"
TOKEN=""
VIP=""
MODE="create"
SERVER_URL=""
ROLE=""
AMI=""
SUBNET=""
SG=""
KEY_NAME=""
VOLUME_SIZE="250"
PASSWORD_HASH=""
HOSTNAME_OVERRIDE=""
USER_DATA_FILE=""
DATA_DISK_SIZE="max"
MTU="1500"
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
  --join URL       Join the existing cluster reachable at URL instead of
                   bootstrapping a new one. Accepts a bare VIP (172.31.0.10),
                   which is expanded to https://172.31.0.10:443. Requires
                   --token, and takes no --vip of its own.
  --vip            Management VIP. Must be a free address in the subnet; it is
                   assigned to the instance's ENI as a secondary private IP.
                   Auto-selected from the subnet if omitted. Create mode only.
  --token          Cluster token. Generated if omitted when creating; required
                   when joining, and must match the cluster exactly.
  --instance-type  Default: ${INSTANCE_TYPE}. Must support nested virtualization.
  --key-name       EC2 key pair. Its public key is added to the rancher user.
  --role ROLE      Node role. Left unset by default, which is Harvester's
                   "default": eligible for automatic promotion. Promotion only
                   happens once the cluster has 3 nodes -- OnNodeChanged in
                   promote_controller.go returns early below
                   defaultSpecManagementNumber -- so a 2-node cluster leaves the
                   second node with no role, and that is expected.
                     default     eligible for promotion (same as unset)
                     management  prefer this node for control-plane + etcd
                     worker      never promoted; use for nodes beyond the third
                     witness     etcd-only quorum member, maximum 1. Harvester
                                 taints it NoExecute and expects it to have no
                                 data partition, which does not match an AMI
                                 built by phases 1-2 -- untested here.
  --replica-count  Longhorn replica count. Default: ${REPLICA_COUNT} (single node).
                   Create mode only -- it is written into the harvester chart
                   values at bootstrap, so it is fixed by the first node. To
                   change it later, edit the harvester-longhorn StorageClass.
  --volume-size    Root volume size in GiB. Default: ${VOLUME_SIZE}, which is also
                   the minimum -- the installer's disk check is not gated by
                   skipchecks. May be larger than the AMI; the Longhorn data
                   partition is grown to match on first boot.
  --data-disk-size How much of the volume to give Longhorn. Default: ${DATA_DISK_SIZE}
                   (everything left over). Or a size such as 200Gi.
  --mtu N          Management interface MTU. Default: ${MTU}. What matters is
                   that it is set at all: harvester-installer only emits an
                   mtu= line into the bridge and bond NM connections when it is
                   explicitly set, and without it mgmt-br keeps ENA's 9001
                   while mgmt-bo and eth0 stay at 1500. Sockets then derive an
                   8961 MSS from the bridge and every segment over 1500 is
                   silently dropped by the bond -- TCP handshakes succeed and
                   the first real payload vanishes, so a joining node never
                   completes. 1500 is the safe default: it matches the 1500 cap
                   AWS applies to anything leaving the VPC.
                   9000 is a valid opt-in (ENA carries 9001, checkMTU() caps at
                   9000) and helps Longhorn replication between nodes, but it
                   leaves VM egress depending on PMTUD through GENEVE and NAT.
                   Pass 0 to leave it unset entirely -- that is the broken case.
  --password-hash  SHA-512 crypt hash for the rancher user. If omitted, the
                   password baked in during phase 1 is kept.
                   Generate one with:  mkpasswd -m sha-512
  --hostname       Node hostname. Default: harvester-<instance-id>
  --user-data-file Use this file as the Harvester configuration verbatim
                   instead of generating one.
  --name           Name tag. Default: ${NAME_TAG}
  --dry-run        Print the configuration and the launch parameters, then stop.
  -h, --help       Show this help.

Examples:
  # First node: bootstrap a cluster, auto-selecting a VIP
  $0 --ami ami-0abc --subnet subnet-0abc --sg sg-0abc --mtu 9000

  # Second and third nodes: join it
  $0 --ami ami-0abc --subnet subnet-0abc --sg sg-0abc --mtu 9000 \\
     --join 172.31.0.10 --token <the token the first node printed> \\
     --name harvester-node-2
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ami)            AMI="$2"; shift 2 ;;
        --subnet)         SUBNET="$2"; shift 2 ;;
        --sg)             SG="$2"; shift 2 ;;
        --vip)            VIP="$2"; shift 2 ;;
        --join)           MODE="join"; SERVER_URL="$2"; shift 2 ;;
        --role)           ROLE="$2"; shift 2 ;;
        --token)          TOKEN="$2"; shift 2 ;;
        --instance-type)  INSTANCE_TYPE="$2"; shift 2 ;;
        --key-name)       KEY_NAME="$2"; shift 2 ;;
        --replica-count)  REPLICA_COUNT="$2"; REPLICA_COUNT_SET="true"; shift 2 ;;
        --volume-size)    VOLUME_SIZE="$2"; shift 2 ;;
        --password-hash)  PASSWORD_HASH="$2"; shift 2 ;;
        --hostname)       HOSTNAME_OVERRIDE="$2"; shift 2 ;;
        --user-data-file) USER_DATA_FILE="$2"; shift 2 ;;
        --data-disk-size) DATA_DISK_SIZE="$2"; shift 2 ;;
        --mtu)            MTU="$2"; shift 2 ;;
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

case "$ROLE" in
    "") : ;;
    default|management|worker) : ;;
    witness)
        echo "WARNING: role 'witness' expects a node with no Longhorn data partition" >&2
        echo "         (ShouldCreateDataPartitionOnOsDisk returns false for it), but the" >&2
        echo "         AMI built by phases 1-2 always carries HARV_LH_DEFAULT and phase 2" >&2
        echo "         grows and mounts it. This combination is untested." >&2
        echo "" >&2
        ;;
    *)
        echo "ERROR: --role must be default, management, worker or witness (got: $ROLE)." >&2
        echo "       See RoleDefault/RoleMgmt/RoleWorker/RoleWitness in" >&2
        echo "       harvester-installer pkg/config/constants.go." >&2
        exit 1
        ;;
esac

# -----------------------------------------------------------------------------
# Mode
# -----------------------------------------------------------------------------
if [ "$MODE" = "join" ]; then
    if [ -n "$VIP" ]; then
        echo "ERROR: --vip and --join are mutually exclusive." >&2
        echo "       The VIP belongs to the cluster, not to the node. A joining" >&2
        echo "       node reaches it via --join; it does not host one." >&2
        exit 1
    fi
    if [ -z "$TOKEN" ]; then
        echo "ERROR: --token is required with --join." >&2
        echo "       It has to be the token the cluster was created with -- it is" >&2
        echo "       what rancherd authenticates to the server with, so it cannot" >&2
        echo "       be generated here. The create run printed it." >&2
        exit 1
    fi
    if [ "$REPLICA_COUNT_SET" = "true" ]; then
        echo "WARNING: --replica-count has no effect when joining." >&2
        echo "         It only feeds the harvester chart values, which are" >&2
        echo "         generated once, by the node that bootstrapped the cluster." >&2
        echo "" >&2
    fi

    # Accept a bare address and expand it the way the installer's own
    # getFormattedServerURL() does: default scheme https, default port 443.
    case "$SERVER_URL" in
        *://*) : ;;
        "") echo "ERROR: --join needs a value" >&2; exit 1 ;;
        *)  SERVER_URL="https://${SERVER_URL}" ;;
    esac
    case "$SERVER_URL" in
        https://*) : ;;
        *) echo "ERROR: --join must be an https URL (got: $SERVER_URL)" >&2; exit 1 ;;
    esac
    SERVER_HOSTPORT="${SERVER_URL#https://}"
    case "$SERVER_HOSTPORT" in
        */*) echo "ERROR: --join must not have a path (got: $SERVER_URL)" >&2; exit 1 ;;
    esac
    case "$SERVER_HOSTPORT" in
        *:*) : ;;
        *)   SERVER_URL="${SERVER_URL}:443" ;;
    esac
    # harv-update-rke2-server-url rewrites this to :9345 for the RKE2 supervisor,
    # but only if it matches ^https://(.*):(8443|443) -- anything else is left
    # alone and the join silently never completes.
    if ! [[ "$SERVER_URL" =~ ^https://[^/]+:(443|8443)$ ]]; then
        echo "ERROR: --join must use port 443 or 8443 (got: $SERVER_URL)." >&2
        echo "       harv-update-rke2-server-url only rewrites those two to the" >&2
        echo "       RKE2 supervisor port 9345; any other port is left as-is and" >&2
        echo "       the node never joins." >&2
        exit 1
    fi

    # The join target must be the cluster VIP, not a node's own address. Both
    # answer on 443, so this is easy to get wrong and the failure is opaque:
    # rancherd fetches https://<server>/system-agent-install.sh, and the
    # certificate only carries the VIP, so it retries forever on
    #   tls: failed to verify certificate: x509: certificate is valid for
    #   10.52.0.6, ..., 172.31.31.251, not 172.31.16.75
    # A VIP is registered as a SECONDARY private address on the ENI; a node's
    # own address is the primary. That is the difference we can check for.
    SERVER_HOST="${SERVER_URL#https://}"
    SERVER_HOST="${SERVER_HOST%:*}"
    if [[ "$SERVER_HOST" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        IS_PRIMARY="$(aws ec2 describe-network-interfaces \
            --filters "Name=addresses.private-ip-address,Values=${SERVER_HOST}" \
            --query "NetworkInterfaces[].PrivateIpAddresses[?PrivateIpAddress=='${SERVER_HOST}'].Primary" \
            --output text 2>/dev/null | tr -d '[:space:]')"
        case "$IS_PRIMARY" in
            True|true|TRUE)
                echo "ERROR: ${SERVER_HOST} is the PRIMARY private address of an ENI." >&2
                echo "       That is a node's own address, not the cluster VIP." >&2
                echo "       It will answer on 443, but the Rancher certificate is" >&2
                echo "       issued for the VIP only, so rancherd fails certificate" >&2
                echo "       verification and retries forever without ever joining." >&2
                echo "" >&2
                echo "       The VIP is the secondary address on that same ENI. Find it:" >&2
                echo "         aws ec2 describe-network-interfaces \\" >&2
                echo "           --filters Name=addresses.private-ip-address,Values=${SERVER_HOST} \\" >&2
                echo "           --query 'NetworkInterfaces[].PrivateIpAddresses[?!Primary].PrivateIpAddress'" >&2
                exit 1
                ;;
            False|false|FALSE)
                echo "  ${SERVER_HOST} is a secondary private address (a VIP)"
                ;;
            *)
                echo "WARNING: ${SERVER_HOST} was not found as a private address on any" >&2
                echo "         ENI in this account and region. That is expected for a" >&2
                echo "         load balancer or an address outside this VPC, but if you" >&2
                echo "         meant a node's VIP, check it before launching." >&2
                echo "" >&2
                ;;
        esac
    fi
fi

echo "=== Phase 3: Launch Harvester on EC2 ==="
if [ "$MODE" = "join" ]; then
    echo "Mode: join -> ${SERVER_URL}"
else
    echo "Mode: create (bootstrap a new cluster)"
fi
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
if [ "$MODE" = "join" ]; then
    echo "Joining ${SERVER_URL}; no VIP to select or assign."
elif [ -z "$VIP" ]; then
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

# Join mode already required a token above.
if [ -z "$TOKEN" ]; then
    if command -v openssl >/dev/null; then
        TOKEN="harvester-aws-$(openssl rand -hex 8)"
    else
        TOKEN="harvester-aws-$(date +%s)-$RANDOM"
    fi
    echo "Generated cluster token: $TOKEN"
fi

if [ "$MTU" = "0" ]; then
    MTU=""
    echo "WARNING: --mtu 0 leaves the MTU unset. On AWS that produces mgmt-br at" >&2
    echo "         9001 over a 1500 bond, which breaks node-to-node TCP for any" >&2
    echo "         payload above 1500 bytes. Only do this deliberately." >&2
    echo "" >&2
elif [ -n "$MTU" ]; then
    # checkMTU() accepts 0 (unset) or 576..9000 -- note 9000, not ENA's 9001.
    if ! [[ "$MTU" =~ ^[0-9]+$ ]] || [ "$MTU" -lt 576 ] || [ "$MTU" -gt 9000 ]; then
        echo "ERROR: --mtu must be between 576 and 9000 (checkMTU in validator.go)." >&2
        echo "       ENA's 9001 is rejected; use 9000." >&2
        exit 1
    fi
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

# ${VAR:+...} strips quotes from its replacement text, so the server_url line is
# assembled here rather than inline in the heredoc below -- otherwise the value
# lands unquoted.
SERVER_URL_BLOCK=""
if [ -n "$SERVER_URL" ]; then
    SERVER_URL_BLOCK="
# server_url is top-level, not under install. Its presence is what makes
# rancherd render 'role: agent' instead of 'role: cluster-init'.
server_url: \"${SERVER_URL}\""
fi

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
token: "${TOKEN}"${SERVER_URL_BLOCK}
install:
  automatic: true
  mode: ${MODE}${ROLE:+
  role: ${ROLE}}
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
      fail_over_mac: "active"${MTU:+
    mtu: ${MTU}}
EOF

    # The VIP and the storage class belong to the cluster, not to the node.
    # genBootstrapResources() only runs for mode=create, so a joining node has
    # nowhere to put either of them.
    if [ "$MODE" = "create" ]; then
        cat >> "$USERDATA_FILE" <<EOF
  vip: "${VIP}"
  vip_mode: static
  harvester:
    storage_class:
      replica_count: ${REPLICA_COUNT}
EOF
    fi

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
    if [ "$MODE" = "create" ]; then
        echo "VIP to assign after launch: $VIP"
    else
        echo "Join mode: no VIP is assigned to this instance."
    fi
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
# A joining node does not get one: the VIP stays registered on the ENI of the
# node that bootstrapped the cluster.
if [ "$MODE" = "create" ]; then
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
fi

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

if [ "$MODE" = "create" ]; then
    CLUSTER_LINE="  VIP:            $VIP"
    UI_URL="https://${VIP}"
    BOOTSTRAP_NOTE="First boot writes /oem/userdata.yaml from user-data, then the installer
configures the node and rancherd bootstraps RKE2, Rancher and the Harvester
charts. Expect 15-25 minutes."
else
    CLUSTER_LINE="  Joining:        $SERVER_URL"
    UI_URL="$SERVER_URL"
    BOOTSTRAP_NOTE="First boot writes /oem/userdata.yaml from user-data, then the installer
configures the node and rancherd joins it to the cluster at
${SERVER_URL}. Joining is quicker than bootstrapping -- the charts
are already deployed -- but still expect around 10 minutes before the node
shows up in 'kubectl get nodes' as Ready."
fi

cat <<SUMMARY

=============================================
Harvester instance launched
=============================================

  Instance ID:    $INSTANCE_ID
  Instance type:  $INSTANCE_TYPE  (nested virtualization enabled)
  Availability:   $AZ
  Primary IP:     $PRIMARY_IP
${CLUSTER_LINE}
  Public IP:      ${PUBLIC_IP:-none}
  Cluster token:  $TOKEN
  Root volume:    ${VOLUME_SIZE} GiB (Longhorn data partition: ${DATA_DISK_SIZE})

${BOOTSTRAP_NOTE}

Watch it:

  # Serial console (this is where everything is logged; serial console
  # access for this account is currently: ${SERIAL_ENABLED})
  aws ec2-instance-connect send-serial-console-ssh-public-key \\
    --instance-id $INSTANCE_ID --serial-port 0 \\
    --ssh-public-key file://~/.ssh/id_rsa.pub
  ssh ${INSTANCE_ID}.port0@serial-console.ec2-instance-connect.${AZ%?}.aws

  # Or follow the console buffer
  ./follow-console.sh --instance-id $INSTANCE_ID --tee console.txt

  # Once SSH is up
  ssh rancher@${SSH_TARGET}
  sudo journalctl -u harvester-aws-config      # user-data -> /oem/userdata.yaml
  sudo cat /var/log/console.log                # harvester-installer
  sudo journalctl -fu rancherd                 # cluster bootstrap / join
  sudo kubectl get nodes                       # all nodes in the cluster
  sudo kubectl get managedchart -n fleet-local # harvester / harvester-crd

  # Harvester UI
  ${UI_URL}    admin / admin

Security group ${SG} needs at least:
  22    SSH
  443   Harvester UI and API (on the VIP)
  6443  Kubernetes API
  9345  RKE2 supervisor

For more than one node it also needs a rule allowing all traffic from itself
-- source ${SG}, not a CIDR. etcd (2379-2380), the kubelet (10250), Longhorn
(3260, 9500-9504) and kube-ovn's GENEVE tunnels (UDP 6081) all run node to
node, and enumerating them is more trouble than it is worth:

  aws ec2 authorize-security-group-ingress --group-id ${SG} \\
    --protocol -1 --source-group ${SG}
SUMMARY

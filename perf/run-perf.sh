#!/bin/bash
set -euo pipefail

# =============================================================================
# Run harvester/harvester-perf (hvperf) against a cluster deployed by this
# repository.
#
# Same shape as e2e/run-tests.sh -- discover the cluster, launch a runner in its
# subnet and security group, provision it, run, collect -- for different
# reasons. hvperf needs only a kubeconfig, but:
#
#   1. The only way to get one is from a node, and node SSH is key-only on the
#      private address. The runner is the jump host, so the cluster key never
#      leaves your machine.
#   2. Pointing the kubeconfig at a node's private address keeps the run off
#      both the VIP (which goes dark if kube-vip re-elects -- see the README)
#      and an internet-facing NLB (350 s idle timeout on long exec and watch
#      streams, and unreachable from inside the VPC anyway).
#   3. etcd-benchmark ships etcdctl/benchmark/promtool into a pod on a node, so
#      they have to be built for the NODES' architecture. The runner
#      cross-compiles them; see runner-provision.sh.
#
#   ./perf/run-perf.sh                         # all four suites, bounded density
#   ./perf/run-perf.sh --suites node-capacity,resource-footprint --keep
#   ./perf/run-perf.sh --down                  # just terminate the runner
# =============================================================================

NAME_PREFIX="terraform-cluster"
KEY_NAME="aws-testing"
KEY_FILE=""
# Key for the CLUSTER's key pair, used to SSH to node 1 as rancher (through the
# runner). Any key type works: this is OpenSSH, not the e2e suite's paramiko.
HOST_KEY_FILE=""
# Larger than the e2e runner's t3.medium: this one compiles etcd and a
# client-go-heavy binary, and linking those wants more than 4 GiB of headroom.
RUNNER_TYPE="t3.large"
RUNNER_TAG="harvester-perf-runner"
# Order matters, and it is NOT what `hvperf run all` does: that runs suites
# alphabetically, which puts density (push the cluster to failure) first and the
# idle resource-footprint measurement last, measuring the aftermath. Cheapest
# and most passive first, then the in-guest workloads (they need the cluster
# idle too), then etcd load, then density.
#
# `guest` is not an hvperf suite: it is this repository's perf/guest-bench.sh,
# the only part that measures what a VM gets from the node -- i.e. the only
# part that shows the cost of nested virtualization.
SUITES="node-capacity,resource-footprint,guest,etcd-benchmark,density"
KNOWN_SUITES="node-capacity resource-footprint guest etcd-benchmark density"
GUEST_VCPUS=4
GUEST_LABEL=""
GUEST_MODE="both"
GUEST_MULTIQUEUE="false"
GUEST_VM_CPU_LIMIT=""
GUEST_SUSTAINED=0
GUEST_STORAGE_CLASS=""
GUEST_PGBENCH="false"
GUEST_CONTENTION=0
GUEST_CONTENTION_PREFILL="false"
# hvperf's own default is 0, meaning "keep adding VMIs until a health check
# trips". Bounded by default so a first run measures boot latency without
# taking the cluster to its edge; pass --max-vms 0 for the real ramp.
MAX_VMS=50
BATCH_SIZE=10
BATCH_WAIT_TIMEOUT="5m"
CONTAINER_DISK="quay.io/kubevirt/cirros-container-disk-demo:latest"
PERF_REF=""
ALLOW_ARM64_DENSITY="false"
ALLOW_ARM64_GUEST="false"
KEEP_NAMESPACE="false"
KEEP="false"
DOWN="false"
RESULTS_DIR="perf/results"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
KNOWN_HOSTS="$REPO/.make/perf_known_hosts"

usage() {
    cat <<USAGE
Usage: $0 [options]

  --name-prefix P   Cluster Name-tag prefix to discover. Default: ${NAME_PREFIX}
  --key-name N      EC2 key pair for the runner. Default: ${KEY_NAME}
  --key-file F      Private key for the runner. Default: \$HOME/.ssh/<key-name>.pem
  --host-key-file F Private key for the CLUSTER's key pair, used to SSH to
                    node 1 as rancher via the runner. Default: --key-file.
  --runner-type T   Runner instance type. Default: ${RUNNER_TYPE}
  --suites LIST     Comma-separated suites, run one at a time IN THIS ORDER.
                    Default: ${SUITES}
  --max-vms N       density: stop after N VMIs. 0 = until a health check
                    fails, i.e. push the cluster to its limit. Default: ${MAX_VMS}
  --batch-size N    density: VMIs created per batch. Default: ${BATCH_SIZE}
  --batch-wait-timeout D
                    density: per-batch wait for Running. Default: ${BATCH_WAIT_TIMEOUT}
  --container-disk I
                    density: guest image. Default: ${CONTAINER_DISK}
  --perf-ref R      harvester-perf branch, tag or commit. Default: its HEAD.
                    The repository moves daily; pin this to compare runs.
  --guest-vcpus N   guest: vCPUs per benchmark VM. Default: ${GUEST_VCPUS}. Keep it
                    the same across every cluster you compare.
  --guest-label T   guest: label recorded with the results. Default:
                    "aws <instance type> <nested|metal>".
  --guest-multiqueue
                    guest: one virtio-net queue per vCPU in the VMs.
  --guest-vm-cpu-limit N
                    guest: CPU limit of the VMs, above --guest-vcpus for
                    headroom for QEMU's own threads. Default: --guest-vcpus.
  --guest-sustained S
                    guest: also run a 4-stream iperf for S seconds, sampled
                    every 10 s, to find the sustained rate after the EC2
                    network burst runs out. 900 is enough. Default: 0 (off).
  --guest-storage-class SC
                    guest: storage class for the fio data disk, in both the
                    VM and the pod (root disks keep the image's class).
                    Default: the cluster's default class.
  --guest-pgbench   guest: also run pgbench (PostgreSQL 16, scale 100, 1/8/32
                    clients) with the database on the data disk's storage
                    class, in the VM and the pod. About 10 minutes per mode.
  --guest-contention N
                    guest: instead of the VM/pod comparison, N VMs writing at
                    once (one alone first for reference), with each node's EBS
                    writes and etcd latency recorded. About 30 minutes.
  --guest-contention-prefill
                    guest: write every contention VM's disk once before
                    measuring (steady state, not first writes). Adds up to 15 minutes.
  --guest-mode M    guest: both (default; VM and pod, which gives the VM
                    overhead), vm or pod.
  --allow-arm64-density
                    Run density on arm64 v1.9.x anyway. Refused by default:
                    guests cannot boot there, yet VMIs still reach Running, so
                    the results look healthy and measure nothing.
  --allow-arm64-v19 As --allow-arm64-density, for density AND guest.
  --keep-namespace  Leave harvester-perf-system (and anything in it) behind.
  --keep            Leave the runner running when the suites finish. It then
                    holds a cluster-admin kubeconfig in ~/.kube/config.
  --down            Terminate the runner and exit.
  -h, --help        This.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --name-prefix)   NAME_PREFIX="$2"; shift 2 ;;
        --key-name)      KEY_NAME="$2"; shift 2 ;;
        --key-file)      KEY_FILE="$2"; shift 2 ;;
        --host-key-file) HOST_KEY_FILE="$2"; shift 2 ;;
        --runner-type)   RUNNER_TYPE="$2"; shift 2 ;;
        --suites)        SUITES="$2"; shift 2 ;;
        --max-vms)       MAX_VMS="$2"; shift 2 ;;
        --batch-size)    BATCH_SIZE="$2"; shift 2 ;;
        --batch-wait-timeout) BATCH_WAIT_TIMEOUT="$2"; shift 2 ;;
        --container-disk) CONTAINER_DISK="$2"; shift 2 ;;
        --perf-ref)      PERF_REF="$2"; shift 2 ;;
        --guest-vcpus)   GUEST_VCPUS="$2"; shift 2 ;;
        --guest-label)   GUEST_LABEL="$2"; shift 2 ;;
        --guest-mode)    GUEST_MODE="$2"; shift 2 ;;
        --guest-multiqueue) GUEST_MULTIQUEUE="true"; shift ;;
        --guest-vm-cpu-limit) GUEST_VM_CPU_LIMIT="$2"; shift 2 ;;
        --guest-sustained) GUEST_SUSTAINED="$2"; shift 2 ;;
        --guest-storage-class) GUEST_STORAGE_CLASS="$2"; shift 2 ;;
        --guest-pgbench) GUEST_PGBENCH="true"; shift ;;
        --guest-contention) GUEST_CONTENTION="$2"; shift 2 ;;
        --guest-contention-prefill) GUEST_CONTENTION_PREFILL="true"; shift ;;
        --allow-arm64-density) ALLOW_ARM64_DENSITY="true"; shift ;;
        --allow-arm64-v19) ALLOW_ARM64_DENSITY="true"; ALLOW_ARM64_GUEST="true"; shift ;;
        --keep-namespace) KEEP_NAMESPACE="true"; shift ;;
        --keep)          KEEP="true"; shift ;;
        --down)          DOWN="true"; shift ;;
        -h|--help)       usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
done

: "${KEY_FILE:=$HOME/.ssh/${KEY_NAME}.pem}"
: "${HOST_KEY_FILE:=$KEY_FILE}"

if ! [[ "$NAME_PREFIX" =~ ^[A-Za-z0-9-]+$ ]]; then
    echo "ERROR: --name-prefix may contain only letters, digits and '-'." >&2
    exit 1
fi
for n in "$MAX_VMS" "$BATCH_SIZE"; do
    [[ "$n" =~ ^[0-9]+$ ]] || { echo "ERROR: --max-vms and --batch-size take integers" >&2; exit 1; }
done
[ "$BATCH_SIZE" -gt 0 ] || { echo "ERROR: --batch-size must be positive" >&2; exit 1; }
[[ "$BATCH_WAIT_TIMEOUT" =~ ^[0-9]+(s|m|h)$ ]] || {
    echo "ERROR: --batch-wait-timeout takes a duration such as 5m" >&2; exit 1; }
# Written into hvperf.yaml, so keep it to characters that need no YAML quoting.
[[ "$CONTAINER_DISK" =~ ^[A-Za-z0-9./:@_-]+$ ]] || {
    echo "ERROR: --container-disk does not look like an image reference" >&2; exit 1; }
[[ "$GUEST_VCPUS" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: --guest-vcpus takes a positive integer" >&2; exit 1; }
[[ "$GUEST_SUSTAINED" =~ ^[0-9]+$ ]] || { echo "ERROR: --guest-sustained takes seconds" >&2; exit 1; }
[[ "$GUEST_CONTENTION" =~ ^[0-9]+$ ]] || { echo "ERROR: --guest-contention takes a VM count" >&2; exit 1; }
[[ -z "$GUEST_STORAGE_CLASS" || "$GUEST_STORAGE_CLASS" =~ ^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$ ]] || {
    echo "ERROR: --guest-storage-class must be a Kubernetes object name" >&2; exit 1; }
[[ -z "$GUEST_VM_CPU_LIMIT" || "$GUEST_VM_CPU_LIMIT" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: --guest-vm-cpu-limit takes a positive integer" >&2; exit 1; }
case "$GUEST_MODE" in both|vm|pod) ;; *) echo "ERROR: --guest-mode must be both, vm or pod" >&2; exit 1 ;; esac
[[ -z "$PERF_REF" || "$PERF_REF" =~ ^[A-Za-z0-9._/-]+$ ]] || {
    echo "ERROR: --perf-ref may contain only letters, digits and . _ / -" >&2; exit 1; }

# hvperf ignores names it does not know, so a typo silently runs nothing.
# (`guest` is ours, not hvperf's; see above.)
IFS=',' read -r -a SUITE_LIST <<<"$SUITES"
for s in "${SUITE_LIST[@]}"; do
    case " $KNOWN_SUITES " in
        *" $s "*) ;;
        *) echo "ERROR: unknown suite '$s'. Known: $KNOWN_SUITES" >&2; exit 1 ;;
    esac
done
has_suite() { case ",${SUITES}," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }

find_runner() {
    aws ec2 describe-instances \
        --filters "Name=tag:Name,Values=${RUNNER_TAG}" \
                  "Name=instance-state-name,Values=pending,running" \
        --query 'Reservations[].Instances[0].InstanceId' --output text 2>/dev/null | tr -d '\n'
}

# --- teardown ---------------------------------------------------------------
if [ "$DOWN" = "true" ]; then
    ID="$(find_runner)"
    if [ -z "$ID" ] || [ "$ID" = "None" ]; then
        echo "No runner instance tagged ${RUNNER_TAG} is running."
        exit 0
    fi
    echo "==> terminating $ID"
    aws ec2 terminate-instances --instance-ids "$ID" >/dev/null
    aws ec2 wait instance-terminated --instance-ids "$ID"
    echo "    gone"
    exit 0
fi

# --- preflight --------------------------------------------------------------
command -v aws >/dev/null || { echo "ERROR: aws CLI not found" >&2; exit 1; }
aws sts get-caller-identity >/dev/null 2>&1 || {
    echo "ERROR: AWS credentials are not usable (expired session?)." >&2; exit 1; }
[ -f "$KEY_FILE" ] || { echo "ERROR: key file $KEY_FILE not found (--key-file)" >&2; exit 1; }
[ -f "$HOST_KEY_FILE" ] || { echo "ERROR: host key file $HOST_KEY_FILE not found (--host-key-file)" >&2; exit 1; }

# --- discover the cluster ---------------------------------------------------
# Node 1 specifically: it is the bootstrap server under both Terraform
# (<name_prefix>-node-1) and CloudFormation (<StackName>-node-1), so it always
# has /etc/rancher/rke2/rke2.yaml and a local etcd member.
echo "==> discovering cluster '${NAME_PREFIX}-*'"
read -r NODE1_ID NODE1_IP SUBNET SG NODE_ARCH NODE_TYPE <<<"$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=${NAME_PREFIX}-node-1" "Name=instance-state-name,Values=running" \
    --query 'Reservations[0].Instances[0].[InstanceId,PrivateIpAddress,SubnetId,SecurityGroups[0].GroupId,Architecture,InstanceType]' \
    --output text 2>/dev/null)"
[ -n "${SG:-}" ] && [ "$SG" != "None" ] || {
    echo "ERROR: found no running instance tagged ${NAME_PREFIX}-node-1" >&2
    exit 1
}
NODE_COUNT="$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=${NAME_PREFIX}-node-*" "Name=instance-state-name,Values=running" \
    --query 'length(Reservations[].Instances[])' --output text)"
case "$NODE_ARCH" in
    x86_64) NODE_GOARCH=amd64 ;;
    arm64)  NODE_GOARCH=arm64 ;;
    *) echo "ERROR: unexpected node architecture '$NODE_ARCH'" >&2; exit 1 ;;
esac
echo "    nodes: ${NODE_COUNT} x ${NODE_TYPE} (${NODE_GOARCH})   node 1: ${NODE1_ID} ${NODE1_IP}"
# The limits a figure can be pinned by, recorded so the report can say which
# one a result is sitting at. See perf/README.md, "Which AWS limit".
read -r NET_BASE NET_PEAK EBS_BASE_MBPS EBS_MAX_MBPS EBS_BASE_IOPS EBS_MAX_IOPS <<<"$(aws ec2 describe-instance-types \
    --instance-types "$NODE_TYPE" \
    --query 'InstanceTypes[0].[NetworkInfo.NetworkCards[0].BaselineBandwidthInGbps,NetworkInfo.NetworkCards[0].PeakBandwidthInGbps,EbsInfo.EbsOptimizedInfo.BaselineBandwidthInMbps,EbsInfo.EbsOptimizedInfo.MaximumBandwidthInMbps,EbsInfo.EbsOptimizedInfo.BaselineIops,EbsInfo.EbsOptimizedInfo.MaximumIops]' \
    --output text 2>/dev/null || true)"
read -r VOL_TYPE VOL_SIZE VOL_IOPS VOL_TPUT <<<"$(aws ec2 describe-volumes \
    --filters "Name=attachment.instance-id,Values=${NODE1_ID}" \
    --query 'Volumes[0].[VolumeType,Size,Iops,Throughput]' --output text 2>/dev/null || true)"

# --- launch the runner ------------------------------------------------------
ID="$(find_runner)"
if [ -n "$ID" ] && [ "$ID" != "None" ]; then
    echo "==> reusing runner $ID"
else
    echo "==> launching runner (${RUNNER_TYPE})"
    # Any architecture works for the runner itself; the cluster tools are
    # cross-compiled. Ask EC2 rather than guessing from the type name.
    case "$(aws ec2 describe-instance-types --instance-types "$RUNNER_TYPE" \
            --query 'InstanceTypes[0].ProcessorInfo.SupportedArchitectures' --output text)" in
        *arm64*) RUNNER_AMI_ARCH=arm64 ;;
        *)       RUNNER_AMI_ARCH=x86_64 ;;
    esac
    OS_AMI="$(aws ssm get-parameter \
        --name "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-${RUNNER_AMI_ARCH}" \
        --query 'Parameter.Value' --output text)"
    ROOT_DEV="$(aws ec2 describe-images --image-ids "$OS_AMI" \
        --query 'Images[0].RootDeviceName' --output text)"
    # Same security group as the nodes: it allows all traffic from itself, so
    # the runner reaches 6443 and SSH on every node without a new rule.
    ID="$(aws ec2 run-instances --image-id "$OS_AMI" --instance-type "$RUNNER_TYPE" \
        --subnet-id "$SUBNET" --security-group-ids "$SG" \
        --key-name "$KEY_NAME" --associate-public-ip-address \
        --metadata-options "HttpTokens=required,HttpPutResponseHopLimit=1" \
        --block-device-mappings "DeviceName=${ROOT_DEV},Ebs={VolumeSize=30,VolumeType=gp3,DeleteOnTermination=true,Encrypted=true}" \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${RUNNER_TAG}}]" \
        --query 'Instances[0].InstanceId' --output text)"
    echo "    $ID, waiting for it to run"
    aws ec2 wait instance-running --instance-ids "$ID"
fi

IP="$(aws ec2 describe-instances --instance-ids "$ID" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)"
echo "    public IP: $IP"

cleanup() {
    if [ "$KEEP" = "true" ]; then
        echo ""
        echo "Runner left running: $ID ($IP)"
        echo "  ssh -i $KEY_FILE ec2-user@$IP"
        echo "  It holds a cluster-admin kubeconfig. $0 --down when finished."
    else
        echo ""
        echo "==> terminating runner $ID"
        # Loud, not silent: an AWS session that expired during a long run made
        # this fail once and left a runner (with a cluster-admin kubeconfig)
        # running for days.
        if ! aws ec2 terminate-instances --instance-ids "$ID" >/dev/null; then
            echo "WARNING: runner $ID was NOT terminated and is still running."
            echo "         Once AWS credentials work again: $0 --down"
        fi
    fi
}
trap cleanup EXIT

# Host keys are filed under the INSTANCE ID (HostKeyAlias), not the address.
# Private IPs are reused by the next cluster deployed into the subnet, and a
# redeploy would otherwise trip "REMOTE HOST IDENTIFICATION HAS CHANGED".
# IdentitiesOnly: the nodes' sshd has a low MaxAuthTries, and an agent offering
# several keys first can exhaust it before the right one is tried.
mkdir -p "$REPO/.make"
SSH_BASE=(-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$KNOWN_HOSTS"
          -o ConnectTimeout=10 -o IdentitiesOnly=yes)
RUNNER_SSH_OPTS=("${SSH_BASE[@]}" -o HostKeyAlias="$ID" -i "$KEY_FILE")
runner() { ssh "${RUNNER_SSH_OPTS[@]}" "ec2-user@$IP" "$@"; }
runner_scp() { scp "${RUNNER_SSH_OPTS[@]}" -q "$@"; }

PROXY="ssh"
for o in "${RUNNER_SSH_OPTS[@]}"; do PROXY+=" $(printf '%q' "$o")"; done
PROXY+=" -W %h:%p ec2-user@${IP}"
node1() {
    ssh "${SSH_BASE[@]}" -o HostKeyAlias="$NODE1_ID" -o ProxyCommand="$PROXY" \
        -i "$HOST_KEY_FILE" "rancher@${NODE1_IP}" "$@"
}

echo "==> waiting for SSH"
for _ in $(seq 1 40); do
    runner true 2>/dev/null && break || sleep 10
done
runner true

# --- cluster facts, before spending time on provisioning ---------------------
echo "==> inspecting the cluster from node 1"
FACTS="$(node1 'bash -s' "$NODE1_IP" <<'NODE'
set -u
K="sudo /var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml"
echo "SERVER_VERSION=$($K get settings.harvesterhci.io server-version -o jsonpath='{.value}' 2>/dev/null)"
echo "JOB_NODE=$($K get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}' 2>/dev/null | awk -v ip="$1" '$2 == ip {print $1}')"
echo "CP_NODES=$($K get nodes -l node-role.kubernetes.io/control-plane=true -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)"
echo "CORDONED=$($K get nodes -o jsonpath='{range .items[?(@.spec.unschedulable==true)]}{.metadata.name}{" "}{end}' 2>/dev/null)"
echo "MONITORING=$($K -n cattle-monitoring-system get addons.harvesterhci.io rancher-monitoring -o jsonpath='{.spec.enabled}' 2>/dev/null)"
# RKE2 runs etcd from a config file rather than flags.
echo "ETCD_METRICS_URLS=$(sudo sed -n 's/^listen-metrics-urls: *//p' /var/lib/rancher/rke2/server/db/etcd/config 2>/dev/null)"
echo "PERF_NS=$($K get namespace harvester-perf-system -o name 2>/dev/null)"
# For a kubectl on the runner that matches the cluster (guest suite only).
echo "KUBE_VERSION=$($K get --raw /version 2>/dev/null | sed -n 's/.*"gitVersion": *"\(v[0-9.]*\).*/\1/p')"
NODE
)" || { echo "ERROR: could not SSH to node 1 as rancher via the runner (--host-key-file?)" >&2; exit 1; }

SERVER_VERSION="" JOB_NODE="" CP_NODES="" CORDONED="" MONITORING="" ETCD_METRICS_URLS="" PERF_NS="" KUBE_VERSION=""
while IFS='=' read -r k v; do
    case "$k" in
        SERVER_VERSION|JOB_NODE|CP_NODES|CORDONED|MONITORING|ETCD_METRICS_URLS|PERF_NS|KUBE_VERSION) printf -v "$k" '%s' "$v" ;;
    esac
done <<<"$FACTS"

# etcd-expose-metrics adds the node address alongside 127.0.0.1, so any URL
# that is not loopback means Prometheus can scrape it.
if [ -z "$ETCD_METRICS_URLS" ]; then
    ETCD_METRICS="unknown"
elif printf '%s\n' "$ETCD_METRICS_URLS" | tr ',' '\n' | grep -vq '//127\.0\.0\.1:'; then
    ETCD_METRICS="exposed"
else
    ETCD_METRICS="loopback-only"
fi

echo "    harvester ${SERVER_VERSION:-unknown}   job node: ${JOB_NODE:-?}   control plane: ${CP_NODES:-?}"
echo "    monitoring addon: ${MONITORING:-absent}   etcd metrics: ${ETCD_METRICS}"
[ -n "$JOB_NODE" ] || { echo "ERROR: could not map ${NODE1_IP} to a Kubernetes node name" >&2; exit 1; }

# The etcd job pod is host-network and talks to etcd on 127.0.0.1:2379, but
# hvperf does not pin it to a node. On a five-node cluster nodes 4-5 are
# workers with no etcd, so it is pinned to node 1 via JobPodNode below.
WARNINGS=0
WARN_LIST=()
warn() { echo "WARNING: $*"; WARNINGS=$((WARNINGS + 1)); WARN_LIST+=("$*"); }

if [ "$MONITORING" != "true" ]; then
    has_suite resource-footprint && warn "rancher-monitoring is not enabled: resource-footprint will SKIP every case."
    has_suite etcd-benchmark     && warn "rancher-monitoring is not enabled: etcd-benchmark's metrics case will SKIP."
    has_suite density            && warn "rancher-monitoring is not enabled: density's metrics case will ERROR (the VMI ramp itself still runs)."
fi
if has_suite etcd-benchmark && [ "$MONITORING" = "true" ] && [ "$ETCD_METRICS" != "exposed" ]; then
    warn "etcd metrics are ${ETCD_METRICS} on node 1. The etcd metrics case will wait"
    echo "         ~10 minutes for Prometheus targets that never go healthy, then SKIP."
    echo "         Deploy a test cluster with the Terraform module's"
    echo "         etcd_expose_metrics = true on a current AMI; see perf/README.md."
fi
if [ -n "$CORDONED" ]; then
    warn "cordoned node(s): ${CORDONED% } -- often e2e maintenance-mode residue."
    echo "         density capacity will be understated; e2e/clean-cluster.py releases them."
fi
if [ -n "$PERF_NS" ]; then
    warn "harvester-perf-system already exists (an earlier run kept it); its contents count against the cluster."
fi
if has_suite guest; then
    if [ "$NODE_GOARCH" = "arm64" ] && [[ "$SERVER_VERSION" == v1.9.* ]] && [ "$GUEST_MODE" != "pod" ] \
       && [ "$ALLOW_ARM64_GUEST" != "true" ]; then
        echo "ERROR: the guest suite cannot run on arm64 ${SERVER_VERSION}: its guests dead-loop" >&2
        echo "       in firmware and never boot (README, 'What has been tested'). Drop guest" >&2
        echo "       from --suites, use v1.8.2, or pass --allow-arm64-v19." >&2
        exit 1
    fi
    [ -n "$KUBE_VERSION" ] || { echo "ERROR: could not read the cluster's Kubernetes version for kubectl" >&2; exit 1; }
    # Its figures are the guest's share of an idle node; anything that loads
    # the cluster first is measured instead.
    for s in "${SUITE_LIST[@]}"; do
        [ "$s" = "guest" ] && break
        case "$s" in etcd-benchmark|density)
            warn "guest runs after ${s}; its figures will include that suite's after-effects." ;;
        esac
    done
    case "$NODE_TYPE" in *.metal*) VIRT="metal" ;; *) VIRT="nested" ;; esac
    : "${GUEST_LABEL:=aws ${NODE_TYPE} ${VIRT}}"
fi
if has_suite density; then
    if [ "$NODE_GOARCH" = "arm64" ] && [[ "$SERVER_VERSION" == v1.9.* ]] && [ "$ALLOW_ARM64_DENSITY" != "true" ]; then
        echo "ERROR: density on arm64 ${SERVER_VERSION} would report success while measuring nothing." >&2
        echo "       The v1.9 guest firmware dead-loops before the kernel boots (see README," >&2
        echo "       'What has been tested'), but density only waits for VMI phase Running," >&2
        echo "       which QEMU reaches regardless. Drop density from --suites, use v1.8.2," >&2
        echo "       or pass --allow-arm64-density to run it anyway." >&2
        exit 1
    fi
    if [ "$MAX_VMS" -eq 0 ]; then
        warn "--max-vms 0: density keeps adding VMIs until a node reports pressure, a"
        echo "         control-plane pod restarts, or a batch misses its deadline. Use a"
        echo "         cluster you are prepared to lose."
    fi
    # Density's health check compares against pods present at its start, so it
    # should be last; an explicit order is honoured but flagged.
    [ "${SUITE_LIST[${#SUITE_LIST[@]}-1]}" = "density" ] || \
        warn "density is not the last suite; whatever runs after it measures a cluster just pushed to its limit."
fi

# --- provision ---------------------------------------------------------------
echo "==> provisioning (tools for ${NODE_GOARCH})"
runner_scp "$HERE/runner-provision.sh" "ec2-user@$IP:/tmp/"
KUBECTL_VERSION=""
if has_suite guest; then KUBECTL_VERSION="$KUBE_VERSION"; fi
runner "NODE_GOARCH=${NODE_GOARCH} PERF_REF='${PERF_REF}' KUBECTL_VERSION='${KUBECTL_VERSION}' bash /tmp/runner-provision.sh"
if has_suite guest; then
    runner 'mkdir -p ~/perf-run/guest-src/guest'
    runner_scp "$HERE/guest-bench.sh" "ec2-user@$IP:~/perf-run/guest-src/"
    runner_scp "$HERE/guest/bench.py" "$HERE/guest/hvg.py" "ec2-user@$IP:~/perf-run/guest-src/guest/"
    # Arguments travel as a file of shell-quoted assignments, so a label with
    # spaces or quotes survives ssh's re-parsing.
    GUEST_EXTRA=""
    [ "$GUEST_MULTIQUEUE" = "true" ] && GUEST_EXTRA+=" --multiqueue"
    [ -n "$GUEST_VM_CPU_LIMIT" ] && GUEST_EXTRA+=" --vm-cpu-limit ${GUEST_VM_CPU_LIMIT}"
    [ "$GUEST_SUSTAINED" -gt 0 ] && GUEST_EXTRA+=" --sustained ${GUEST_SUSTAINED}"
    [ -n "$GUEST_STORAGE_CLASS" ] && GUEST_EXTRA+=" --storage-class ${GUEST_STORAGE_CLASS}"
    [ "$GUEST_PGBENCH" = "true" ] && GUEST_EXTRA+=" --pgbench"
    [ "$GUEST_CONTENTION" -gt 0 ] && GUEST_EXTRA+=" --contention ${GUEST_CONTENTION}"
    [ "$GUEST_CONTENTION_PREFILL" = "true" ] && GUEST_EXTRA+=" --contention-prefill"
    printf 'GUEST_ARGS=(--label %q --vcpus %q --mode %q%s)\n' "$GUEST_LABEL" "$GUEST_VCPUS" "$GUEST_MODE" "$GUEST_EXTRA" \
        | runner 'cat > ~/perf-run/guest.env'
fi

echo "==> kubeconfig"
# Straight from node 1 to the runner; it never touches this machine's disk.
# Node 1's own address is in its API certificate by default, independent of
# the tls-san drop-in.
node1 'sudo cat /etc/rancher/rke2/rke2.yaml' \
    | sed "s#https://127\.0\.0\.1:6443#https://${NODE1_IP}:6443#" \
    | runner 'umask 077; mkdir -p ~/.kube ~/perf-run && cat > ~/.kube/config'
runner 'hvperf version' | sed 's/^/    /'

# JobPodNode is a string, so it survives hvperf's options decoding. Do not add
# duration-valued globals here: hvperf round-trips this file through JSON into
# time.Duration fields, and a YAML "10m" does not decode that way.
runner 'cat > ~/perf-run/hvperf.yaml' <<YAML
JobPodNode: ${JOB_NODE}

density:
  batchSize: ${BATCH_SIZE}
  maxVMs: ${MAX_VMS}
  batchWaitTimeout: ${BATCH_WAIT_TIMEOUT}
  vmi:
    containerDisk: ${CONTAINER_DISK}
    memory: 90Mi
    cpu: 100m
YAML

# --- run ---------------------------------------------------------------------
# One hvperf invocation per suite: each gets its own JSON and log, and a failure
# in one does not lose the others' results.
runner 'cat > ~/perf-run/run.sh' <<'RUN'
#!/bin/bash
set -uo pipefail
cd ~/perf-run
keep_alive="$1"; shift
# Only the LAST hvperf suite may delete harvester-perf-system. Deleting it after
# every suite made the next one wait for the namespace to finish terminating,
# which took over 5 minutes once (2026-10-16) and timed density out before it
# created a single VMI.
last_hvperf=""
for s in "$@"; do [ "$s" = "guest" ] || last_hvperf="$s"; done
rc=0
for s in "$@"; do
    echo ""
    echo "==> ${s}   ($(date -u +%H:%M:%SZ))"
    if [ "$s" = "guest" ]; then
        # shellcheck disable=SC1090
        source ~/perf-run/guest.env
        rm -rf ~/perf-run/guest
        bash ~/perf-run/guest-src/guest-bench.sh --out ~/perf-run/guest "${GUEST_ARGS[@]}" \
            2>&1 | tee guest.log || rc=1
        continue
    fi
    ka="true"; [ "$s" = "$last_hvperf" ] && ka="$keep_alive"
    hvperf run "$s" --config hvperf.yaml --keep-alive="$ka" -o json \
        > "${s}.json" 2> >(tee "${s}.log" >&2) || { echo "    hvperf exited $? for ${s}"; rc=1; }
done
exit "$rc"
RUN

KEEP_ALIVE="false"
[ "$KEEP_NAMESPACE" = "true" ] && KEEP_ALIVE="true"
echo ""
echo "==> running: ${SUITES//,/ -> }"
[ "$WARNINGS" -eq 0 ] || echo "    (${WARNINGS} warning(s) above)"
# Detached on the runner, so a dropped connection -- this machine sleeping, a
# network blip -- stops only the log follow below, never the run. The follow
# reconnects until run.rc appears.
# The detached shell records its own PID: setsid may fork, so \$! would not do.
runner "rm -f ~/perf-run/run.rc ~/perf-run/run.out ~/perf-run/run.pid
    setsid nohup bash -c 'echo \$\$ > ~/perf-run/run.pid; bash ~/perf-run/run.sh ${KEEP_ALIVE} ${SUITE_LIST[*]} > ~/perf-run/run.out 2>&1; echo \$? > ~/perf-run/run.rc' \
        > /dev/null 2>&1 < /dev/null &
    for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s ~/perf-run/run.pid ] && break; sleep 1; done"
RUN_PID="$(runner 'cat ~/perf-run/run.pid')"
echo "    detached on the runner (pid ${RUN_PID}); log: ~/perf-run/run.out"
FROM="+1"
until runner 'test -f ~/perf-run/run.rc' 2>/dev/null; do
    runner "tail -n ${FROM} -F --pid=${RUN_PID} ~/perf-run/run.out 2>/dev/null" \
        || echo "    (lost the runner connection; reconnecting)"
    # After a reconnect, show only what is new rather than replaying the log.
    FROM="0"
    sleep 10
done
RC="$(runner 'cat ~/perf-run/run.rc' 2>/dev/null || echo 1)"

# --- collect -----------------------------------------------------------------
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$REPO/${RESULTS_DIR}/${STAMP}"
mkdir -p "$OUT"
echo ""
echo "==> collecting results into ${RESULTS_DIR}/${STAMP}/"
PERF_SHA="$(runner 'git -C ~/harvester-perf rev-parse --short HEAD' 2>/dev/null || echo unknown)"
cat > "$OUT/cluster.txt" <<INFO
name_prefix:      ${NAME_PREFIX}
harvester:        ${SERVER_VERSION:-unknown}
architecture:     ${NODE_GOARCH}
nodes:            ${NODE_COUNT} x ${NODE_TYPE}
control_plane:    ${CP_NODES}
job_node:         ${JOB_NODE}
monitoring:       ${MONITORING:-absent}
etcd_metrics:     ${ETCD_METRICS} (${ETCD_METRICS_URLS:-n/a})
cordoned_at_start: ${CORDONED:-none}
harvester_perf:   ${PERF_SHA}
suites:           ${SUITES}
instance_network: ${NET_BASE:-?} / ${NET_PEAK:-?} Gbit/s (${NODE_TYPE})
instance_ebs:     ${EBS_BASE_MBPS:-?} / ${EBS_MAX_MBPS:-?} Mbps, ${EBS_BASE_IOPS:-?} / ${EBS_MAX_IOPS:-?} IOPS
node_volume:      ${VOL_TYPE:-?} ${VOL_SIZE:-?} GiB, ${VOL_IOPS:-?} IOPS, ${VOL_TPUT:-?} MiB/s
INFO
# ${a[@]+...}: macOS's bash 3.2 calls an empty array unbound under set -u.
for w in ${WARN_LIST[@]+"${WARN_LIST[@]}"}; do printf 'warning:          %s\n' "$w" >> "$OUT/cluster.txt"; done
runner_scp "ec2-user@$IP:~/perf-run/hvperf.yaml" "$OUT/" 2>/dev/null || true
if has_suite guest; then
    runner_scp -r "ec2-user@$IP:~/perf-run/guest" "$OUT/" 2>/dev/null \
        && echo "    guest/" || echo "    guest/ (not produced)"
    runner_scp "ec2-user@$IP:~/perf-run/guest.log" "$OUT/" 2>/dev/null || true
fi
for s in "${SUITE_LIST[@]}"; do
    [ "$s" != "guest" ] || continue
    for f in "${s}.json" "${s}.log"; do
        runner_scp "ec2-user@$IP:~/perf-run/$f" "$OUT/" 2>/dev/null \
            && echo "    $f" || echo "    $f (not produced)"
    done
done

python3 -I - "$OUT" "${SUITE_LIST[@]}" <<'PY' || true
import json, os, sys
out, suites = sys.argv[1], sys.argv[2:]
for s in suites:
    if s == "guest":
        continue
    path = os.path.join(out, s + ".json")
    try:
        results = json.load(open(path))
    except (OSError, ValueError):
        print(f"    {s:<20} no parseable result")
        continue
    for r in results or []:
        line = f"    {r.get('Name', s):<20}"
        if r.get("Err"):
            line += f" suite error: {r['Err'][:120]}"
        print(line)
        for c in r.get("Results") or []:
            extra = ""
            for cap in c.get("CapacityResults") or []:
                extra += f"  max={cap.get('Max')}"
                if cap.get("Err"):
                    extra += f" (stopped: {cap['Err'][:80]})"
            if c.get("Err"):
                extra += f"  {c['Err'][:100]}"
            print(f"      {c.get('State', '?'):<6} {c.get('CaseName', '?')}{extra}")
PY

if [ -f "$OUT/guest/vm/result.json" ]; then
    echo ""
    python3 -I "$HERE/guest/hvg.py" summary "$OUT/guest" || true
fi
if [ -f "$OUT/guest/vm/result.json" ] && [ -f "$OUT/guest/pod/result.json" ]; then
    python3 -I "$HERE/guest/hvg.py" overhead "$OUT/guest" || true
fi

python3 -I "$HERE/report.py" "$OUT" >/dev/null \
    && echo "    report: ${RESULTS_DIR}/${STAMP}/summary.md" \
    || echo "    (report.py failed; the raw results are intact)"

echo ""
[ "$RC" -eq 0 ] && echo "all suites exited 0" || echo "at least one suite exited non-zero; see its .log"
exit 0

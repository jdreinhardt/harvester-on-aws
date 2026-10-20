#!/bin/bash
set -euo pipefail

# =============================================================================
# In-guest workload benchmark: what a VM actually gets from a Harvester node,
# and how much the VM layer costs.
#
# harvester-perf measures the control plane, etcd and VMI-to-Running latency.
# None of that runs inside a guest, so none of it shows what virtualization --
# let alone nested virtualization -- costs. This runs one fixed set of
# workloads (CPU, memory, context switches, futexes, page faults, disk I/O on
# Longhorn, network across nodes) twice on the same nodes:
#
#   vm   inside a Harvester VM, created the way the UI creates one
#   pod  in a plain pod, same CPUs, same Longhorn volume type, same network
#
# VM / pod is the cost of the VM layer ON THIS CLUSTER, with the hardware
# cancelled out. On bare metal that is the cost of one layer of KVM ("VMs lose
# X%"); on an m8i node it is the cost of KVM nested on Nitro ("Y%").
#
# Needs only kubectl, python3 and a kubeconfig -- no SSH, no AWS -- so the SAME
# script, images and workload profile run here, on an on-prem Harvester, or
# from perf/run-perf.sh's runner (`--suites guest`).
#
#   ./perf/guest-bench.sh --label "aws m8i.4xlarge nested"
#   ./perf/guest-bench.sh --label "on-prem r650" --out perf/results/onprem-r650
#   python3 perf/guest/hvg.py overhead perf/results/onprem-r650 perf/results/<aws>/guest
#
# Everything lives in one namespace that it owns and deletes afterwards.
# =============================================================================

NAMESPACE="harvester-perf-guest"
MODE="both"
VCPUS=4
MEMORY="8Gi"
ROOT_SIZE="10Gi"
DATA_SIZE="10Gi"
DATA_SC=""
BENCH_NODE=""
PEER_NODE=""
# Dated, not "release" or "latest": both images are part of what is compared.
IMAGE_SERIAL="20260926"
IMAGE_URL=""
POD_IMAGE="docker.io/library/ubuntu:noble-20260917"
TIMEOUT_MIN=60
OUT=""
LABEL=""
KEEP="false"
ALLOW_ARM64_V19="false"
MULTIQUEUE="false"
VM_CPU_LIMIT=""
SUSTAINED=0

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HVG=(python3 -I "$HERE/guest/hvg.py")
OWNER_LABEL="perf.harvester-aws/owned"

usage() {
    cat <<USAGE
Usage: $0 [options]

  --label TEXT        Free text recorded with the results and shown in
                      comparisons, e.g. "aws m8i.4xlarge nested".
  --out DIR           Results directory. Default: perf/results/guest-<stamp>
  --mode M            both (default), vm or pod. Overhead needs both.
  --namespace NS      Namespace to create and delete. Default: ${NAMESPACE}
                      Refuses an existing namespace this script did not create.
  --vcpus N           vCPUs per VM, and CPUs per pod. Default: ${VCPUS}. Keep it
                      the same across clusters you compare.
  --multiqueue        Give each VM one virtio-net queue per vCPU
                      (networkInterfaceMultiqueue). Off by default, as in
                      Harvester. Recorded in meta.json.
  --vm-cpu-limit N    CPU limit of each VM, above its --vcpus if wanted. The
                      limit covers QEMU's emulator and vhost-net threads as
                      well as the vCPUs, so N > vCPUs gives those headroom.
                      Default: --vcpus. Pods always get --vcpus.
  --sustained SECONDS Also run a 4-stream iperf for SECONDS, sampled every
                      10 s, after the standard tests. The 30 s tests fit
                      inside an EC2 network burst; 900 drains it on the sizes
                      that burst. Default: 0 (off). Adds to each mode's run.
  --memory Q          Memory per VM and pod. Default: ${MEMORY}
  --data-size Q       Longhorn data disk for fio. Default: ${DATA_SIZE}
  --storage-class SC  Data disk storage class. Default: the cluster default.
  --bench-node N      Node for the benchmark. Default: first schedulable node.
  --peer-node N       Node for the network peer. Default: the next one (the
                      same node on a single-node cluster, which is recorded).
  --image-url URL     Guest image. Default: Ubuntu 24.04 cloud image, serial
                      ${IMAGE_SERIAL}, for the cluster's architecture.
  --pod-image IMG     Pod image. Default: ${POD_IMAGE}
  --timeout MIN       Per-mode limit on the benchmark. Default: ${TIMEOUT_MIN}
  --allow-arm64-v19   Run VMs on arm64 Harvester v1.9.x anyway. Refused by
                      default: guests dead-loop in firmware there.
  --keep              Leave the namespace and everything in it in place.
  -h, --help          This.

Uses the current kubeconfig (KUBECONFIG, or ~/.kube/config). The guests and
pods need package egress: they install fio, sysbench, stress-ng and iperf3.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --label)         LABEL="$2"; shift 2 ;;
        --out)           OUT="$2"; shift 2 ;;
        --mode)          MODE="$2"; shift 2 ;;
        --namespace)     NAMESPACE="$2"; shift 2 ;;
        --vcpus)         VCPUS="$2"; shift 2 ;;
        --memory)        MEMORY="$2"; shift 2 ;;
        --data-size)     DATA_SIZE="$2"; shift 2 ;;
        --storage-class) DATA_SC="$2"; shift 2 ;;
        --bench-node)    BENCH_NODE="$2"; shift 2 ;;
        --peer-node)     PEER_NODE="$2"; shift 2 ;;
        --image-url)     IMAGE_URL="$2"; shift 2 ;;
        --pod-image)     POD_IMAGE="$2"; shift 2 ;;
        --timeout)       TIMEOUT_MIN="$2"; shift 2 ;;
        --allow-arm64-v19) ALLOW_ARM64_V19="true"; shift ;;
        --multiqueue)    MULTIQUEUE="true"; shift ;;
        --vm-cpu-limit)  VM_CPU_LIMIT="$2"; shift 2 ;;
        --sustained)     SUSTAINED="$2"; shift 2 ;;
        --keep)          KEEP="true"; shift ;;
        -h|--help)       usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
done

case "$MODE" in both|vm|pod) ;; *) echo "ERROR: --mode must be both, vm or pod" >&2; exit 1 ;; esac
want() { [ "$MODE" = "both" ] || [ "$MODE" = "$1" ]; }
[[ "$NAMESPACE" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || { echo "ERROR: bad --namespace" >&2; exit 1; }
[[ "$VCPUS" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: --vcpus takes a positive integer" >&2; exit 1; }
[[ "$SUSTAINED" =~ ^[0-9]+$ ]] || { echo "ERROR: --sustained takes seconds" >&2; exit 1; }
[[ -z "$VM_CPU_LIMIT" || "$VM_CPU_LIMIT" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: --vm-cpu-limit takes a positive integer" >&2; exit 1; }
[[ -z "$VM_CPU_LIMIT" || "$VM_CPU_LIMIT" -ge "$VCPUS" ]] || { echo "ERROR: --vm-cpu-limit below --vcpus would starve the vCPUs" >&2; exit 1; }
[[ "$TIMEOUT_MIN" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: --timeout takes minutes" >&2; exit 1; }
# The sustained test runs inside the same per-mode deadline.
TIMEOUT_MIN=$(( TIMEOUT_MIN + (SUSTAINED + 59) / 60 ))
for q in "$MEMORY" "$DATA_SIZE" "$ROOT_SIZE"; do
    [[ "$q" =~ ^[1-9][0-9]*(Mi|Gi|Ti)$ ]] || { echo "ERROR: '$q' is not a quantity like 8Gi" >&2; exit 1; }
done

command -v kubectl >/dev/null || { echo "ERROR: kubectl not found" >&2; exit 1; }
command -v python3 >/dev/null || { echo "ERROR: python3 not found" >&2; exit 1; }
kubectl version >/dev/null 2>&1 || { echo "ERROR: kubectl cannot reach the cluster" >&2; exit 1; }

RUN_ID="$(date -u +%Y%m%d-%H%M%S)"
: "${OUT:=$HERE/results/guest-${RUN_ID}}"
mkdir -p "$OUT/manifests"
k() { kubectl -n "$NAMESPACE" "$@"; }

# --- cluster facts -------------------------------------------------------------
echo "==> cluster"
HARVESTER="$(kubectl get settings.harvesterhci.io server-version -o jsonpath='{.value}' 2>/dev/null || echo unknown)"
KUBE="$(kubectl version -o json 2>/dev/null | python3 -I -c 'import json,sys; print(json.load(sys.stdin).get("serverVersion",{}).get("gitVersion","?"))')"
OVERCOMMIT="$(kubectl get settings.harvesterhci.io overcommit-config -o jsonpath='{.value}' 2>/dev/null || true)"
NODES="$(kubectl get nodes -o json | "${HVG[@]}" nodes)"
printf '%s\n' "$NODES" > "$OUT/nodes.tsv"

ARCHES="$(cut -f2 <<<"$NODES" | sort -u | tr '\n' ' ')"
ARCH="${ARCHES%% *}"
[ "$(wc -w <<<"$ARCHES")" -eq 1 ] || { echo "ERROR: mixed node architectures: $ARCHES" >&2; exit 1; }
case "$ARCH" in amd64|arm64) ;; *) echo "ERROR: unsupported architecture '$ARCH'" >&2; exit 1 ;; esac

if want vm && [ "$ARCH" = "arm64" ] && [[ "$HARVESTER" == v1.9.* ]] && [ "$ALLOW_ARM64_V19" != "true" ]; then
    echo "ERROR: arm64 ${HARVESTER} guests dead-loop in their UEFI firmware and never boot" >&2
    echo "       (see the repository README, 'What has been tested'). There is nothing" >&2
    echo "       to measure. Use v1.8.2, --mode pod, or --allow-arm64-v19 to try anyway." >&2
    exit 1
fi

# Schedulable, Ready nodes in name order; bench on the first, peer on the next.
# (A while-read loop, not mapfile: macOS still ships bash 3.2.)
CANDIDATES=()
while IFS= read -r n; do
    [ -n "$n" ] && CANDIDATES+=("$n")
done < <(awk -F'\t' '$3 == "ready" && $4 == "schedulable" {print $1}' <<<"$NODES" | sort)
[ "${#CANDIDATES[@]}" -gt 0 ] || { echo "ERROR: no Ready, schedulable node" >&2; exit 1; }
: "${BENCH_NODE:=${CANDIDATES[0]}}"
if [ -z "$PEER_NODE" ]; then
    PEER_NODE="$BENCH_NODE"
    for n in "${CANDIDATES[@]}"; do
        [ "$n" != "$BENCH_NODE" ] && { PEER_NODE="$n"; break; }
    done
fi
for n in "$BENCH_NODE" "$PEER_NODE"; do
    awk -F'\t' -v n="$n" '$1 == n {found=1} END {exit !found}' <<<"$NODES" \
        || { echo "ERROR: node '$n' does not exist" >&2; exit 1; }
done
SAME_NODE="false"
[ "$BENCH_NODE" != "$PEER_NODE" ] || SAME_NODE="true"

if [ -z "$DATA_SC" ]; then
    DATA_SC="$(kubectl get storageclass -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}' | head -1)"
    : "${DATA_SC:=harvester-longhorn}"
fi
DATA_SC_PARAMS="$(kubectl get storageclass "$DATA_SC" -o jsonpath='{.parameters}')" \
    || { echo "ERROR: storage class '$DATA_SC' not found" >&2; exit 1; }

: "${IMAGE_URL:=https://cloud-images.ubuntu.com/releases/releases/24.04/release-${IMAGE_SERIAL}/ubuntu-24.04-server-cloudimg-${ARCH}.img}"
IMAGE_NAME="hvg-ubuntu-2404-${ARCH}"

echo "    harvester ${HARVESTER} (kubernetes ${KUBE}), ${ARCH}, $(wc -l <<<"$NODES" | tr -d ' ') node(s)"
echo "    mode ${MODE}: bench on ${BENCH_NODE}, peer on ${PEER_NODE}$([ "$SAME_NODE" = "true" ] && echo ' (SAME node: network figures are node-local)')"
[ "$SUSTAINED" -eq 0 ] || echo "    sustained network test: ${SUSTAINED} s per mode"
echo "    ${VCPUS} vCPU / ${MEMORY} each, VM CPU limit ${VM_CPU_LIMIT:-$VCPUS}, VM net multiqueue ${MULTIQUEUE}, data disk ${DATA_SIZE} on ${DATA_SC} ${DATA_SC_PARAMS}"
[ -z "$OVERCOMMIT" ] || echo "    overcommit-config: ${OVERCOMMIT}"

LABEL="$LABEL" RUN_ID="$RUN_ID" HARVESTER="$HARVESTER" KUBE="$KUBE" ARCH="$ARCH" \
VCPUS="$VCPUS" MEMORY="$MEMORY" DATA_SIZE="$DATA_SIZE" DATA_SC="$DATA_SC" \
DATA_SC_PARAMS="$DATA_SC_PARAMS" BENCH_NODE="$BENCH_NODE" PEER_NODE="$PEER_NODE" \
IMAGE_URL="$IMAGE_URL" OVERCOMMIT="$OVERCOMMIT" MULTIQUEUE="$MULTIQUEUE" VM_CPU_LIMIT="$VM_CPU_LIMIT" SUSTAINED="$SUSTAINED" "${HVG[@]}" meta > "$OUT/meta.json"

# --- namespace ---------------------------------------------------------------
# Owned or nothing: cleanup deletes the whole namespace, so it must never be
# one that holds anything else.
if kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
    if [ "$(kubectl get namespace "$NAMESPACE" -o jsonpath="{.metadata.labels.perf\.harvester-aws/owned}")" != "true" ]; then
        echo "ERROR: namespace ${NAMESPACE} exists and was not created by this script." >&2
        exit 1
    fi
    if k get virtualmachines,pods -o name 2>/dev/null | grep -q .; then
        echo "ERROR: ${NAMESPACE} still holds VMs or pods from an earlier run (--keep?)." >&2
        echo "       kubectl delete namespace ${NAMESPACE}   and retry." >&2
        exit 1
    fi
else
    kubectl create namespace "$NAMESPACE" >/dev/null
    kubectl label namespace "$NAMESPACE" "${OWNER_LABEL}=true" >/dev/null
fi

# --- CPU quota sampler ----------------------------------------------------------
# cpu.stat of the bench workload's own container, every 5 s, for the length of
# one mode's run. For a VM that is virt-launcher's compute container, whose
# quota pays for the vCPUs AND QEMU's emulator and vhost-net threads; for the
# pod, the bench container. hvg.py throttle attributes it to each test.
CG_PID=""
cg_start() {   # pod container outfile
    (
        set +e
        while :; do
            line="$(k exec "$1" -c "$2" -- cat /sys/fs/cgroup/cpu.stat 2>/dev/null \
                | awk '{v[$1]=$2} END {if (v["usage_usec"] != "") print v["usage_usec"], v["nr_periods"]+0, v["nr_throttled"]+0, v["throttled_usec"]+0}')"
            [ -n "$line" ] && echo "HVG:C $(date +%s) $line"
            sleep 5
        done
    ) > "$3" 2>/dev/null &
    CG_PID=$!
}
cg_stop() {
    [ -n "$CG_PID" ] || return 0
    kill "$CG_PID" 2>/dev/null || true
    wait "$CG_PID" 2>/dev/null || true
    CG_PID=""
}

cleanup() {
    local rc=$?
    cg_stop
    collect_sampler || true
    if [ "$KEEP" = "true" ]; then
        echo ""
        echo "Left in place: namespace ${NAMESPACE}. kubectl delete namespace ${NAMESPACE} when done."
    else
        echo ""
        echo "==> deleting namespace ${NAMESPACE}"
        # Waited for, within reason: run-perf.sh starts the next suite as soon
        # as this returns, and Longhorn tearing down volumes is load it would
        # measure.
        kubectl delete namespace "$NAMESPACE" --wait=true --timeout=300s >/dev/null 2>&1 \
            || echo "    still terminating after 5 minutes; continuing"
    fi
    exit "$rc"
}
collect_sampler() {
    k logs hvg-sampler > "$OUT/node-sampler.log" 2>/dev/null || true
}
trap cleanup EXIT

# --- shared helpers ------------------------------------------------------------
pod_ip() {   # pod-name -> IP once Running (or already finished), else exits
    local pod="$1" phase="" ip=""
    for _ in $(seq 1 90); do
        read -r phase ip <<<"$(k get pod "$pod" -o jsonpath='{.status.phase} {.status.podIP}' 2>/dev/null || true)"
        case "$phase" in
            Running|Succeeded) [ -n "$ip" ] && { echo "$ip"; return 0; } ;;
            Failed) break ;;
        esac
        sleep 10
    done
    echo "ERROR: pod ${pod} did not start (phase '${phase:-none}')" >&2
    k describe pod "$pod" 2>/dev/null | tail -15 >&2 || true
    exit 1
}

# wait_results DIR LOG_FN: poll LOG_FN (which writes DIR/bench.log and
# DIR/peer.log) until the bench side reports DONE or FAIL, then decode.
wait_results() {
    local dir="$1" fetch="$2" state="none" last="" peer_state deadline
    deadline=$(( $(date +%s) + TIMEOUT_MIN * 60 ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        "$fetch"
        state="$("${HVG[@]}" status "$dir/bench.log" 2>/dev/null || echo none)"
        case "$state" in
            done|fail:*) break ;;
            running:*) [ "$state" != "$last" ] && echo "    ${state#running:}"; last="$state" ;;
        esac
        sleep 30
    done
    "$fetch"
    peer_state="$("${HVG[@]}" status "$dir/peer.log" 2>/dev/null || echo none)"
    [ "$peer_state" = "ready" ] || echo "WARNING: peer state '${peer_state}'; network tests will have failed."
    case "$state" in
        done) "${HVG[@]}" decode "$dir/bench.log" "$dir/result.json" | sed 's/^/    /' ;;
        fail:*) echo "ERROR: the benchmark reported failure: ${state#fail:} (see $dir/bench.log)" >&2
                exit 1 ;;
        *) if [ ! -s "$dir/bench.log" ]; then
               echo "ERROR: no log from the benchmark in $dir (for VMs: does this KubeVirt support logSerialConsole?)" >&2
           else
               echo "ERROR: timed out after ${TIMEOUT_MIN} minutes in state '${state}' (see $dir/bench.log)" >&2
           fi
           exit 1 ;;
    esac
}

# --- node steal sampler -----------------------------------------------------------
# Runs on the bench node for the whole run. Part of a nested VM's overhead is
# spent by AWS's hypervisor underneath the node and shows up on the node only
# as steal time, so the node's own CPU accounting never sees it. This records it.
echo "==> steal sampler on ${BENCH_NODE}"
"${HVG[@]}" sampler hvg-sampler "$NAMESPACE" "$BENCH_NODE" "$POD_IMAGE" \
    | tee "$OUT/manifests/sampler.json" | k apply -f - >/dev/null
pod_ip hvg-sampler >/dev/null

# --- VM mode -------------------------------------------------------------------
run_vm() {
    mkdir -p "$OUT/vm"
    echo "==> image ${IMAGE_NAME}"
    "${HVG[@]}" image "$IMAGE_NAME" "$NAMESPACE" "$IMAGE_URL" | tee "$OUT/manifests/image.json" | kubectl apply -f - >/dev/null
    local imported="-" retry_exceeded="-" progress="0" image_sc="-"
    for _ in $(seq 1 120); do
        read -r imported retry_exceeded progress image_sc <<<"$(k get virtualmachineimages.harvesterhci.io "$IMAGE_NAME" \
            -o json 2>/dev/null | "${HVG[@]}" imagestatus)"
        [ "$imported" = "True" ] && break
        if [ "$retry_exceeded" = "True" ]; then
            echo "ERROR: image import failed (retry limit). Does the cluster have egress to ${IMAGE_URL%/*}?" >&2
            exit 1
        fi
        printf '    importing: %s%%\r' "$progress"
        sleep 10
    done
    [ "$imported" = "True" ] || { echo "ERROR: image not imported after 20 minutes" >&2; exit 1; }
    [ "$image_sc" != "-" ] || image_sc="longhorn-${IMAGE_NAME}"
    echo "    imported; root disks use storage class ${image_sc}"

    # The peer goes first: the bench VM's cloud-init needs its address. With
    # masquerade, a VM is reachable on its virt-launcher pod's IP, which the pod
    # has before the guest has even booted.
    echo "==> VM mode: peer on ${PEER_NODE}"
    create_vm peer "$PEER_NODE" "" "$image_sc"
    local peer_ip
    peer_ip="$(pod_ip "$(launcher_pod hvg-peer)")"
    echo "    running, pod IP ${peer_ip}"
    echo "==> VM mode: bench on ${BENCH_NODE}"
    create_vm bench "$BENCH_NODE" "$peer_ip" "$image_sc"
    pod_ip "$(launcher_pod hvg-bench)" >/dev/null
    k get vmi hvg-bench hvg-peer -o json > "$OUT/vm/vmi.json" 2>/dev/null || true
    cg_start "$(launcher_pod hvg-bench)" compute "$OUT/vm/cgroup-cpu.log"
    echo "    running; package install, then about 15 minutes of workloads"
    wait_results "$OUT/vm" fetch_vm_logs
    cg_stop

    # Nothing of the VM run may still be running when the pod run starts.
    echo "    removing the VMs"
    k delete vm hvg-bench hvg-peer --wait=true --timeout=300s >/dev/null 2>&1 || true
    k delete pvc hvg-bench-rootdisk hvg-bench-datadisk hvg-peer-rootdisk hvg-peer-datadisk \
        --wait=true --timeout=300s >/dev/null 2>&1 || true
}

create_vm() {   # role node peer-ip image-sc
    local role="$1" node="$2" peer="$3" image_sc="$4" name="hvg-$1"
    SUSTAINED="$SUSTAINED" "${HVG[@]}" userdata "$role" "$HERE/guest/bench.py" ${peer:+"$peer"} > "$OUT/manifests/${name}-userdata.yaml"
    k create secret generic "${name}-cloudinit" --from-file=userdata="$OUT/manifests/${name}-userdata.yaml" \
        --dry-run=client -o json | k apply -f - >/dev/null
    MULTIQUEUE="$MULTIQUEUE" VM_CPU_LIMIT="$VM_CPU_LIMIT" "${HVG[@]}" vm "$name" "$NAMESPACE" "$role" "$node" "${NAMESPACE}/${IMAGE_NAME}" "$image_sc" "$DATA_SC" \
        "$VCPUS" "$MEMORY" "$ROOT_SIZE" "$DATA_SIZE" "${name}-cloudinit" "$ARCH" "$RUN_ID" \
        | tee "$OUT/manifests/${name}.json" | k apply -f - >/dev/null
    # Harvester's VM controller creates the PVCs from the volumeClaimTemplates
    # annotation. If they never appear, the VM waits forever with no event
    # that says why, so check rather than time out later.
    for _ in $(seq 1 24); do
        k get pvc "${name}-rootdisk" "${name}-datadisk" >/dev/null 2>&1 && return 0
        sleep 5
    done
    echo "ERROR: Harvester never created the PVCs for ${name}; is this a Harvester cluster?" >&2
    exit 1
}

launcher_pod() {   # vm-name -> its virt-launcher pod, waiting for it to exist
    local pod=""
    for _ in $(seq 1 60); do
        pod="$(k get pod -l "vm.kubevirt.io/name=$1" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
        [ -n "$pod" ] && { echo "$pod"; return 0; }
        sleep 5
    done
    echo "ERROR: no virt-launcher pod for $1" >&2
    exit 1
}

fetch_vm_logs() {
    local role pod
    for role in bench peer; do
        pod="$(k get pod -l "vm.kubevirt.io/name=hvg-${role}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
        [ -n "$pod" ] && k logs "$pod" -c guest-console-log > "$OUT/vm/${role}.log" 2>/dev/null || true
    done
}

# --- pod mode ------------------------------------------------------------------
run_pod() {
    mkdir -p "$OUT/pod"
    echo "==> pod mode: peer on ${PEER_NODE}"
    k create configmap hvg-program --from-file=bench.py="$HERE/guest/bench.py" \
        --dry-run=client -o json | k apply -f - >/dev/null
    "${HVG[@]}" pvc hvg-pod-data "$NAMESPACE" "$DATA_SC" "$DATA_SIZE" \
        | tee "$OUT/manifests/pod-data-pvc.json" | k apply -f - >/dev/null
    "${HVG[@]}" pod hvg-pod-peer "$NAMESPACE" peer "$PEER_NODE" "$POD_IMAGE" hvg-program "$VCPUS" "$MEMORY" \
        | tee "$OUT/manifests/pod-peer.json" | k apply -f - >/dev/null
    local peer_ip
    peer_ip="$(pod_ip hvg-pod-peer)"
    echo "    running, pod IP ${peer_ip}"
    echo "==> pod mode: bench on ${BENCH_NODE}"
    SUSTAINED="$SUSTAINED" "${HVG[@]}" pod hvg-pod-bench "$NAMESPACE" bench "$BENCH_NODE" "$POD_IMAGE" hvg-program "$VCPUS" "$MEMORY" \
        hvg-pod-data "$peer_ip" | tee "$OUT/manifests/pod-bench.json" | k apply -f - >/dev/null
    pod_ip hvg-pod-bench >/dev/null
    k get pod hvg-pod-bench hvg-pod-peer -o json > "$OUT/pod/pods.json" 2>/dev/null || true
    cg_start hvg-pod-bench bench "$OUT/pod/cgroup-cpu.log"
    echo "    running; package install, then about 15 minutes of workloads"
    wait_results "$OUT/pod" fetch_pod_logs
    cg_stop
    k delete pod hvg-pod-bench hvg-pod-peer --wait=true --timeout=120s >/dev/null 2>&1 || true
}

fetch_pod_logs() {
    k logs hvg-pod-bench > "$OUT/pod/bench.log" 2>/dev/null || true
    k logs hvg-pod-peer > "$OUT/pod/peer.log" 2>/dev/null || true
}

# --- run ---------------------------------------------------------------------
# One mode at a time, never overlapping: each is the other's baseline.
if want vm; then run_vm; fi
if want pod; then run_pod; fi

collect_sampler
for m in vm pod; do
    if [ -f "$OUT/$m/result.json" ]; then
        "${HVG[@]}" steal "$OUT/node-sampler.log" "$OUT/$m/result.json" "$OUT/$m/node-steal.json"
        if [ -s "$OUT/$m/cgroup-cpu.log" ]; then
            "${HVG[@]}" throttle "$OUT/$m/cgroup-cpu.log" "$OUT/$m/result.json" "$OUT/$m/cgroup-throttle.json"
        fi
    fi
done

echo ""
if [ -f "$OUT/vm/result.json" ]; then "${HVG[@]}" summary "$OUT"; fi
if [ -f "$OUT/vm/result.json" ] && [ -f "$OUT/pod/result.json" ]; then
    "${HVG[@]}" overhead "$OUT"
fi
"${HVG[@]}" quota "$OUT"
echo ""
echo "Results: $OUT"

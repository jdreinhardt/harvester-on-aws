#!/bin/bash
# Start a Harvester node. Called as: power_on.sh <hostname> <host IP>
set -euo pipefail
source "$(dirname "$0")/_common.sh"

ID="$(resolve_instance)"
echo "starting ${HOSTNAME} (${IP}) = ${ID}"
# Starting a stopped instance is a FRESH capacity request against the AZ -- the
# capacity was released when it stopped, and AWS can refuse to give it back.
# Measured: m8i.4xlarge in this AZ had none for ~3 minutes, which is enough to
# fail test_poweron_state even though the condition clears on its own. Retry
# rather than letting `set -e` turn a transient refusal into a hard failure.
for attempt in $(seq 1 20); do
    if ERR="$(aws ec2 start-instances --instance-ids "$ID" 2>&1 >/dev/null)"; then
        break
    fi
    case "$ERR" in
        *InsufficientInstanceCapacity*)
            if [ "$attempt" -eq 20 ]; then
                echo "ERROR: no capacity to restart ${ID} after 10 minutes: ${ERR}" >&2
                exit 1
            fi
            echo "  no capacity yet, retrying (${attempt}/20)"
            sleep 30 ;;
        *)
            echo "ERROR: start-instances failed: ${ERR}" >&2
            exit 1 ;;
    esac
done
# 'running' only means the hypervisor released it; wait for status checks so the
# OS is actually up before the test probes Harvester.
for _ in $(seq 1 80); do
    if OUT="$(aws ec2 describe-instance-status --instance-ids "$ID" \
            --query 'InstanceStatuses[0].[InstanceState.Name,InstanceStatus.Status,SystemStatus.Status]' \
            --output text 2>&1)"; then
        OK="$OUT"
    else
        # A permissions failure never resolves itself. Discarding it with
        # 2>/dev/null once cost a full timeout reported as an empty status,
        # when the real cause was a missing ec2:DescribeInstanceStatus.
        case "$OUT" in
            *UnauthorizedOperation*|*AccessDenied*|*"not authorized"*)
                echo "ERROR: ${OUT}" >&2
                exit 1 ;;
        esac
        OK=""
    fi
    [ "$OK" = "running	ok	ok" ] && { echo "  running, status checks passed"; exit 0; }
    sleep 15
done
echo "ERROR: ${ID} did not pass status checks in 20 minutes (last: ${OK:-<no status returned>})" >&2
exit 1

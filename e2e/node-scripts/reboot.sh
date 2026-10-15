#!/bin/bash
# Reboot a Harvester node. Called as: reboot.sh <hostname> <host IP>
set -euo pipefail
source "$(dirname "$0")/_common.sh"

ID="$(resolve_instance)"
echo "rebooting ${HOSTNAME} (${IP}) = ${ID}"
# reboot-instances is asynchronous and has no waiter, and the instance never
# leaves 'running' -- so watch the status checks go away and come back rather
# than watching the state.
aws ec2 reboot-instances --instance-ids "$ID" >/dev/null
sleep 30
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
    [ "$OK" = "running	ok	ok" ] && { echo "  back up, status checks passed"; exit 0; }
    sleep 15
done
echo "ERROR: ${ID} did not pass status checks in 20 minutes (last: ${OK:-<no status returned>})" >&2
exit 1

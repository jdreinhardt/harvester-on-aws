#!/bin/bash
# Stop a Harvester node. Called as: power_off.sh <hostname> <host IP>
set -euo pipefail
source "$(dirname "$0")/_common.sh"

ID="$(resolve_instance)"
echo "stopping ${HOSTNAME} (${IP}) = ${ID}"
aws ec2 stop-instances --instance-ids "$ID" >/dev/null
# Bare metal takes minutes longer than a virtualized instance. The default EC2
# waiter gives up after 40 attempts at 15s (10 minutes), which a .metal stop can
# exceed, so poll instead of using `aws ec2 wait instance-stopped`.
for _ in $(seq 1 80); do
    STATE="$(aws ec2 describe-instances --instance-ids "$ID" \
        --query 'Reservations[0].Instances[0].State.Name' --output text)"
    [ "$STATE" = stopped ] && { echo "  stopped"; exit 0; }
    sleep 15
done
echo "ERROR: ${ID} did not reach 'stopped' in 20 minutes (last state: ${STATE})" >&2
exit 1

#!/bin/bash
# Shared helper for the Harvester test suite's host-management scripts.
#
# The suite calls each script as:  <script> <hostname> <host IP>
# (see scripts/vagrant/*.example in the harvester/tests repo).
#
# We resolve the instance from the IP rather than the hostname. Our nodes are
# named harvester-<instance-id>, so the hostname would work too -- but the IP is
# passed in anyway and does not depend on that convention holding.
set -euo pipefail

usage() {
    echo "${0}: <hostname> <host IP>" >&2
    exit 1
}

[ $# -eq 2 ] || usage
HOSTNAME="$1"
IP="$2"

resolve_instance() {
    local id
    # Capture stderr rather than discarding it. Hiding it turns "no credentials"
    # or "not authorized" into "no instance has that IP", which sends you
    # looking at the wrong thing entirely.
    if ! id="$(aws ec2 describe-instances \
            --filters "Name=private-ip-address,Values=${IP}" \
                      "Name=instance-state-name,Values=pending,running,stopping,stopped" \
            --query 'Reservations[].Instances[0].InstanceId' --output text 2>&1)"; then
        echo "ERROR: describe-instances failed for ${IP} (host ${HOSTNAME}):" >&2
        echo "       ${id}" >&2
        exit 1
    fi
    if [ -z "$id" ] || [ "$id" = "None" ]; then
        echo "ERROR: no EC2 instance has private IP ${IP} (host ${HOSTNAME})." >&2
        echo "       Is AWS_PROFILE/AWS_REGION set for the cluster's account?" >&2
        exit 1
    fi
    echo "$id"
}

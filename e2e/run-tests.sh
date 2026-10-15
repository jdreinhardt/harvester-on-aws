#!/bin/bash
set -euo pipefail

# =============================================================================
# Run the upstream Harvester test suite against a cluster deployed by this
# repository.
#
# Why a runner instance rather than your laptop: the suite needs TWO kinds of
# access, and an internet-facing endpoint only gives you one of them.
#
#   1. HTTPS to the Harvester API.
#   2. SSH to each node's PRIVATE address. Several tests -- backup/restore
#      among them -- reach a guest by SSHing to the node and using it as a
#      jumphost. host_ip comes from the node's `InternalIP` in the Harvester
#      API, with no config override, and these nodes report no ExternalIP at
#      all (RKE2 runs without the AWS cloud controller, so nothing populates
#      one). There is no way to point the suite at public addresses.
#
# So the runner lives in the cluster's subnet and, importantly, in the
# cluster's own security group -- which allows all traffic from itself, giving
# the runner the node access it needs with no new rules.
#
#   ./e2e/run-tests.sh                        # launch, run the default markers, tear down
#   ./e2e/run-tests.sh --markers "p0 and images" --keep
#   ./e2e/run-tests.sh --down                 # just terminate the runner
# =============================================================================

NAME_PREFIX="terraform-cluster"
KEY_NAME="aws-testing"
KEY_FILE=""
RUNNER_TYPE="t3.medium"
RUNNER_TAG="harvester-e2e-runner"
# IAM role and instance profile used only by the host-power tests. Opt-in via
# --host-power; see ensure_instance_profile() for what it grants and why.
IAM_ROLE="harvester-e2e-runner"
HOST_POWER="false"
# Backup/restore is the thing we actually want to learn about: it is the one
# category that exercises S3 and has never been run on this deployment.
MARKERS="p0 and backup_target"
KEEP="false"
DOWN="false"
# Extra pytest arguments, e.g. --ignore of modules that cannot work here.
PYTEST_ARGS=""
# Which path(s) to collect from -- a space-separated LIST, and the order
# matters. pytest honours the order of explicitly-listed files, but ONLY when
# every target is explicit: mixing the `harvester_e2e_tests` package with
# appended files silently re-sorts them into natural order. So to force
# node-mutating modules to run last, list every module explicitly with those at
# the end -- which is what e2e/targets-full.txt does.
TARGET="harvester_e2e_tests"
RESULTS_DIR="e2e/results"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

usage() {
    cat <<USAGE
Usage: $0 [options]

  --name-prefix P   Cluster Name-tag prefix to discover. Default: ${NAME_PREFIX}
  --key-name N      EC2 key pair for the runner. Default: ${KEY_NAME}
  --key-file F      Private key. Default: \$HOME/.ssh/<key-name>.pem
  --runner-type T   Runner instance type. Default: ${RUNNER_TYPE}
  --markers M       pytest -m expression. Default: "${MARKERS}"
  --target PATHS    Space-separated list of paths to collect from, in the
                    order they should RUN. Default: ${TARGET}.
  --targets-file F  Read the target list from F, one path per line (# comments
                    allowed). Use e2e/targets-full.txt for the ordered full run
                    with the destructive modules last.
  --pytest-args A   Extra args passed through to pytest, e.g.
                    --pytest-args "--ignore=harvester_e2e_tests/integrations/test_5_vm_networks.py"
                    Needed because vlan-id: -1 does NOT skip VLAN-dependent
                    tests -- it only skips ones marked public_network, and the
                    rest then error on "VLAN ID should be in range 1-4094".
  --host-power      Give the runner an IAM instance profile so the node-scripts
                    can stop and start cluster nodes through the EC2 API.
                    Required by test_4_vm_host_powercycle.py and nothing else.
                    Creates the role on first use (idempotent).
  --keep            Leave the runner running when the tests finish.
  --down            Terminate the runner and exit.
  -h, --help        This.

Requires e2e/config.yml (copy e2e/config.example.yml and fill it in). It is
gitignored because it holds credentials.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --name-prefix) NAME_PREFIX="$2"; shift 2 ;;
        --key-name)    KEY_NAME="$2"; shift 2 ;;
        --key-file)    KEY_FILE="$2"; shift 2 ;;
        --runner-type) RUNNER_TYPE="$2"; shift 2 ;;
        --markers)     MARKERS="$2"; shift 2 ;;
        --target)      TARGET="$2"; shift 2 ;;
        --targets-file)
            [ -f "$2" ] || { echo "ERROR: targets file $2 not found" >&2; exit 1; }
            TARGET="$(grep -vE '^[[:space:]]*(#|$)' "$2" | tr '\n' ' ')"; shift 2 ;;
        --pytest-args) PYTEST_ARGS="$2"; shift 2 ;;
        --host-power)  HOST_POWER="true"; shift ;;
        --keep)        KEEP="true"; shift ;;
        --down)        DOWN="true"; shift ;;
        -h|--help)     usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
done

: "${KEY_FILE:=$HOME/.ssh/${KEY_NAME}.pem}"
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$REPO/.make/e2e_known_hosts" -o ConnectTimeout=10)

find_runner() {
    aws ec2 describe-instances \
        --filters "Name=tag:Name,Values=${RUNNER_TAG}" \
                  "Name=instance-state-name,Values=pending,running" \
        --query 'Reservations[].Instances[0].InstanceId' --output text 2>/dev/null | tr -d '\n'
}

# --- IAM for the host-power tests -------------------------------------------
# test_4_vm_host_powercycle.py is the ONLY part of the suite that needs AWS
# credentials. It calls e2e/node-scripts/*.sh, which stop and start the node
# through the EC2 API, and those run ON the runner -- so without an instance
# profile resolve_instance() finds nothing, exits 1, and the suite reports
# "Failed to PowerOff node" with rc=1. Everything else talks only to the
# Harvester API, which is why this is opt-in rather than always-on: a run that
# does not include the powercycle module needs no IAM at all.
#
# Scoping. ec2:DescribeInstances cannot be restricted by resource -- EC2's
# describe calls do not support resource-level permissions -- so it is granted
# on "*". The calls that actually change state are restricted to instances
# carrying a HarvesterRole tag, which both the Terraform node definitions and
# the CloudFormation node definitions set (create/join/worker) and nothing else
# in the account carries. The runner itself is tagged only with Name, so this
# policy does not let it stop itself, the NLB's targets aside from nodes, or
# any unrelated instance.
iam_trust_document() {
    cat <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "ec2.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}
JSON
}

iam_policy_document() {
    cat <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DescribeIsNotResourceScopable",
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeInstances",
        "ec2:DescribeInstanceStatus"
      ],
      "Resource": "*"
    },
    {
      "Sid": "PowerCycleTaggedHarvesterNodesOnly",
      "Effect": "Allow",
      "Action": [
        "ec2:StartInstances",
        "ec2:StopInstances",
        "ec2:RebootInstances"
      ],
      "Resource": "arn:aws:ec2:*:*:instance/*",
      "Condition": {
        "StringLike": {"aws:ResourceTag/HarvesterRole": "*"}
      }
    }
  ]
}
JSON
}

# Idempotent, and written so a partially-created set of objects converges
# rather than erroring: each piece is checked for separately because a failed
# earlier run can leave the role without its profile, or the profile without
# its role.
ensure_instance_profile() {
    aws iam get-role --role-name "$IAM_ROLE" >/dev/null 2>&1 || {
        echo "    creating IAM role ${IAM_ROLE}"
        aws iam create-role --role-name "$IAM_ROLE" \
            --description "Lets the Harvester e2e runner power-cycle tagged cluster nodes" \
            --assume-role-policy-document "$(iam_trust_document)" >/dev/null
    }
    # Always re-put: the policy is the part most likely to change, and
    # put-role-policy overwrites in place.
    aws iam put-role-policy --role-name "$IAM_ROLE" --policy-name node-power \
        --policy-document "$(iam_policy_document)" >/dev/null

    aws iam get-instance-profile --instance-profile-name "$IAM_ROLE" >/dev/null 2>&1 || {
        echo "    creating instance profile ${IAM_ROLE}"
        aws iam create-instance-profile --instance-profile-name "$IAM_ROLE" >/dev/null
    }
    local attached
    attached="$(aws iam get-instance-profile --instance-profile-name "$IAM_ROLE" \
        --query 'InstanceProfile.Roles[].RoleName' --output text 2>/dev/null)"
    case " ${attached} " in
        *" ${IAM_ROLE} "*) ;;
        *) aws iam add-role-to-instance-profile --instance-profile-name "$IAM_ROLE" \
               --role-name "$IAM_ROLE" >/dev/null ;;
    esac
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
[ -f "$REPO/e2e/config.yml" ] || {
    echo "ERROR: $REPO/e2e/config.yml not found." >&2
    echo "       cp e2e/config.example.yml e2e/config.yml  and fill it in." >&2
    exit 1
}
[ -f "$KEY_FILE" ] || { echo "ERROR: key file $KEY_FILE not found (--key-file)" >&2; exit 1; }

if grep -q 'REPLACE-WITH' "$REPO/e2e/config.yml"; then
    echo "ERROR: e2e/config.yml still has REPLACE-WITH placeholders:" >&2
    grep -n 'REPLACE-WITH' "$REPO/e2e/config.yml" | sed 's/^/       /' >&2
    exit 1
fi

# --- discover the cluster ---------------------------------------------------
echo "==> discovering cluster '${NAME_PREFIX}-*'"
read -r NODE_ID SUBNET SG <<<"$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=${NAME_PREFIX}-node-*" "Name=instance-state-name,Values=running" \
    --query 'Reservations[0].Instances[0].[InstanceId,SubnetId,SecurityGroups[0].GroupId]' \
    --output text 2>/dev/null)"
[ -n "${SG:-}" ] && [ "$SG" != "None" ] || {
    echo "ERROR: found no running instances tagged ${NAME_PREFIX}-node-*" >&2
    exit 1
}
NODE_COUNT="$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=${NAME_PREFIX}-node-*" "Name=instance-state-name,Values=running" \
    --query 'length(Reservations[].Instances[])' --output text)"

# The VIP is a secondary private address on whichever node holds it -- node 1
# today, but the discovery above returns an arbitrary node, so search them all
# rather than assuming. Deriving it beats asking for it again in config.yml,
# where it could drift out of date.
VIP="$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=${NAME_PREFIX}-node-*" "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[].NetworkInterfaces[].PrivateIpAddresses[?Primary==`false`].PrivateIpAddress[]' \
    --output text 2>/dev/null | tr '\t' '\n' | head -1)"
[ -n "$VIP" ] || {
    echo "ERROR: no node in ${NAME_PREFIX}-* carries a secondary private IP," >&2
    echo "       so there is no VIP to target. Is the cluster fully up?" >&2
    exit 1
}
echo "    nodes: ${NODE_COUNT}   subnet: ${SUBNET}   sg: ${SG}   vip: ${VIP}"

# A powercycle run without --host-power fails at the first assertion, three
# hours in if it is at the end of an ordered target list. Say so up front.
case "$TARGET" in
    *powercycle*)
        if [ "$HOST_POWER" != "true" ]; then
            echo "WARNING: the targets include test_4_vm_host_powercycle.py but"
            echo "         --host-power was not given. The runner will have no EC2"
            echo "         credentials, node-scripts/power_off.sh cannot resolve the"
            echo "         instance, and those tests will fail with rc=1."
        fi ;;
esac

# --- launch the runner ------------------------------------------------------
# Note the `if` rather than `[ ... ] && ensure_instance_profile`: under `set -e`
# a trailing false test is the script's exit status, so the && form would kill
# a run that simply did not ask for host-power.
if [ "$HOST_POWER" = "true" ]; then
    ensure_instance_profile
fi

ID="$(find_runner)"
if [ -n "$ID" ] && [ "$ID" != "None" ]; then
    echo "==> reusing runner $ID"
    # A profile can be attached to a RUNNING instance and reaches IMDS within
    # seconds, so a runner launched without --host-power is fixed in place
    # rather than relaunched -- which matters when the runner holds a venv and
    # a clone you do not want to rebuild.
    if [ "$HOST_POWER" = "true" ]; then
        ASSOC="$(aws ec2 describe-iam-instance-profile-associations \
            --filters "Name=instance-id,Values=${ID}" \
            --query 'IamInstanceProfileAssociations[?State!=`disassociated`].IamInstanceProfile.Arn' \
            --output text 2>/dev/null)"
        if [ -z "$ASSOC" ] || [ "$ASSOC" = "None" ]; then
            echo "    attaching instance profile ${IAM_ROLE}"
            # Same eventual-consistency problem as run-instances below, and it
            # bites harder here: this is the path taken the very first time
            # --host-power is used against an already-running runner, moments
            # after ensure_instance_profile created the profile.
            for attempt in $(seq 1 12); do
                if ERR="$(aws ec2 associate-iam-instance-profile --instance-id "$ID" \
                        --iam-instance-profile "Name=${IAM_ROLE}" 2>&1 >/dev/null)"; then
                    break
                fi
                case "$ERR" in
                    *"Invalid IAM Instance Profile"*|*"iamInstanceProfile"*)
                        if [ "$attempt" -eq 12 ]; then
                            echo "ERROR: ${IAM_ROLE} never became usable: $ERR" >&2
                            exit 1
                        fi
                        echo "    waiting for ${IAM_ROLE} to propagate (${attempt}/12)"
                        sleep 5 ;;
                    *)
                        echo "ERROR: associate-iam-instance-profile failed: $ERR" >&2
                        exit 1 ;;
                esac
            done
        fi
    fi
else
    echo "==> launching runner (${RUNNER_TYPE})"
    OS_AMI="$(aws ssm get-parameter \
        --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
        --query 'Parameter.Value' --output text)"
    ROOT_DEV="$(aws ec2 describe-images --image-ids "$OS_AMI" \
        --query 'Images[0].RootDeviceName' --output text)"
    # Same security group as the nodes: it allows all traffic from itself, so
    # the runner gets API and SSH access to every node without a new rule.
    LAUNCH_ARGS=(--image-id "$OS_AMI" --instance-type "$RUNNER_TYPE" \
        --subnet-id "$SUBNET" --security-group-ids "$SG" \
        --key-name "$KEY_NAME" --associate-public-ip-address \
        --block-device-mappings "DeviceName=${ROOT_DEV},Ebs={VolumeSize=30,VolumeType=gp3,DeleteOnTermination=true}" \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${RUNNER_TAG}}]" \
        --query 'Instances[0].InstanceId' --output text)
    if [ "$HOST_POWER" = "true" ]; then
        LAUNCH_ARGS+=(--iam-instance-profile "Name=${IAM_ROLE}")
    fi

    # IAM is eventually consistent: a profile created seconds ago is routinely
    # not yet visible to run-instances, which rejects the call outright instead
    # of waiting. Retry rather than making the caller re-run the script.
    for attempt in $(seq 1 12); do
        if ID="$(aws ec2 run-instances "${LAUNCH_ARGS[@]}" 2>&1)"; then
            break
        fi
        case "$ID" in
            *"Invalid IAM Instance Profile"*|*"iamInstanceProfile"*)
                if [ "$attempt" -eq 12 ]; then
                    echo "ERROR: ${IAM_ROLE} never became usable: $ID" >&2
                    exit 1
                fi
                echo "    waiting for ${IAM_ROLE} to propagate (${attempt}/12)"
                sleep 5 ;;
            *)
                echo "ERROR: run-instances failed: $ID" >&2
                exit 1 ;;
        esac
    done
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
        echo "  $0 --down   # when finished"
    else
        echo ""
        echo "==> terminating runner $ID"
        aws ec2 terminate-instances --instance-ids "$ID" >/dev/null || true
    fi
}
trap cleanup EXIT

mkdir -p "$REPO/.make"
echo "==> waiting for SSH"
for _ in $(seq 1 40); do
    ssh "${SSH_OPTS[@]}" -i "$KEY_FILE" "ec2-user@$IP" true 2>/dev/null && break || sleep 10
done
ssh "${SSH_OPTS[@]}" -i "$KEY_FILE" "ec2-user@$IP" true

# --- provision --------------------------------------------------------------
echo "==> provisioning"
scp "${SSH_OPTS[@]}" -i "$KEY_FILE" -q "$HERE/runner-provision.sh" "ec2-user@$IP:/tmp/"
ssh "${SSH_OPTS[@]}" -i "$KEY_FILE" "ec2-user@$IP" 'mkdir -p ~/node-scripts'
scp "${SSH_OPTS[@]}" -i "$KEY_FILE" -q "$HERE"/node-scripts/*.sh "ec2-user@$IP:~/node-scripts/"

ssh "${SSH_OPTS[@]}" -i "$KEY_FILE" "ec2-user@$IP" 'chmod +x ~/node-scripts/*.sh /tmp/runner-provision.sh'

# Provisioning clones the suite, so it must run BEFORE the config is placed:
# git clone refuses a non-empty directory, and the clone would overwrite our
# config.yml with the repo's own anyway.
ssh "${SSH_OPTS[@]}" -i "$KEY_FILE" "ec2-user@$IP" 'bash /tmp/runner-provision.sh'

echo "==> config"
scp "${SSH_OPTS[@]}" -i "$KEY_FILE" -q "$REPO/e2e/config.yml" "ec2-user@$IP:~/harvester-tests/config.yml"
# Only now can pytest be invoked at all: conftest.py does a bare
# open('config.yml'), relative to the CWD, while parsing options.
ssh "${SSH_OPTS[@]}" -i "$KEY_FILE" "ec2-user@$IP" \
    'cd ~/harvester-tests && ./.venv/bin/pytest harvester_e2e_tests --collect-only -q 2>&1 | tail -2'

# --- run --------------------------------------------------------------------
echo "==> running: -m \"${MARKERS}\""
echo "    targets: $(echo ${TARGET} | wc -w | tr -d ' ') path(s), in run order"
echo "    endpoint ${VIP} (derived), node scripts ~/node-scripts"
echo ""
RC=0
ssh "${SSH_OPTS[@]}" -i "$KEY_FILE" -t "ec2-user@$IP" "
    cd ~/harvester-tests &&
    ./.venv/bin/pytest ${TARGET} \
        -m '${MARKERS}' \
        --endpoint 'https://${VIP}' \
        --node-scripts-location \$HOME/node-scripts \
        --html=report.html --self-contained-html \
        --json-report --json-report-file=report.json \
        ${PYTEST_ARGS} \
        -v 2>&1 | tee pytest.log
" || RC=$?

# --- collect ----------------------------------------------------------------
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$REPO/${RESULTS_DIR}/${STAMP}"
mkdir -p "$OUT"
echo ""
echo "==> collecting results into ${RESULTS_DIR}/${STAMP}/"
for f in report.html report.json pytest.log; do
    scp "${SSH_OPTS[@]}" -i "$KEY_FILE" -q "ec2-user@$IP:~/harvester-tests/$f" "$OUT/" 2>/dev/null \
        && echo "    $f" || echo "    $f (not produced)"
done

if [ -f "$OUT/report.json" ]; then
    python3 - "$OUT/report.json" <<'PY' || true
import json, sys
d = json.load(open(sys.argv[1]))
s = d.get("summary", {})
order = ["passed", "failed", "error", "skipped", "xfailed", "xpassed"]
print("    " + "  ".join(f"{k}={s[k]}" for k in order if k in s))
PY
fi

echo ""
[ "$RC" -eq 0 ] && echo "pytest exited 0" || echo "pytest exited ${RC} (non-zero is expected while gaps remain)"
exit 0

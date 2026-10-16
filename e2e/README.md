# Running the upstream Harvester test suite against this deployment

The [harvester/tests](https://github.com/harvester/tests) e2e suite, pointed at
a cluster built by this repository.

| File | What it is |
| --- | --- |
| `run-tests.sh` | Discovers the cluster, launches a runner instance, provisions it, runs pytest, collects results into `results/<timestamp>/`. |
| `runner-provision.sh` | Runs *on* the runner: clones the suite, builds the venv. Deliberately knows nothing about `config.yml`. |
| `config.example.yml` | Every key the suite reads, annotated. Copy to `config.yml` and fill in. |
| `config.yml` | Gitignored — it holds credentials. |
| `targets-full.txt` | The module list in run order, with node-mutating modules last. |
| `node-scripts/` | The host power scripts the suite shells out to, implemented against the EC2 API. |

The runner exists because the suite needs two kinds of access at once: HTTPS to
the Harvester API, and SSH to each node's **private** address. Several tests use
a node as a jumphost to reach a guest, taking `host_ip` from the node's
`InternalIP` with no config override — and these nodes report no `ExternalIP`
at all, because RKE2 runs without the AWS cloud controller. So the suite has to
run from inside the VPC.

```bash
./e2e/run-tests.sh --targets-file e2e/targets-full.txt --markers "p0" --keep \
  --host-key-file ~/.ssh/harvester-e2e-rsa.pem
```

## Node SSH: an RSA key pair for test clusters

Node SSH is key-only — password authentication is off and the `rancher` user's
password is unusable unless a hash was set at deploy time — so the suite has to
reach the nodes with the cluster's key. It can only load **RSA** keys: both
`host_shell` and the VM jumphost path call `paramiko.RSAKey.from_private_key`,
which fails on ED25519 with "unpack requires a buffer of 4 bytes".

So deploy test clusters with a dedicated RSA EC2 key pair, and keep ED25519 for
everything else:

```bash
aws ec2 create-key-pair --key-name harvester-e2e-rsa --key-type rsa \
  --key-format pem --query KeyMaterial --output text > ~/.ssh/harvester-e2e-rsa.pem
chmod 0600 ~/.ssh/harvester-e2e-rsa.pem
```

Use it as the cluster's `KeyName` / `key_name`, then pass it to
`--host-key-file` (or use it for the runner too, via `--key-name`, and let
`--host-key-file` default to `--key-file`). `run-tests.sh`:

* checks the key is RSA and unencrypted before launching anything;
* copies it into the **runner's** copy of `config.yml` as `host-private-key`
  and clears `host-password`. Your local `config.yml` keeps both empty, so the
  private key is never written into it.

`--host-key-file none` skips this and uses `config.yml`'s host credentials as
they are — only useful against a cluster built before node SSH became key-only.

## IAM: only the host-power tests need it

`test_4_vm_host_powercycle.py` is the only module that needs AWS credentials.
It shells out to `node-scripts/power_off.sh` and `power_on.sh`, which stop and
start the node through the EC2 API — and those run *on* the runner. Without an
instance profile, `resolve_instance()` finds nothing, exits 1, and the test
fails at its first assertion with `Failed to PowerOff node`.

Everything else in the suite talks only to the Harvester API. If you are not
running the powercycle module you can ignore this section entirely; the runner
needs no AWS permissions at all.

To opt in, add `--host-power`. The role and instance profile
(`harvester-e2e-runner`) are created on first use and the operation is
idempotent, so it is safe to pass on every run:

```bash
./e2e/run-tests.sh --targets-file e2e/targets-full.txt --host-power --keep
```

A profile can be attached to an already-running instance, so adding the flag to
a run that reuses a `--keep`'d runner fixes it in place — no relaunch, and the
venv and clone survive.

### The policy

`ec2:DescribeInstances` is granted on `*` because EC2's describe calls do not
support resource-level permissions. The calls that actually change state are
restricted to this account and region, and to instances carrying both a
`HarvesterRole` tag (which the Terraform and CloudFormation node definitions
set) **and** a `Name` of `<name-prefix>-node-*` — the same pattern the script
uses to discover the cluster, and the one both deployments use
(`<name_prefix>-node-N`, `<StackName>-node-N`). `HarvesterRole` alone is not
enough: every cluster deployed from this repo carries it, so a test run could
otherwise stop another, real cluster's nodes. The runner itself is tagged only
with `Name=harvester-e2e-runner`, so it cannot stop itself.

The role is shared between runs and the policy is re-put on every
`--host-power` run, so it always names the most recently tested cluster. The
node scripts apply the same scope when resolving an IP to an instance, from a
`cluster.env` file `run-tests.sh` places beside them.

```json
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
      "Resource": "arn:aws:ec2:<region>:<account>:instance/*",
      "Condition": {
        "StringLike": {
          "aws:ResourceTag/HarvesterRole": "*",
          "aws:ResourceTag/Name": "<name-prefix>-node-*"
        }
      }
    }
  ]
}
```

The trust policy allows `ec2.amazonaws.com` to assume the role, and nothing
else. Both documents are defined in `run-tests.sh` (`iam_policy_document` and
`iam_trust_document`) so the script is the source of truth; this section is a
copy for review.

### What *your* credentials need

`--host-power` creates IAM objects and attaches them, so the credentials you run
`run-tests.sh` with need `iam:CreateRole`, `iam:PutRolePolicy`,
`iam:CreateInstanceProfile`, `iam:AddRoleToInstanceProfile`, `iam:PassRole`, and
`ec2:AssociateIamInstanceProfile` — on top of the EC2 permissions the script
already uses. Without `--host-power` none of these are touched.

### Removing it

`--down` terminates the runner but leaves the role in place, since it is
reusable and grants nothing on its own. To remove it completely:

```bash
aws iam remove-role-from-instance-profile --instance-profile-name harvester-e2e-runner --role-name harvester-e2e-runner
aws iam delete-instance-profile --instance-profile-name harvester-e2e-runner
aws iam delete-role-policy --role-name harvester-e2e-runner --policy-name node-power
aws iam delete-role --role-name harvester-e2e-runner
```

## Known environmental results

These fail for reasons that are not Harvester defects. They are recorded here so
they are not re-diagnosed each run.

| Test | Why |
| --- | --- |
| `TestVMResource::test_update_schedule_on_maximum[memory]` | Sizes a VM at the midpoint between the roomiest and second-roomiest node's schedulable memory, to prove the scheduler picks the roomiest. On a homogeneous cluster those two values are nearly equal, so the midpoint lands at ~a whole node and KubeVirt's virt-launcher overhead pushes the pod request past what any node can take. Needs spread in free memory between nodes, which identical instance types from one AMI do not provide. |
| `TestHostState::test_poweron_state` | Stopping an instance releases its capacity to the AZ; starting it again is a fresh request AWS can refuse with `InsufficientInstanceCapacity`. Measured on `m8i.4xlarge`: no capacity for ~3 minutes, long enough to fail the test. `power_on.sh` now retries for 10 minutes, but a longer shortage will still fail it — and the node stays stopped until capacity returns. Not a Harvester or harness defect; a property of stop/start on EC2. |
| Anything requiring `--vlan-id` or `--vlan-nic` | EC2 ENAs do not pass VLAN-tagged frames. Structural; see the repository README. |

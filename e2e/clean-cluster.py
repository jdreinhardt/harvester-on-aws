#!/usr/bin/env python3
"""Return a Harvester test cluster to a clean state between e2e runs.

Why this exists: the suite does not always clean up after itself, and leftovers
are not inert. A stale secret or image makes TestInvalidEncryptionSecret fail
with "secret ... not found" and errors its teardown, and a timed-out
maintenance-mode test leaves its target node cordoned -- which then skews every
later test that picks a node. Several findings in this project's first full run
turned out to be residue rather than defects.

Runs against the VIP, so it needs to be inside the VPC: scp it to the test
runner and run it there with the suite's own venv, e.g.

    scp -i KEY e2e/clean-cluster.py ec2-user@RUNNER:/tmp/
    ssh -i KEY ec2-user@RUNNER '~/harvester-tests/.venv/bin/python -I /tmp/clean-cluster.py \
        --config ~/harvester-tests/config.yml --endpoint https://<VIP> --yes'

Pass --endpoint explicitly: config.yml's own `endpoint` is typically the
cluster's public address, which is NOT reachable from inside the VPC. run-tests.sh
ignores it too and passes pytest --endpoint https://<VIP>, which is why the suite
works while a naive read of the config does not.

Only ever touches the `default` namespace -- the namespace the suite creates its
fixtures in. Built-in templates and images live in `harvester-public` and are
left alone. Deletes nothing without --yes.
"""
import argparse
import sys
import time

import requests
import urllib3
import yaml

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

NAMESPACE = "default"
# Order matters: a volume pins the image it was cloned from, and an image pins
# the secret that encrypts it, so the dependants have to go first.
RESOURCES = [
    ("kubevirt.io.virtualmachines", "virtual machines"),
    ("persistentvolumeclaims", "volumes"),
    ("harvesterhci.io.virtualmachineimages", "images"),
    ("secrets", "secrets"),
]


def load_config(path):
    with open(path) as fh:
        cfg = yaml.safe_load(fh)
    return cfg["endpoint"], cfg["username"], cfg["password"]


def session_for(endpoint, user, passwd):
    s = requests.Session()
    s.verify = False
    r = s.post(f"{endpoint}/v3-public/localProviders/local?action=login",
               json={"username": user, "password": passwd, "responseType": "token"},
               timeout=30)
    r.raise_for_status()
    s.headers["Authorization"] = f"Bearer {r.json()['token']}"
    return s


# Settings the suite mutates and does not reliably put back. overcommit-config
# is the one that actually bit us: set_cpu_memory_overcommit's teardown assigns
# spec.val instead of spec.value, so it never restores, and the cluster is left
# at cpu 2400 / memory 800 -- which silently changes the resource maths for
# every later test and for the next run. The target is whatever the setting
# reports as its own `default`, read at run time rather than hardcoded.
#
# Deliberately NOT a blanket "reset everything that differs from default":
# backup-target holds the S3 configuration this harness depends on, and
# clearing it would break the backup tests rather than fix anything.
RESET_SETTINGS = ("overcommit-config", "additional-guest-memory-overhead-ratio")


def reset_settings(s, endpoint, dry_run):
    for name in RESET_SETTINGS:
        r = s.get(f"{endpoint}/v1/harvester/harvesterhci.io.settings/{name}", timeout=30)
        if r.status_code != 200:
            print(f"  {name}: HTTP {r.status_code}, skipped")
            continue
        data = r.json()
        default, value = data.get("default", ""), data.get("value", "")
        if not value or value == default:
            continue
        print(f"  {name}: {value}  ->  {default or '<unset>'}")
        if dry_run:
            continue
        body = dict(data)
        body["value"] = default
        u = s.put(f"{endpoint}/v1/harvester/harvesterhci.io.settings/{name}",
                  json=body, timeout=30)
        print(f"    {u.status_code}" + ("" if u.status_code == 200 else f"  <- {u.text[:140]}"))


def release_nodes(s, endpoint, dry_run):
    """Clear maintenance mode on any node still in it, and uncordon.

    Uncordoning alone is not enough: the node keeps its maintain-status
    annotation and Harvester still considers it in maintenance.
    """
    nodes = s.get(f"{endpoint}/v1/harvester/nodes", timeout=30).json().get("data", [])
    for n in nodes:
        name = n["metadata"]["name"]
        maint = n["metadata"].get("annotations", {}).get("harvesterhci.io/maintain-status")
        cordon = n.get("spec", {}).get("unschedulable", False)
        if not maint and not cordon:
            continue
        print(f"  node {name}: maint={maint} cordon={cordon}")
        if dry_run:
            continue
        r = s.post(f"{endpoint}/v1/harvester/nodes/{name}",
                   params={"action": "disableMaintenanceMode"},
                   json={"force": "false"}, timeout=60)
        print(f"    disableMaintenanceMode -> {r.status_code}")
        for _ in range(40):
            cur = s.get(f"{endpoint}/v1/harvester/nodes/{name}", timeout=30).json()
            if not cur.get("spec", {}).get("unschedulable", False):
                break
            time.sleep(3)
        else:
            print(f"    WARNING: {name} is still cordoned")


def purge(s, endpoint, dry_run):
    failures = []
    for kind, label in RESOURCES:
        items = [i for i in s.get(f"{endpoint}/v1/harvester/{kind}", timeout=30).json().get("data", [])
                 if i["metadata"].get("namespace") == NAMESPACE]
        print(f"  {label}: {len(items)}")
        for i in items:
            name = i["metadata"]["name"]
            if dry_run:
                print(f"    would delete {name}")
                continue
            r = s.delete(f"{endpoint}/v1/harvester/{kind}/{NAMESPACE}/{name}", timeout=60)
            ok = r.status_code in (200, 202, 204)
            print(f"    {r.status_code} {name}" + ("" if ok else f"  <- {r.text[:160]}"))
            if not ok:
                failures.append((kind, name, r.text[:160]))
        # Deletion is not instant and the next kind may depend on this one
        # finishing, so give the controllers a moment before moving on.
        if items and not dry_run:
            time.sleep(8)
    return failures


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--config", default="config.yml", help="path to the suite config (default: config.yml)")
    # config.yml's `endpoint` is usually the cluster's PUBLIC address, which is
    # not reachable from inside the VPC -- run-tests.sh ignores it and passes
    # pytest --endpoint https://<VIP> instead. Same override here.
    ap.add_argument("--endpoint", help="override config.yml's endpoint, e.g. https://<VIP>")
    ap.add_argument("--yes", action="store_true", help="actually delete; without it this is a dry run")
    args = ap.parse_args()

    endpoint, user, passwd = load_config(args.config)
    endpoint = args.endpoint or endpoint
    dry = not args.yes
    print(f"cluster: {endpoint}   namespace: {NAMESPACE}" + ("   [DRY RUN]" if dry else ""))
    s = session_for(endpoint, user, passwd)

    print("== nodes ==")
    release_nodes(s, endpoint, dry)
    print("== settings ==")
    reset_settings(s, endpoint, dry)
    print("== resources ==")
    failures = purge(s, endpoint, dry)

    if failures:
        print("\nNOT deleted:")
        for kind, name, msg in failures:
            print(f"  {kind}/{name}: {msg}")
        print("\nA volume pins its source image and an image pins its secret;"
              " re-run once the dependants are gone.")
        return 1
    if dry:
        print("\nDry run. Re-run with --yes to delete.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

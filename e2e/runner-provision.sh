#!/bin/bash
set -euo pipefail

# =============================================================================
# Runs ON the test-runner instance. Installs the upstream Harvester test suite.
#
# Deliberately knows nothing about config.yml. conftest.py does a bare
# open('config.yml') while parsing options, so anything that invokes pytest
# needs the config in place first -- but the clone cannot happen into a
# directory that already holds one. Keeping that ordering in run-tests.sh,
# which owns the config, avoids the circular dependency.
#
# Idempotent: safe to re-run against a --keep'd runner, and fast when nothing
# has changed.
# =============================================================================

TESTS_REPO="${TESTS_REPO:-https://github.com/harvester/tests.git}"
TESTS_DIR="${TESTS_DIR:-$HOME/harvester-tests}"

echo "==> packages"
# AL2023's default python3 is 3.9. Prefer 3.11: new enough for the pinned deps,
# old enough that manylinux wheels exist for all of them, so nothing compiles.
sudo dnf -y -q install git python3.11 python3.11-pip >/dev/null 2>&1 || \
    sudo dnf -y -q install git python3 python3-pip >/dev/null 2>&1
PY="$(command -v python3.11 || command -v python3)"
echo "    python: $PY ($($PY --version))"

echo "==> clone"
if [ -d "$TESTS_DIR/.git" ]; then
    git -C "$TESTS_DIR" fetch --quiet origin
    git -C "$TESTS_DIR" reset --quiet --hard origin/HEAD
    echo "    updated existing clone"
else
    # A non-empty directory without .git means a previous run died between
    # creating it and cloning. git clone refuses to write into it, so clear it.
    [ -e "$TESTS_DIR" ] && rm -rf "$TESTS_DIR"
    git clone --quiet "$TESTS_REPO" "$TESTS_DIR"
    echo "    cloned"
fi

cd "$TESTS_DIR"

# Reuse the venv when it is already complete -- this is what makes a re-run
# against a --keep'd runner quick. harvester_api is the real test of
# completeness: it is the step most likely to have been missed.
if [ -x .venv/bin/pytest ] && ./.venv/bin/python -c "import harvester_api" 2>/dev/null; then
    echo "==> venv already complete, reusing"
else
    echo "==> venv and dependencies"
    # rm -rf, not plain `venv`: `python -m venv` silently no-ops on an existing
    # directory and keeps the old interpreter, leaving pip installing into one
    # site-packages tree while the interpreter reads another.
    rm -rf .venv
    "$PY" -m venv .venv
    ./.venv/bin/pip install --quiet --upgrade pip
    ./.venv/bin/pip install --quiet -r test-requirements.txt
    # The step the README omits. harvester_api is the repo's OWN apiclient/
    # directory; only tox.ini installs it, as a separate command. Without this,
    # collection fails with 28 ImportErrors for "No module named 'harvester_api'".
    ./.venv/bin/pip install --quiet --no-deps -e ./apiclient
fi

echo "==> installed"
./.venv/bin/python -c "import harvester_api, pytest; print('    harvester_api OK, pytest', pytest.__version__)"

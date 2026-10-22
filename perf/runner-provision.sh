#!/bin/bash
set -euo pipefail

# =============================================================================
# Runs ON the perf runner instance. Installs hvperf and the tools its
# etcd-benchmark suite ships into the cluster -- natively, without Docker.
#
# Why not the upstream container image: etcd-benchmark copies
# /usr/local/bin/{etcdctl,benchmark,promtool} from wherever hvperf runs into a
# job pod ON A NODE. Those three binaries must therefore match the NODES'
# architecture, not the runner's. The image bakes in one architecture
# (IMAGE_PLATFORMS, default linux/amd64), which silently produces
# "exec format error" against a Graviton cluster. Cross-compiling here with
# GOARCH=$NODE_GOARCH keeps the runner itself on any architecture.
#
# Tool versions are read from the clone's own Dockerfile, so they track
# whatever upstream pins without being restated here.
#
# Inputs (environment):
#   NODE_GOARCH  amd64 | arm64 -- the cluster's architecture. Required.
#   PERF_REF     branch, tag or commit of harvester-perf. Default: origin/HEAD.
#   GO_VERSION   e.g. go1.26.3. Default: the newest stable release.
#   KUBECTL_VERSION  e.g. v1.35.7. Installs kubectl, for the guest suite
#                (perf/guest-bench.sh). Default: unset, no kubectl.
#
# Idempotent: re-running against a --keep'd runner rebuilds only what changed.
# =============================================================================

: "${NODE_GOARCH:?NODE_GOARCH must be amd64 or arm64}"
case "$NODE_GOARCH" in amd64|arm64) ;; *) echo "ERROR: NODE_GOARCH=$NODE_GOARCH" >&2; exit 1 ;; esac
PERF_REPO="${PERF_REPO:-https://github.com/harvester/harvester-perf.git}"
PERF_DIR="${PERF_DIR:-$HOME/harvester-perf}"
PERF_REF="${PERF_REF:-}"
GO_VERSION="${GO_VERSION:-}"
KUBECTL_VERSION="${KUBECTL_VERSION:-}"
TOOLS_STAMP=/usr/local/bin/.hvperf-tools

case "$(uname -m)" in
    x86_64)  HOST_GOARCH=amd64 ;;
    aarch64) HOST_GOARCH=arm64 ;;
    *) echo "ERROR: unsupported runner architecture $(uname -m)" >&2; exit 1 ;;
esac

echo "==> packages"
# iperf3: the guest suite's VPC test uses the runner as its VPC host.
sudo dnf -y -q install git tar gzip python3 iperf3 >/dev/null

# --- Go ----------------------------------------------------------------------
# AL2023's packaged Go lags upstream, and hvperf's go.mod asks for 1.26+. Take
# the release straight from go.dev, checked against the sha256 published in the
# same JSON index.
echo "==> go"
GO_FILE_JSON="$(curl -fsSL 'https://go.dev/dl/?mode=json&include=all' | python3 -c '
import json, sys
want, arch = sys.argv[1], sys.argv[2]
for rel in json.load(sys.stdin):
    if (want and rel["version"] != want) or (not want and not rel["stable"]):
        continue
    for f in rel["files"]:
        if f["os"] == "linux" and f["arch"] == arch and f["kind"] == "archive":
            print(rel["version"], f["filename"], f["sha256"])
            sys.exit(0)
sys.exit("no matching Go release for " + (want or "latest stable"))
' "$GO_VERSION" "$HOST_GOARCH")"
read -r GO_WANT GO_TARBALL GO_SHA <<<"$GO_FILE_JSON"
if [ "$(/usr/local/go/bin/go env GOVERSION 2>/dev/null || true)" = "$GO_WANT" ]; then
    echo "    $GO_WANT already installed"
else
    curl -fsSL -o "/tmp/$GO_TARBALL" "https://go.dev/dl/$GO_TARBALL"
    echo "$GO_SHA  /tmp/$GO_TARBALL" | sha256sum -c --quiet
    sudo rm -rf /usr/local/go
    sudo tar -C /usr/local -xzf "/tmp/$GO_TARBALL"
    rm -f "/tmp/$GO_TARBALL"
    echo "    installed $GO_WANT"
fi
export PATH="/usr/local/go/bin:$PATH"
# A newer toolchain than go.mod asks for is fine; never let go fetch another.
export GOTOOLCHAIN=local

# proxy.golang.org resets HTTP/2 streams now and then ("stream error ...
# INTERNAL_ERROR"), which failed a whole run at the first build on 2026-10-19.
# Fetch modules up front, retrying, so the builds themselves never download.
go_fetch() {   # dir
    local attempt
    for attempt in 1 2 3 4 5; do
        if (cd "$1" && go mod download); then
            return 0
        fi
        echo "    module download failed in $1 (attempt ${attempt}/5); retrying in $((attempt * 15))s"
        sleep $((attempt * 15))
    done
    echo "ERROR: could not download Go modules for $1 after 5 attempts" >&2
    return 1
}

# --- harvester-perf ----------------------------------------------------------
echo "==> clone"
if [ -d "$PERF_DIR/.git" ]; then
    git -C "$PERF_DIR" fetch --quiet --tags origin
    echo "    updated existing clone"
else
    [ -e "$PERF_DIR" ] && rm -rf "$PERF_DIR"
    git clone --quiet "$PERF_REPO" "$PERF_DIR"
    echo "    cloned"
fi
if [ -n "$PERF_REF" ]; then
    # A branch name resolves against origin; a tag or sha resolves as itself.
    git -C "$PERF_DIR" checkout --quiet --detach "origin/$PERF_REF" 2>/dev/null \
        || git -C "$PERF_DIR" checkout --quiet --detach "$PERF_REF"
else
    git -C "$PERF_DIR" checkout --quiet --detach origin/HEAD
fi
PERF_SHA="$(git -C "$PERF_DIR" rev-parse --short HEAD)"
echo "    harvester-perf at $PERF_SHA"

echo "==> hvperf"
if [ "$(/usr/local/bin/hvperf version --client-only 2>/dev/null | grep -o "+${PERF_SHA}" || true)" = "+${PERF_SHA}" ]; then
    echo "    already built at $PERF_SHA"
else
    go_fetch "$PERF_DIR"
    (cd "$PERF_DIR" && CGO_ENABLED=0 go build -trimpath \
        -ldflags "-X github.com/harvester/hvperf/cmd.Version=runner+${PERF_SHA}" \
        -o /tmp/hvperf .)
    sudo install -m 0755 /tmp/hvperf /usr/local/bin/hvperf
    rm -f /tmp/hvperf
    echo "    built"
fi

# --- etcd tools and promtool, for the NODES' architecture --------------------
dockerfile_arg() {
    sed -n "s/^ARG $1=//p" "$PERF_DIR/Dockerfile" | head -1
}
ETCD_VERSION="$(dockerfile_arg ETCD_VERSION)"
PROMETHEUS_VERSION="$(dockerfile_arg PROMETHEUS_VERSION)"
[ -n "$ETCD_VERSION" ] && [ -n "$PROMETHEUS_VERSION" ] || {
    echo "ERROR: could not read ETCD_VERSION / PROMETHEUS_VERSION from $PERF_DIR/Dockerfile" >&2
    exit 1
}
WANT_STAMP="etcd=${ETCD_VERSION} prometheus=${PROMETHEUS_VERSION} arch=${NODE_GOARCH}"

echo "==> cluster tools (${WANT_STAMP})"
if [ "$(cat "$TOOLS_STAMP" 2>/dev/null || true)" = "$WANT_STAMP" ]; then
    echo "    already installed"
else
    ETCD_SRC="$HOME/etcd-src-${ETCD_VERSION}"
    [ -d "$ETCD_SRC/.git" ] || git clone --quiet --depth 1 --branch "$ETCD_VERSION" \
        https://github.com/etcd-io/etcd.git "$ETCD_SRC"
    # Same two builds as the upstream Dockerfile's etcd-builder stage.
    go_fetch "$ETCD_SRC/tools/benchmark"
    go_fetch "$ETCD_SRC/etcdctl"
    GOOS=linux GOARCH="$NODE_GOARCH" CGO_ENABLED=0 go build -C "$ETCD_SRC/tools/benchmark" -trimpath -o /tmp/benchmark
    GOOS=linux GOARCH="$NODE_GOARCH" CGO_ENABLED=0 go build -C "$ETCD_SRC/etcdctl" -trimpath -o /tmp/etcdctl

    PROM="prometheus-${PROMETHEUS_VERSION}.linux-${NODE_GOARCH}"
    PROM_URL="https://github.com/prometheus/prometheus/releases/download/v${PROMETHEUS_VERSION}"
    curl -fsSL -o "/tmp/${PROM}.tar.gz" "${PROM_URL}/${PROM}.tar.gz"
    curl -fsSL "${PROM_URL}/sha256sums.txt" | grep " ${PROM}.tar.gz\$" \
        | sed "s# ${PROM}.tar.gz\$# /tmp/${PROM}.tar.gz#" | sha256sum -c --quiet
    tar -C /tmp -xzf "/tmp/${PROM}.tar.gz" "${PROM}/promtool"

    # hvperf reads these three paths literally; they are not configurable.
    sudo install -m 0755 /tmp/benchmark /tmp/etcdctl "/tmp/${PROM}/promtool" /usr/local/bin/
    rm -rf /tmp/benchmark /tmp/etcdctl "/tmp/${PROM}" "/tmp/${PROM}.tar.gz"
    echo "$WANT_STAMP" | sudo tee "$TOOLS_STAMP" >/dev/null
    echo "    installed"
fi

# Prove the architecture rather than trusting the stamp: a mismatch here is the
# failure this script exists to prevent, and it would otherwise surface only as
# "exec format error" inside a pod.
for b in etcdctl benchmark promtool; do
    got="$(go version -m "/usr/local/bin/$b" | sed -n 's/.*GOARCH=//p' | head -1)"
    [ "$got" = "$NODE_GOARCH" ] || {
        echo "ERROR: /usr/local/bin/$b is GOARCH=$got, cluster needs $NODE_GOARCH" >&2
        exit 1
    }
done

# --- kubectl, only for the guest suite --------------------------------------
# The cluster's own version rather than "stable": kubectl supports one minor
# of skew, and dl.k8s.io's stable is routinely two ahead of a Harvester
# release's RKE2.
if [ -n "$KUBECTL_VERSION" ]; then
    echo "==> kubectl ${KUBECTL_VERSION}"
    [[ "$KUBECTL_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
        echo "ERROR: KUBECTL_VERSION '$KUBECTL_VERSION' is not vX.Y.Z" >&2; exit 1; }
    if [ "$(kubectl version --client -o json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["clientVersion"]["gitVersion"])' 2>/dev/null || true)" = "$KUBECTL_VERSION" ]; then
        echo "    already installed"
    else
        KURL="https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${HOST_GOARCH}/kubectl"
        curl -fsSL -o /tmp/kubectl "$KURL"
        echo "$(curl -fsSL "${KURL}.sha256")  /tmp/kubectl" | sha256sum -c --quiet
        sudo install -m 0755 /tmp/kubectl /usr/local/bin/kubectl
        rm -f /tmp/kubectl
        echo "    installed"
    fi
fi

echo "==> installed"
echo "    $(hvperf version --client-only 2>&1 | tr '\n' ' ')"
echo "    etcdctl/benchmark ${ETCD_VERSION}, promtool ${PROMETHEUS_VERSION}, all GOARCH=${NODE_GOARCH}"

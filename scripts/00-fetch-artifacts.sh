#!/bin/bash
set -euo pipefail

# =============================================================================
# Phase 0: Download and verify the Harvester release artifacts
#
#   ./scripts/00-fetch-artifacts.sh            # v1.9.0, this host's arch
#   HARVESTER_VERSION=v1.8.2 ARCH=arm64 ./scripts/00-fetch-artifacts.sh
#
# Fetches the ISO, kernel and initrd that 01-build-instance.sh needs into
# ARTIFACTS_DIR, and checks each against the release's own
# harvester-<version>-<arch>.sha512 manifest, which lists all three.
#
# Two things this guards against:
#
#   - A truncated download. Each file is fetched to <name>.part and only
#     renamed once complete and verified, so an interrupted run never leaves a
#     partial file that a later run would mistake for a finished one.
#   - Corruption or tampering in transit or at rest. A file already present is
#     re-verified rather than trusted because it exists.
#
# The manifest comes from the same origin over HTTPS, so this does not defend
# against a compromised release server. Set SHA512_FILE to a manifest obtained
# out of band if that matters to you.
# =============================================================================

HARVESTER_VERSION="${HARVESTER_VERSION:-v1.9.0}"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-./artifacts}"
RELEASE_BASE="${RELEASE_BASE:-https://releases.rancher.com/harvester/${HARVESTER_VERSION}}"
SHA512_FILE="${SHA512_FILE:-}"

if [ -z "${ARCH:-}" ]; then
    case "$(uname -m)" in
        x86_64|amd64)  ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64" ;;
        *) echo "ERROR: unsupported host architecture $(uname -m); set ARCH" >&2; exit 1 ;;
    esac
fi
case "$ARCH" in
    amd64|arm64) : ;;
    *) echo "ERROR: ARCH must be amd64 or arm64 (got: ${ARCH})" >&2; exit 1 ;;
esac

if command -v sha512sum >/dev/null; then
    SHA512=(sha512sum)
elif command -v shasum >/dev/null; then
    SHA512=(shasum -a 512)
else
    echo "ERROR: neither sha512sum nor shasum found" >&2
    exit 1
fi
command -v curl >/dev/null || { echo "ERROR: curl not found" >&2; exit 1; }

PREFIX="harvester-${HARVESTER_VERSION}"
FILES=(
    "${PREFIX}-${ARCH}.iso"
    "${PREFIX}-vmlinuz-${ARCH}"
    "${PREFIX}-initrd-${ARCH}"
)
MANIFEST="${PREFIX}-${ARCH}.sha512"

mkdir -p "$ARTIFACTS_DIR"
cd "$ARTIFACTS_DIR"

if [ -n "$SHA512_FILE" ]; then
    cp "$SHA512_FILE" "$MANIFEST"
else
    curl -fsSL -o "${MANIFEST}.part" "${RELEASE_BASE}/${MANIFEST}"
    mv "${MANIFEST}.part" "$MANIFEST"
fi

# expected_hash <file> -- the manifest line for exactly that name. The manifest
# also lists the net-install ISO and the rootfs squashfs, which we do not need.
expected_hash() {
    awk -v f="$1" '{ name = $2; sub(/^\*/, "", name) } name == f { print $1; exit }' "$MANIFEST"
}

actual_hash() {
    "${SHA512[@]}" "$1" | awk '{print $1}'
}

for f in "${FILES[@]}"; do
    want="$(expected_hash "$f")"
    if [ -z "$want" ]; then
        echo "ERROR: $f is not listed in $MANIFEST" >&2
        exit 1
    fi

    if [ -f "$f" ] && [ "$(actual_hash "$f")" = "$want" ]; then
        echo "  $f: present, checksum OK"
        continue
    fi

    echo "  $f: downloading"
    rm -f "${f}.part"
    curl -fsSL -o "${f}.part" "${RELEASE_BASE}/${f}"
    got="$(actual_hash "${f}.part")"
    if [ "$got" != "$want" ]; then
        rm -f "${f}.part"
        echo "ERROR: checksum mismatch for $f" >&2
        echo "       expected $want" >&2
        echo "       got      $got" >&2
        exit 1
    fi
    mv "${f}.part" "$f"
    echo "  $f: checksum OK"
done

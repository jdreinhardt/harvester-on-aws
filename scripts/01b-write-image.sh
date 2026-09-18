#!/bin/bash
set -euo pipefail

# =============================================================================
# Phase 1.5: Write the Harvester raw image from S3 onto an EBS volume
#
# Run this as root on the helper instance.
#
#   sudo ./scripts/01b-write-image.sh \
#       --source s3://suse-virtualization-testing/harvester-v1.8.2-amd64.raw.zst \
#       --device /dev/nvme1n1
#
# Why this exists rather than the obvious one-liner:
#
#   aws s3 cp s3://bucket/key - | zstd -dc | sudo dd of=/dev/nvme1n1
#
# `aws s3 cp` writing to stdout does a single, non-resumable GET. Its retry
# logic cannot help, because the bytes it already emitted have gone downstream
# into zstd and dd -- there is nothing to rewind. A half-hour connection to S3
# only has to hiccup once:
#
#   169160474624 bytes (169 GB) copied, 1289 s, 131 MB/s
#   download failed: ... ConnectionResetError(104, 'Connection reset by peer')
#   /*stdin*\ : Read error (39) : premature end
#
# Instead this fetches the object in ranged chunks. Each chunk lands in a small
# scratch file and is only emitted downstream once it has been fetched
# successfully, so any individual chunk can be retried without corrupting the
# stream. Scratch usage is one chunk, not the whole object, so it works on a
# helper instance with a small root volume.
# =============================================================================

SOURCE=""
DEVICE=""
CHUNK_MIB="${CHUNK_MIB:-256}"
RETRIES="${RETRIES:-6}"
DD_BLOCK="${DD_BLOCK:-4M}"
SCRATCH_DIR="${SCRATCH_DIR:-/var/tmp}"
ASSUME_YES="false"
SPARSE="true"

usage() {
    cat <<USAGE
Usage: sudo $0 --source <s3-uri> --device <block-device> [options]

Required:
  --source    s3://bucket/key of the zstd-compressed raw image
  --device    Target block device, e.g. /dev/nvme1n1

Options:
  --chunk-mib N   Range request size in MiB (default ${CHUNK_MIB})
  --retries N     Attempts per chunk (default ${RETRIES})
  --scratch DIR   Where to stage each chunk (default ${SCRATCH_DIR})
  --no-sparse     Write every block, including the all-zero ones. Only needed
                  if the target is NOT a freshly created volume (see below).
  --yes           Do not prompt before overwriting the device
  -h, --help      Show this help

The image is mostly zeroes, so by default dd is given conv=sparse and seeks over
the zero blocks instead of writing them. That matters twice over on EBS: the
write finishes in a fraction of the time, and a snapshot of the volume only
stores blocks that were actually written -- writing 250 GiB of zeroes makes them
"written" and bloats every snapshot taken from it.

The catch is that skipped blocks keep whatever was there before. A freshly
created EBS volume reads as zeroes, so this is safe; re-using a volume that
already holds an image is not. Pass --no-sparse in that case, or just create a
new volume.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --source)    SOURCE="$2"; shift 2 ;;
        --device)    DEVICE="$2"; shift 2 ;;
        --chunk-mib) CHUNK_MIB="$2"; shift 2 ;;
        --retries)   RETRIES="$2"; shift 2 ;;
        --scratch)   SCRATCH_DIR="$2"; shift 2 ;;
        --no-sparse) SPARSE="false"; shift ;;
        --yes|-y)    ASSUME_YES="true"; shift ;;
        -h|--help)   usage; exit 0 ;;
        *)           echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
done

[ -n "$SOURCE" ] && [ -n "$DEVICE" ] || { usage >&2; exit 1; }

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: must run as root (it writes to a block device)" >&2
    exit 1
fi

for tool in aws zstd dd lsblk blkid; do
    command -v "$tool" >/dev/null || { echo "ERROR: $tool not found" >&2; exit 1; }
done

case "$SOURCE" in
    s3://*/*) : ;;
    *) echo "ERROR: --source must be an s3://bucket/key URI" >&2; exit 1 ;;
esac
BUCKET="${SOURCE#s3://}"
KEY="${BUCKET#*/}"
BUCKET="${BUCKET%%/*}"

if [ ! -b "$DEVICE" ]; then
    echo "ERROR: $DEVICE is not a block device" >&2
    exit 1
fi

# Never write over the helper instance's own root disk.
ROOT_SRC="$(findmnt -no SOURCE / 2>/dev/null || true)"
if [ -n "$ROOT_SRC" ]; then
    ROOT_DISK="/dev/$(lsblk -no pkname "$ROOT_SRC" 2>/dev/null || true)"
    if [ "$ROOT_DISK" = "$DEVICE" ]; then
        echo "ERROR: $DEVICE is this instance's root disk. Refusing." >&2
        exit 1
    fi
fi
if lsblk -no MOUNTPOINT "$DEVICE" 2>/dev/null | grep -q .; then
    echo "ERROR: $DEVICE has mounted partitions. Unmount them first." >&2
    lsblk "$DEVICE" >&2
    exit 1
fi

# Sparse writing skips zero blocks, which leaves whatever was there before. That
# is only safe on a volume that reads as zeroes, i.e. a freshly created one.
if [ "$SPARSE" = "true" ] && lsblk -no FSTYPE,PARTTYPENAME "$DEVICE" 2>/dev/null | grep -q '[^[:space:]]'; then
    echo "WARNING: $DEVICE already contains a partition table or filesystem." >&2
    echo "         Sparse writing leaves the old contents in any block the new" >&2
    echo "         image has as zero. Use a fresh volume, or pass --no-sparse." >&2
    echo "" >&2
fi

echo "=== Phase 1.5: Write Harvester image to $DEVICE ==="
echo ""

OBJECT_SIZE="$(aws s3api head-object --bucket "$BUCKET" --key "$KEY" \
    --query ContentLength --output text 2>/dev/null || true)"
if ! [[ "$OBJECT_SIZE" =~ ^[0-9]+$ ]]; then
    echo "ERROR: could not read $SOURCE (check the URI and the instance's IAM role)" >&2
    exit 1
fi

DEVICE_SIZE="$(lsblk --bytes --nodeps --noheadings --output SIZE "$DEVICE" | tr -d ' ')"

printf '  Source:      %s\n' "$SOURCE"
printf '  Compressed:  %s bytes (%.1f GiB)\n' "$OBJECT_SIZE" \
    "$(awk -v b="$OBJECT_SIZE" 'BEGIN{print b/1073741824}')"
printf '  Device:      %s (%s GiB)\n' "$DEVICE" "$((DEVICE_SIZE / 1073741824))"
printf '  Chunk size:  %s MiB, %s attempts each\n' "$CHUNK_MIB" "$RETRIES"
echo ""

if [ "$ASSUME_YES" != "true" ]; then
    echo "This will DESTROY everything on $DEVICE."
    read -r -p "Type the device name to continue: " CONFIRM
    [ "$CONFIRM" = "$DEVICE" ] || { echo "Aborted."; exit 1; }
    echo ""
fi

SCRATCH="$(mktemp -d "${SCRATCH_DIR%/}/harv-write.XXXXXX")"
cleanup() { rm -rf "$SCRATCH"; }
trap cleanup EXIT

# Need room for one chunk plus a little slack.
NEED_KIB=$(( CHUNK_MIB * 1024 * 2 ))
AVAIL_KIB="$(df -Pk "$SCRATCH" | awk 'NR==2{print $4}')"
if [ "$AVAIL_KIB" -lt "$NEED_KIB" ]; then
    echo "ERROR: only $((AVAIL_KIB/1024)) MiB free in $SCRATCH_DIR; need about $((NEED_KIB/1024)) MiB." >&2
    echo "       Use --scratch to point somewhere with more room, or lower --chunk-mib." >&2
    exit 1
fi

# --- The producer: ranged GETs, retried per chunk, emitted in order ----------
fetch_stream() {
    local chunk_bytes=$(( CHUNK_MIB * 1024 * 1024 ))
    local offset=0 end attempt ok pct
    local part="$SCRATCH/part"

    while [ "$offset" -lt "$OBJECT_SIZE" ]; do
        end=$(( offset + chunk_bytes - 1 ))
        [ "$end" -ge "$OBJECT_SIZE" ] && end=$(( OBJECT_SIZE - 1 ))

        ok=0
        for attempt in $(seq 1 "$RETRIES"); do
            if aws s3api get-object \
                    --bucket "$BUCKET" --key "$KEY" \
                    --range "bytes=${offset}-${end}" \
                    "$part" >/dev/null 2>"$SCRATCH/err"; then
                # Guard against a short read being treated as success.
                local got
                got="$(stat -c %s "$part" 2>/dev/null || echo 0)"
                if [ "$got" -eq $(( end - offset + 1 )) ]; then
                    ok=1
                    break
                fi
                echo "  chunk at ${offset}: short read (${got} bytes), retrying" >&2
            else
                echo "  chunk at ${offset}: attempt ${attempt}/${RETRIES} failed: $(tail -1 "$SCRATCH/err" 2>/dev/null)" >&2
            fi
            sleep $(( attempt * 2 ))
        done

        if [ "$ok" -ne 1 ]; then
            echo "ERROR: gave up on the chunk at offset ${offset} after ${RETRIES} attempts." >&2
            return 1
        fi

        cat "$part"
        offset=$(( end + 1 ))
        pct=$(( offset * 100 / OBJECT_SIZE ))
        printf '\r  fetched %s / %s bytes (%s%%)   ' "$offset" "$OBJECT_SIZE" "$pct" >&2
    done
    echo "" >&2
    return 0
}

if [ "$SPARSE" = "true" ]; then
    echo "Writing (sparse: zero blocks are seeked over, not written)."
else
    echo "Writing every block, including zeroes. This is slow and it makes any"
    echo "snapshot of this volume much larger."
fi
echo ""

DD_CONV="fsync"
[ "$SPARSE" = "true" ] && DD_CONV="sparse,fsync"

set -o pipefail
if ! fetch_stream | zstd -dc | dd of="$DEVICE" bs="$DD_BLOCK" \
        iflag=fullblock oflag=direct conv="$DD_CONV" status=progress; then
    echo "" >&2
    echo "ERROR: the write did not complete. $DEVICE now holds a partial image." >&2
    echo "       Re-run this script; it always writes from offset 0." >&2
    exit 1
fi

sync
echo ""
echo "Re-reading the partition table..."
partprobe "$DEVICE" 2>/dev/null || true
udevadm settle 2>/dev/null || true

# --- Verify -----------------------------------------------------------------
echo "Verifying..."
FAILED=0

if command -v sfdisk >/dev/null; then
    PART_COUNT="$(sfdisk --json "$DEVICE" 2>/dev/null | grep -c '"node"' || true)"
    if [ "${PART_COUNT:-0}" -ge 6 ]; then
        echo "  partition table: ${PART_COUNT} partitions"
    else
        echo "  ERROR: expected 6 partitions, found ${PART_COUNT:-0}" >&2
        FAILED=1
    fi
fi

for label in COS_GRUB COS_OEM COS_STATE COS_PERSISTENT; do
    if blkid -L "$label" >/dev/null 2>&1; then
        echo "  $label: $(blkid -L "$label")"
    else
        echo "  ERROR: no partition labelled $label" >&2
        FAILED=1
    fi
done

if [ "$FAILED" -ne 0 ]; then
    echo "" >&2
    echo "ERROR: the image on $DEVICE does not look complete. Re-run this script." >&2
    exit 1
fi

cat <<DONE

=============================================
Image written and verified
=============================================

Next: sudo ./scripts/02-customize-instance.sh $DEVICE
DONE

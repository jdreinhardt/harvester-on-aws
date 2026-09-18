#!/bin/bash
set -euo pipefail

# =============================================================================
# Follow an EC2 instance's console output.
#
#   ./follow-console.sh --instance-id i-xxxxxxxx [--tee console.txt]
#
# `aws ec2 get-console-output` is a snapshot API, not a stream: each call
# returns the most recent ~64 KB of the buffer. This polls it and prints only
# the lines that are new since the previous poll, so it reads like `tail -f`.
#
# For a genuinely live stream, use the serial console instead:
#
#   aws ec2-instance-connect send-serial-console-ssh-public-key \
#     --instance-id i-xxxxxxxx --serial-port 0 \
#     --ssh-public-key file://~/.ssh/id_ed25519.pub
#   ssh i-xxxxxxxx.port0@serial-console.ec2-instance-connect.<region>.aws | tee console.txt
#
# That is lower latency, but it is an interactive TTY: only one session per
# instance at a time, and because phase 2 puts the console on ttyS0 only, it is
# the same terminal the Harvester installer TUI and dashboard draw on. Anything
# you type goes to them. Polling, as this script does, is read-only.
# =============================================================================

INSTANCE_ID=""
INTERVAL=15
TEE_FILE=""
STRIP_ANSI="true"
UNTIL=""

usage() {
    cat <<USAGE
Usage: $0 --instance-id <id> [options]

Options:
  --interval N    Seconds between polls (default ${INTERVAL}, minimum 5).
                  The console buffer only refreshes every minute or so, and the
                  API is throttled, so there is nothing to gain below that.
  --tee FILE      Also append everything to FILE.
  --until REGEX   Exit 0 as soon as a line matches this extended regex.
  --raw           Keep ANSI escape sequences. Off by default, because the
                  Harvester installer and dashboard are full-screen TUIs on
                  this console and their redraws are unreadable interleaved
                  with log lines.
  -h, --help      Show this help.

Examples:
  $0 --instance-id i-0abc --tee console.txt
  $0 --instance-id i-0abc --until 'Harvester installation complete|rancherd.*Done'
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --instance-id) INSTANCE_ID="$2"; shift 2 ;;
        --interval)    INTERVAL="$2"; shift 2 ;;
        --tee)         TEE_FILE="$2"; shift 2 ;;
        --until)       UNTIL="$2"; shift 2 ;;
        --raw)         STRIP_ANSI="false"; shift ;;
        -h|--help)     usage; exit 0 ;;
        *)             echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
done

[ -n "$INSTANCE_ID" ] || { usage >&2; exit 1; }
command -v aws >/dev/null || { echo "ERROR: aws CLI not found" >&2; exit 1; }
[ "$INTERVAL" -ge 5 ] 2>/dev/null || INTERVAL=5

WORK="$(mktemp -d "${TMPDIR:-/tmp}/harv-console.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
: > "$WORK/prev"

emit() {
    if [ "$STRIP_ANSI" = "true" ]; then
        # CSI sequences, plus the lone carriage returns a TUI leaves behind.
        sed -e 's/'$'\033''\[[0-9;?]*[a-zA-Z]//g' -e 's/'$'\033''[()][A-Z0-9]//g' -e 's/\r//g'
    else
        cat
    fi
}

echo "Following console output for ${INSTANCE_ID} (poll every ${INTERVAL}s, Ctrl-C to stop)."
[ -n "$TEE_FILE" ] && echo "Appending to ${TEE_FILE}."
echo "Note: the buffer holds only the most recent ~64 KB, so if the instance has"
echo "      been up a while the earliest boot lines are already gone."
echo "---"

FIRST=1
while true; do
    STATE="$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
        --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null || echo unknown)"

    if aws ec2 get-console-output --instance-id "$INSTANCE_ID" --latest \
            --query Output --output text > "$WORK/cur" 2>"$WORK/err"; then

        if [ "$FIRST" = "1" ]; then
            # Show the whole buffer once, so you start with context.
            emit < "$WORK/cur" | { [ -n "$TEE_FILE" ] && tee -a "$TEE_FILE" || cat; }
            FIRST=0
        else
            # Only lines diff considers added. Lines ageing out of the front of
            # the ring buffer show up as deletions and are ignored.
            # diff exits 1 whenever the files differ, which under `set -o
            # pipefail` would otherwise end the loop on the first new line.
            { diff "$WORK/prev" "$WORK/cur" 2>/dev/null || true; } \
                | sed -n 's/^> //p' \
                | emit \
                | { [ -n "$TEE_FILE" ] && tee -a "$TEE_FILE" || cat; }
        fi

        if [ -n "$UNTIL" ] && grep -qE "$UNTIL" "$WORK/cur"; then
            echo "---"
            echo "Matched --until pattern. Stopping."
            exit 0
        fi

        mv "$WORK/cur" "$WORK/prev"
    else
        # A freshly launched instance has no console output for a minute or two.
        if grep -qi 'not available\|InvalidInstanceID' "$WORK/err" 2>/dev/null; then
            [ "$FIRST" = "1" ] && echo "  (waiting for console output to appear...)"
        else
            echo "  (get-console-output failed: $(tail -1 "$WORK/err" 2>/dev/null))" >&2
        fi
    fi

    case "$STATE" in
        terminated|stopped|shutting-down)
            echo "---"
            echo "Instance is ${STATE}. Stopping."
            exit 0
            ;;
    esac

    sleep "$INTERVAL"
done

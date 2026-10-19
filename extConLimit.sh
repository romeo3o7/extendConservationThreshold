#!/usr/bin/env bash
# Stop on unhandled errors, unset variables, and pipeline failures.
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }

LIMIT=75

BAT=/sys/class/power_supply/BAT1
AC=/sys/class/power_supply/ACAD
CONS=/sys/bus/platform/drivers/ideapad_acpi/VPC2004:00/conservation_mode

[[ -r "$AC/online" ]] || { echo "cannot read AC status: $AC/online" >&2; exit 1; }

# Open a lock file so only one instance can control charging at a time.
exec 9>/run/lock/bat-limit.lock
flock -n 9 || { echo "already running" >&2; exit 1; }

read_cons() { cat $CONS; }
cap() { cat "$BAT/capacity"; }
ac_online() { [[ -r "$AC/online" ]] && [[ $(<"$AC/online") == 1 ]]; }
set_cons() { printf '%s\n' "$1" > "$CONS"; }

# Mark whether cleanup should attempt to re-enable conservation mode.
restore_cons=0

UPID=

cleanup() {
    local status=$?
    trap - EXIT INT TERM HUP

    if (( restore_cons )); then
		if (( $(read_cons) == "0" )); then
       	    if set_cons 1; then
       	        echo "conservation mode restored" >&2
       	    else
       	        echo "error: could not restore conservation mode" >&2
       	        status=1
       	    fi
		fi
    fi

    # Stop the UPower monitor if it was started.
    if [[ -n ${UPID:-} ]]; then
        kill "$UPID" 2>/dev/null || true
    fi

    exit "$status"
 }

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

ac_online || { echo "not on AC, nothing to do"; exit 0; }

percentage=$(cap) || { echo "failed to read battery capacity" >&2; exit 1; }

if (( percentage >= LIMIT )); then
	if (( $(read_cons) == "0" )); then
		set_cons 1 || { echo "failed to enable conservation mode" >&2; exit 1; }
	fi
	echo "limit is already reached"
    exit 0
fi

# Start monitoring before changing the mode, and close the lock descriptor in the child.
exec 3< <(upower --monitor 9>&-)
UPID=$!

restore_cons=1
set_cons 0 || { echo "failed to disable conservation mode" >&2; exit 1; }
while :; do
    ac_online || { echo "unplugged"; exit 0; }

    percentage=$(cap) || { echo "failed to read battery capacity" >&2; exit 1; }

    if (( percentage >= LIMIT )); then
        if set_cons 1; then
            restore_cons=0
            echo "reached ${percentage}%; conservation mode enabled"
            exit 0
        else
            echo "failed to enable conservation mode at ${percentage}%" >&2
            exit 1
        fi
    fi

    # Wait for the next UPower notification; a closed monitor triggers cleanup.
    IFS= read -r _ <&3 || { echo "upower monitor ended; exiting" >&2; exit 1; }
done

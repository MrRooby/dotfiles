#!/usr/bin/env bash
#
# Power profile switcher for the battery drawer in waybar, backed by TLP.
#
#   power-profile.sh get <profile>   -> waybar json for one drawer button
#   power-profile.sh set <profile>   -> switch to it and refresh the buttons
#
# TLP 1.9+ ships tlp-pd, which owns org.freedesktop.UPower.PowerProfiles on
# the system bus and speaks the same performance/balanced/power-saver profile
# names power-profiles-daemon did. Going through the bus rather than the tlp
# CLI matters: `tlp <profile>` needs root, and waybar has no way to prompt for
# a password on click, whereas the bus property is polkit-gated and an active
# local session may set it outright.
#
# The three buttons share one signal, so switching one repaints the others.
# The cpu module picks the matching icon up on its own next poll.

set -uo pipefail

SIGNAL=7

PP_BUS=org.freedesktop.UPower.PowerProfiles
PP_PATH=/org/freedesktop/UPower/PowerProfiles

# TLP's own state file, used when tlp-pd is not running. First field is the
# profile code currently applied: 0=performance, 1=balanced, 2=power-saver.
PP_RUNFILE=/run/tlp/last_pwr

# icon + human label for a profile name
describe() {
	case "$1" in
		performance) icon=""; label="Performance" ;;
		balanced)    icon="󰊚"; label="Balanced" ;;
		power-saver) icon="󰌪"; label="Power saver" ;;
		*)           icon="󰾅"; label="unknown" ;;
	esac
}

# name of the profile TLP is currently applying, empty if it cannot be read
current() {
	local profile code
	profile=$(busctl get-property "$PP_BUS" "$PP_PATH" "$PP_BUS" ActiveProfile \
		2>/dev/null | awk -F'"' '{print $2}')
	if [ -n "$profile" ]; then
		printf '%s' "$profile"
		return
	fi

	read -r code _ < "$PP_RUNFILE" 2>/dev/null || return
	case "$code" in
		0) printf 'performance' ;;
		1) printf 'balanced' ;;
		2) printf 'power-saver' ;;
	esac
}

# apply a profile: over the bus first, falling back to the CLI for setups
# where tlp-pd is disabled but a passwordless sudo rule for tlp exists
apply() {
	busctl set-property "$PP_BUS" "$PP_PATH" "$PP_BUS" ActiveProfile s "$1" 2>/dev/null \
		|| sudo -n /usr/sbin/tlp "$1" >/dev/null 2>&1
}

usage() {
	echo "usage: ${0##*/} {get|set} {performance|balanced|power-saver}" >&2
	exit 1
}

action="${1:-}"

case "$action" in
	get)
		profile="${2:-}"
		[ -n "$profile" ] || usage
		describe "$profile"
		if [ "$(current)" = "$profile" ]; then
			printf '{"text":"%s","class":"active","tooltip":"%s (active)"}\n' "$icon" "$label"
		else
			printf '{"text":"%s","class":"inactive","tooltip":"Switch to: %s"}\n' "$icon" "$label"
		fi
		;;

	set)
		profile="${2:-}"
		[ -n "$profile" ] || usage
		describe "$profile"
		if apply "$profile"; then
			notify-send "Power profile" "$label" \
				-h string:x-canonical-private-synchronous:powerprofile
		else
			notify-send -u critical "Power profile" "Failed to set: $label" \
				-h string:x-canonical-private-synchronous:powerprofile
		fi

		# tlp-pd hands the actual switch to a detached tlp run and only publishes
		# the new profile once that run finishes, which measures around a second
		# here. Wait for it to catch up so the repaint below lands on the new
		# state, rather than leaving the buttons stale until the next 10s poll.
		# The ceiling is generous because the loop exits the moment it matches.
		for _ in $(seq 40); do
			[ "$(current)" = "$profile" ] && break
			sleep 0.1
		done
		pkill -RTMIN+$SIGNAL waybar
		;;

	*)
		usage
		;;
esac

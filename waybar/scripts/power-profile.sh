#!/usr/bin/env bash
#
# Power profile switcher for the battery drawer in waybar.
#
#   power-profile.sh get <profile>   -> waybar json for one drawer button
#   power-profile.sh set <profile>   -> switch to it and refresh the buttons
#
# The three buttons share one signal, so switching one repaints the others.
# The cpu module picks the matching icon up on its own next poll.

set -uo pipefail

SIGNAL=7

# icon + human label for a profile name
describe() {
	case "$1" in
		performance) icon=""; label="Performance" ;;
		balanced)    icon="󰊚"; label="Balanced" ;;
		power-saver) icon="󰌪"; label="Power saver" ;;
		*)           icon="󰾅"; label="unknown" ;;
	esac
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
		if [ "$(powerprofilesctl get 2>/dev/null)" = "$profile" ]; then
			printf '{"text":"%s","class":"active","tooltip":"%s (active)"}\n' "$icon" "$label"
		else
			printf '{"text":"%s","class":"inactive","tooltip":"Switch to: %s"}\n' "$icon" "$label"
		fi
		;;

	set)
		profile="${2:-}"
		[ -n "$profile" ] || usage
		describe "$profile"
		if powerprofilesctl set "$profile" 2>/dev/null; then
			notify-send "Power profile" "$label" \
				-h string:x-canonical-private-synchronous:powerprofile
		else
			notify-send -u critical "Power profile" "Failed to set: $label" \
				-h string:x-canonical-private-synchronous:powerprofile
		fi
		pkill -RTMIN+$SIGNAL waybar
		;;

	*)
		usage
		;;
esac

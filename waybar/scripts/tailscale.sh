#!/usr/bin/env bash
#
# Toggle Tailscale and report its state to Waybar
#
# Requirements:
# 	tailscale, with this user set as operator so that up/down needs no sudo:
# 		sudo tailscale set --operator=$USER

ICON_UP="󰦝"
ICON_DOWN="󰦞"

state() {
	tailscale status --json --peers=false 2>/dev/null |
		awk -F '"' '/"BackendState"/ {print $4; exit}'
}

main() {
	if [[ $1 == "toggle" ]]; then
		if [[ $(state) == "Running" ]]; then
			tailscale down
		else
			tailscale up
		fi
	fi

	case $(state) in
		"Running")
			local ip
			ip=$(tailscale ip -4 2>/dev/null)
			printf '{"text": "%s", "class": "active", "tooltip": "Tailscale: %s"}\n' \
				"$ICON_UP" "${ip:-connected}"
			;;
		"NeedsLogin")
			printf '{"text": "%s", "class": "inactive", "tooltip": "Tailscale: logged out"}\n' \
				"$ICON_DOWN"
			;;
		*)
			printf '{"text": "%s", "class": "inactive", "tooltip": "Tailscale: off"}\n' \
				"$ICON_DOWN"
			;;
	esac
}

main "$@"

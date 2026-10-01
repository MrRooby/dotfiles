#!/usr/bin/env bash
#
# Hotspot module for waybar: toggle a NetworkManager access-point profile on
# click, show what it is doing in the tooltip.
#
#   hotspot.sh          -> waybar json
#   hotspot.sh toggle   -> start or stop it, then refresh the module
#
# The profile must not be locked to an interface name: the old one was bound
# to wlp4s0, the T480's card, and failed silently on anything else. Leave
# connection.interface-name empty and NM picks whichever Wi-Fi card exists.
#
# A card that is both a client and an access point must hold both on one
# channel, and NM keeps one connection per device anyway, so starting the
# hotspot drops the Wi-Fi connection. The tooltip says so beforehand, and
# says which uplink the clients would get their internet from.
#
# Requirements: NetworkManager (nmcli), iw, iproute2

set -uo pipefail
export LC_ALL=C.utf8

NAME="RBMK-1000"   # the NetworkManager profile to toggle
SIGNAL=11          # "signal" in modules/custom/hotspot.jsonc

ICON_ON="󱂇"
ICON_OFF="󰠅"

# ---- toggle --------------------------------------------------------------

active_dev() {
	nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null |
		awk -F: -v n="$NAME" '$1 == n {print $2; exit}'
}

if [ "${1:-}" = "toggle" ]; then
	if [ -n "$(active_dev)" ]; then
		err=$(nmcli connection down "$NAME" 2>&1 >/dev/null)
	else
		err=$(nmcli connection up "$NAME" 2>&1 >/dev/null)
	fi
	# nmcli's own message says why -- no device, wrong password, rfkill
	[ -n "$err" ] && notify-send -u critical -i network-wireless-hotspot \
		"Hotspot: $NAME" "${err#Error: }" >/dev/null 2>&1
	pkill -RTMIN+$SIGNAL waybar
	exit 0
fi

# ---- helpers -------------------------------------------------------------

g_esc=""
escape() {
	local s=${1//&/&amp;}
	s=${s//</&lt;}
	s=${s//>/&gt;}
	s=${s//\\/\\\\}
	g_esc=${s//\"/\\\"}
}

# "1.2 GB", "340 kB" -- SI, one decimal below ten
g_size=""
fmt_size() {
	g_size=$(awk -v b="$1" 'BEGIN {
		split("B kB MB GB TB", u, " "); i = 1
		while (b >= 1000 && i < 5) { b /= 1000; i++ }
		printf (b < 10 && i > 1) ? "%.1f %s" : "%d %s", b, u[i]
	}')
}

# "3 h 12 min", "7 min", "40 s"
fmt_age() {
	local s=$1
	if   [ "$s" -ge 3600 ]; then printf '%d h %d min' $(( s / 3600 )) $(( s % 3600 / 60 ))
	elif [ "$s" -ge 60 ];   then printf '%d min' $(( s / 60 ))
	else                         printf '%d s' "$s"; fi
}

# ---- the profile ---------------------------------------------------------

declare -A P=()
while IFS= read -r line; do
	P[${line%%:*}]=${line#*:}
done < <(nmcli -t -f 802-11-wireless.ssid,802-11-wireless.band,802-11-wireless.channel,802-11-wireless-security.key-mgmt connection show "$NAME" 2>/dev/null)

if [ ${#P[@]} -eq 0 ]; then
	printf '{"text":"%s","class":"inactive","tooltip":"No NetworkManager profile named %s"}\n' "$ICON_OFF" "$NAME"
	exit 0
fi

ssid=${P[802-11-wireless.ssid]:-$NAME}
case "${P[802-11-wireless.band]:-}" in
	bg) band="2.4 GHz" ;;
	a)  band="5 GHz" ;;
	*)  band="auto" ;;
esac
chan=${P[802-11-wireless.channel]:-0}
[ "$chan" = "0" ] && chan=""
case "${P[802-11-wireless-security.key-mgmt]:-}" in
	wpa-psk) sec="WPA2" ;;
	sae)     sec="WPA3" ;;
	"")      sec="open" ;;
	*)       sec=${P[802-11-wireless-security.key-mgmt]} ;;
esac

dev=$(active_dev)

# where the clients' internet would come from: the default route, other than
# the hotspot's own card, loopback and tunnels
uplink=$(ip -j route show default 2>/dev/null | jq -r --arg d "${dev:-}" '
	[ .[] | select(.dev != "lo" and .dev != $d and (.dev | test("^(tailscale|tun|wg)") | not)) ]
	| sort_by(.metric // 0) | .[0].dev // empty')

# ---- rows ----------------------------------------------------------------

labels=(); values=()
row() { [ -n "$2" ] && { labels+=("$1"); values+=("$2"); }; }
rule_row() { labels+=("-"); values+=(""); }

row "Band"     "$band${chan:+ · ch $chan}"
row "Security" "$sec"

if [ -n "$dev" ]; then
	state="On"; class="active"; icon=$ICON_ON

	addr=$(ip -j -4 addr show dev "$dev" 2>/dev/null | jq -r '.[0].addr_info[0] | "\(.local)/\(.prefixlen)" // empty')
	row "Device"  "$dev"
	row "Address" "$addr"
	row "Uplink"  "${uplink:-none, no internet for clients}"

	# connected stations, straight from the driver; IPs from the neighbour
	# table, which only knows a client once it has sent something
	declare -A ipof=()
	while read -r ip _ _ _ mac _; do
		[ -n "$mac" ] && ipof[$mac]=$ip
	done < <(ip -4 neigh show dev "$dev" 2>/dev/null)

	n=0; rxsum=0; txsum=0; clients=()
	mac=""; sig=""; secs=""
	flush() {
		[ -n "$mac" ] || return
		n=$(( n + 1 ))
		clients+=("${ipof[$mac]:-client $n}|${sig:+$sig dBm · }$(fmt_age "${secs:-0}")")
	}
	while read -r a b c _; do
		case "$a $b" in
			Station\ *)     flush; mac=$b; sig=""; secs="" ;;
			"rx bytes:")    rxsum=$(( rxsum + c )) ;;
			"tx bytes:")    txsum=$(( txsum + c )) ;;
			"signal: "*|signal:\ *) sig=$b ;;
			"connected time:") secs=$c ;;
		esac
		[ "$a" = "signal:" ] && sig=$b
	done < <(iw dev "$dev" station dump 2>/dev/null)
	flush

	rule_row
	row "Clients" "$n"
	for c in "${clients[@]}"; do
		row "  ${c%%|*}" "${c#*|}"
	done
	if [ "$n" -gt 0 ]; then
		rule_row
		# from the laptop's side: what went out to the clients, what came in
		fmt_size "$txsum"; row "Sent"     "$g_size"
		fmt_size "$rxsum"; row "Received" "$g_size"
	fi
else
	state="Off"; class="inactive"; icon=$ICON_OFF

	# what starting it would do
	wifi_now=$(nmcli -t -f TYPE,STATE,CONNECTION device 2>/dev/null |
		awk -F: -v n="$NAME" '$1 == "wifi" && $2 == "connected" && $3 != n {print $3; exit}')
	rule_row
	row "Uplink"   "${uplink:-none, no internet for clients}"
	row "On start" "${wifi_now:+drops Wi-Fi $wifi_now}"
fi

# ---- theme colours -------------------------------------------------------

declare -A THEME=()
theme_css="${XDG_CONFIG_HOME:-$HOME/.config}/waybar/current-theme.css"
if [ -r "$theme_css" ]; then
	while read -r kw name val; do
		[ "$kw" = "@define-color" ] || continue
		THEME[$name]=${val%;}
	done < "$theme_css"
fi

g_hex=""
resolve() {
	local v=${THEME[$1]:-} k=0
	while [ -n "$v" ] && [ "${v:0:1}" = "@" ] && [ "$k" -lt 10 ]; do
		v=${THEME[${v#@}]:-}
		k=$(( k + 1 ))
	done
	if [[ $v =~ ^#[0-9a-fA-F]{3,8}$ ]]; then g_hex=$v; else g_hex=""; fi
}

resolve tooltip-dim; C_DIM=$g_hex
resolve tooltip-fg;  C_FG=$g_hex
resolve tooltip-br;  C_ACCENT=$g_hex

paint() {
	if [ -n "$1" ]; then
		printf "<span foreground='%s'>%s</span>" "$1" "$2"
	else
		printf '%s' "$2"
	fi
}

# ---- tooltip -------------------------------------------------------------

# same layout as network-status.sh: widths on plain text, padded by hand
# (printf's width counts bytes, and "·" is two)
lw=0; vw=0
for i in "${!labels[@]}"; do
	[ "${labels[i]}" = "-" ] && continue
	[ ${#labels[i]} -gt "$lw" ] && lw=${#labels[i]}
	[ ${#values[i]} -gt "$vw" ] && vw=${#values[i]}
done

head_plain="$ssid  ·  $state"
inner=$(( lw + 2 + vw ))
if [ ${#head_plain} -gt "$inner" ]; then
	inner=${#head_plain}
	vw=$(( inner - lw - 2 ))
fi

pad=$(( (inner - ${#head_plain}) / 2 ))
escape "$ssid"
state_c=$([ "$class" = "active" ] && echo "$C_ACCENT" || echo "$C_DIM")
tooltip="$(printf '%*s' "$pad" '')<b>$g_esc</b>$(paint "$C_DIM" '  ·  ')$(paint "$state_c" "<b>$state</b>")"

rule=""
for (( i = 0; i < inner; i++ )); do rule+="─"; done
rule="\n$(paint "$C_DIM" "$rule")"

tooltip+="$rule"
prev_rule=1
for i in "${!labels[@]}"; do
	if [ "${labels[i]}" = "-" ]; then
		[ "$prev_rule" -eq 0 ] && [ $(( i + 1 )) -lt ${#labels[@]} ] && tooltip+="$rule"
		prev_rule=1
		continue
	fi
	l=${labels[i]}; v=${values[i]}
	l+=$(printf '%*s' $(( lw - ${#l} )) '')
	v=$(printf '%*s' $(( vw - ${#v} )) '')$v
	escape "$l"; l=$g_esc
	escape "$v"; v=$g_esc
	tooltip+="\n$(paint "$C_DIM" "$l")  $(paint "$C_FG" "<b>$v</b>")"
	prev_rule=0
done

printf '{"text":"%s","class":"%s","tooltip":"%s"}\n' "$icon" "$class" "$tooltip"

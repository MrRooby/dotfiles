#!/usr/bin/env bash
#
# Corne battery for waybar: the lower of the two halves in the bar, both halves
# in the tooltip.
#
# ZMK publishes one Battery Service per half. BlueZ's Battery1 interface picks
# up the first -- the left half, which is the central -- and UPower only mirrors
# that, so the right half never shows up in either. Its level is relayed by the
# central as a second Battery Level characteristic (user description
# "Peripheral 0"), and has to be read off that characteristic directly.
#
# The characteristic path is BlueZ's numbering of the ATT handles, so it holds
# for as long as the firmware keeps the same GATT layout. A ZMK update that adds
# or drops a service can move it; `busctl tree org.bluez` shows where it went.

set -uo pipefail

# Pinned so ${#str} counts characters rather than bytes: the rule and the
# meters are multi-byte and the columns are padded by length.
export LC_ALL=C.utf8

DEV=/org/bluez/hci0/dev_FC_6D_F5_51_64_3B
RIGHT_CHAR=$DEV/service0015/char0016

WARN=20   # %
CRIT=10   # %

ICON=""

# ---- read ----------------------------------------------------------------

# "y 57". Straight from BlueZ rather than UPower: it is the same number, and
# the right half has to come from BlueZ anyway.
left=""
read -r _ left < <(busctl --timeout=2 get-property org.bluez "$DEV" \
	org.bluez.Battery1 Percentage 2>/dev/null)
[[ $left =~ ^[0-9]+$ ]] || left=""

# "ay 1 93". This one is a live read over the air rather than a cached
# property, so it gets a short timeout: a half drifting out of range would
# otherwise hold the call, and the module, for the full ATT timeout.
right=""
read -r _ _ right _ < <(busctl --timeout=2 call org.bluez "$RIGHT_CHAR" \
	org.bluez.GattCharacteristic1 ReadValue 'a{sv}' 0 2>/dev/null)
[[ $right =~ ^[0-9]+$ ]] || right=""

if [ -z "$left" ] && [ -z "$right" ]; then
	echo ""   # hide the module while the keyboard is disconnected
	exit 0
fi

# the bar shows whichever half runs out first
low=${left:-$right}
[ -n "$right" ] && [ "$right" -lt "$low" ] && low=$right

# ---- theme colours -------------------------------------------------------

# Same lookup as battery.sh: pango only takes literal hex, so the palette is
# read from current-theme.css and @references are followed until a hex falls
# out. Anything unresolved paints nothing and inherits styles/tooltips.css.

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
	local v=${THEME[$1]:-} n=0
	while [ -n "$v" ] && [ "${v:0:1}" = "@" ] && [ "$n" -lt 10 ]; do
		v=${THEME[${v#@}]:-}
		n=$(( n + 1 ))
	done
	if [[ $v =~ ^#[0-9a-fA-F]{3,8}$ ]]; then g_hex=$v; else g_hex=""; fi
}

resolve tooltip-dim; C_DIM=$g_hex
resolve tooltip-fg;  C_FG=$g_hex
resolve tooltip-br;  C_ACCENT=$g_hex
resolve warning;     C_WARNING=$g_hex
resolve critical;    C_CRITICAL=$g_hex

paint() {
	if [ -n "$1" ]; then
		printf "<span foreground='%s'>%s</span>" "$1" "$2"
	else
		printf '%s' "$2"
	fi
}

# ---- tooltip -------------------------------------------------------------

BAR_W=10
LW=5   # "Right"

# label, percentage, and a gauge in battery.sh's colours: the accent while the
# half is fine, warning and critical at the same thresholds as the laptop
# battery
row() {   # row <label> <percent or empty>
	local l v f i fill="" rest="" accent
	printf -v l '%-*s' "$LW" "$1"
	g_out+="\n$(paint "$C_DIM" "$l")  "

	if [ -z "$2" ]; then
		g_out+="$(paint "$C_DIM" "not connected")"
		return
	fi

	if   [ "$2" -le "$CRIT" ]; then accent=$C_CRITICAL
	elif [ "$2" -le "$WARN" ]; then accent=$C_WARNING
	else                            accent=$C_ACCENT
	fi

	f=$(( ($2 * BAR_W + 50) / 100 ))
	[ "$f" -gt "$BAR_W" ] && f=$BAR_W
	for (( i = 0; i < BAR_W; i++ )); do
		if [ "$i" -lt "$f" ]; then fill+="█"; else rest+="░"; fi
	done

	printf -v v '%4s' "$2%"
	g_out+="$(paint "$C_FG" "<b>$v</b>")  $(paint "$accent" "$fill")$(paint "$C_DIM" "$rest")"
}

width=$(( LW + 2 + 4 + 2 + BAR_W ))

title="Corne"
pad=$(( (width - ${#title}) / 2 ))
g_out="$(printf '%*s' "$pad" '')$(paint "$C_ACCENT" "<b>$title</b>")"

rule=""
for (( i = 0; i < width; i++ )); do rule+="─"; done
g_out+="\n$(paint "$C_DIM" "$rule")"

row "Left"  "$left"
row "Right" "$right"

printf '{"text":"%s %s%%","tooltip":"%s","class":"keyboard","percentage":%s}\n' \
	"$ICON" "$low" "$g_out" "$low"

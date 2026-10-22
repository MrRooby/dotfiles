#!/usr/bin/env bash
#
# Fan module for waybar: ThinkPad fan speed in the bar, and in the tooltip
# what is driving it -- the level, the temperature the controller watches,
# where the next step up and down are, and the whole curve.
#
# Requirements:
# 	thinkpad_acpi (loaded automatically on ThinkPads)
# Optional:
# 	thinkfan -- its curve is read from /etc/thinkfan.conf (world-readable).
# 	Without it the fan is under firmware control and the tooltip says so.

set -uo pipefail
export LC_ALL=C.utf8

CONF=/etc/thinkfan.conf
PROC=/proc/acpi/ibm/fan

slurp() {
	local v
	[ -r "$1" ] || return 1
	read -r v < "$1" 2>/dev/null || return 1
	[ -n "$v" ] || return 1
	printf '%s' "$v"
}

# ---- speed and level -----------------------------------------------------

# thinkpad_acpi exposes the fan through hwmon, but the hwmon index is not
# stable across boots, so look the device up by name instead
rpm=""; rpm2=""
for path in /sys/class/hwmon/*; do
	[ "$(slurp "$path/name" 2>/dev/null)" = "thinkpad" ] || continue
	rpm=$(slurp "$path/fan1_input")  || rpm=""
	rpm2=$(slurp "$path/fan2_input") || rpm2=""
	break
done

# the procfs interface carries the level, and the speed as a fallback
level=""
if [ -r "$PROC" ]; then
	while read -r key val _; do
		case "$key" in
			speed:) [ -z "$rpm" ] && rpm=$val ;;
			level:) level=$val ;;
		esac
	done < "$PROC"
fi
rpm=${rpm:-0}

# ---- thinkfan's curve ----------------------------------------------------

# "levels:" entries are [level, lower, upper] in the YAML syntax and
# (level, lower, upper) in the old one; the level is a number or a string
# such as "level full-speed". Comments are stripped first.
c_lvl=(); c_lo=(); c_hi=()
sensor_name=""; sensor_idx=1
if [ -r "$CONF" ]; then
	while IFS= read -r line; do
		line=${line%%#*}
		if [[ $line =~ name:[[:space:]]*([A-Za-z0-9_]+) ]] && [ -z "$sensor_name" ]; then
			sensor_name=${BASH_REMATCH[1]}
		elif [[ $line =~ indices:[[:space:]]*\[[[:space:]]*([0-9]+) ]]; then
			sensor_idx=${BASH_REMATCH[1]}
		elif [[ $line =~ [\[\(][[:space:]]*\"?([^,\"]+)\"?[[:space:]]*,[[:space:]]*([0-9]+)[[:space:]]*,[[:space:]]*([0-9]+)[[:space:]]*[\]\)] ]]; then
			l=${BASH_REMATCH[1]}; l=${l#level }; l=${l%% }
			c_lvl+=("$l"); c_lo+=("${BASH_REMATCH[2]}"); c_hi+=("${BASH_REMATCH[3]}")
		fi
	done < "$CONF"
fi

# ---- the temperature the controller watches ------------------------------

# the sensor thinkfan.conf names; failing that the CPU sensor of whichever
# vendor, then the EC's own reading
temp=""
for want in "$sensor_name" k10temp coretemp thinkpad; do
	[ -n "$want" ] || continue
	for path in /sys/class/hwmon/*; do
		[ "$(slurp "$path/name" 2>/dev/null)" = "$want" ] || continue
		idx=$([ "$want" = "$sensor_name" ] && echo "$sensor_idx" || echo 1)
		t=$(slurp "$path/temp${idx}_input") && temp=$(( t / 1000 ))
		break
	done
	[ -n "$temp" ] && break
done

# ---- who is in control ---------------------------------------------------

if pgrep -x thinkfan >/dev/null 2>&1; then
	control="thinkfan"
elif [ "$level" = "auto" ]; then
	control="firmware"
else
	control="manual"
fi

case "$level" in
	"")           level_txt="" ;;
	auto)         level_txt="Auto" ;;
	full-speed)   level_txt="Full speed" ;;
	disengaged)   level_txt="Disengaged" ;;
	*)            level_txt="Level $level" ;;
esac

# position on the curve: the entry whose level matches the current one
cur=-1
for i in "${!c_lvl[@]}"; do
	[ "${c_lvl[i]}" = "$level" ] && { cur=$i; break; }
done

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

# ---- rows ----------------------------------------------------------------

# a label of "-" is a rule; hot=1 paints the row in the accent (the curve's
# active step)
labels=(); values=(); hot=()
row()      { [ -n "$2" ] && { labels+=("$1"); values+=("$2"); hot+=("${3:-0}"); }; }
rule_row() { labels+=("-"); values+=(""); hot+=(0); }

row "CPU" "${temp:+$temp °C}"
if [ "$cur" -ge 0 ]; then
	# the upper bound of a step is where the fan speeds up, the lower bound
	# where it slows down again; 255 is thinkfan's "no upper limit"
	[ "${c_hi[cur]}" -lt 255 ] && row "Speeds up at"   "${c_hi[cur]} °C"
	[ "${c_lo[cur]}" -gt 0 ]   && row "Slows down at"  "${c_lo[cur]} °C"
fi
[ -n "$rpm2" ] && [ "$rpm2" -gt 0 ] 2>/dev/null && row "Second fan" "$rpm2 RPM"
row "Control" "$control"
row "Profile" "$(slurp /sys/firmware/acpi/platform_profile 2>/dev/null)"

if [ ${#c_lvl[@]} -gt 0 ] && [ "$control" = "thinkfan" ]; then
	rule_row
	for i in "${!c_lvl[@]}"; do
		case "${c_lvl[i]}" in
			full-speed) name="Full speed" ;;
			disengaged) name="Disengaged" ;;
			*)          name="Level ${c_lvl[i]}" ;;
		esac
		if   [ "${c_hi[i]}" -ge 255 ]; then range="${c_lo[i]} °C +"
		elif [ "${c_lo[i]}" -le 0 ];   then range="up to ${c_hi[i]} °C"
		else                                range="${c_lo[i]} – ${c_hi[i]} °C"; fi
		row "$name" "$range" "$([ "$i" -eq "$cur" ] && echo 1 || echo 0)"
	done
fi

# ---- tooltip -------------------------------------------------------------

# same layout as network-status.sh: widths on plain text, padded by hand
# (printf's width counts bytes, and "°" and "–" are multi-byte)
lw=0; vw=0
for i in "${!labels[@]}"; do
	[ "${labels[i]}" = "-" ] && continue
	[ ${#labels[i]} -gt "$lw" ] && lw=${#labels[i]}
	[ ${#values[i]} -gt "$vw" ] && vw=${#values[i]}
done

head_l="$rpm RPM"
head_plain="$head_l${level_txt:+  ·  $level_txt}"
inner=$(( lw + 2 + vw ))
if [ ${#head_plain} -gt "$inner" ]; then
	inner=${#head_plain}
	vw=$(( inner - lw - 2 ))
fi

pad=$(( (inner - ${#head_plain}) / 2 ))
tooltip="$(printf '%*s' "$pad" '')<b>$head_l</b>"
[ -n "$level_txt" ] && tooltip+="$(paint "$C_DIM" '  ·  ')$(paint "$C_ACCENT" "<b>$level_txt</b>")"

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
	if [ "${hot[i]}" -eq 1 ]; then
		tooltip+="\n$(paint "$C_ACCENT" "<b>$l  $v</b>")"
	else
		tooltip+="\n$(paint "$C_DIM" "$l")  $(paint "$C_FG" "<b>$v</b>")"
	fi
	prev_rule=0
done

printf '{"text":"%s","tooltip":"%s"}\n' "$rpm" "$tooltip"

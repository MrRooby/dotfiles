#!/usr/bin/env bash
#
# Battery module for waybar: level in the bar, power detail in the tooltip.
#
# waybar's built-in battery module gives {power}, {health} and {cycles}, but it
# cannot express a charge rate in %/hour, cannot see the USB-PD contract the
# charger negotiated, and cannot report the charge-stop threshold — hence this
# replacement. The icon ramp, the state classes and the low/critical/full
# notifications came across with it, so this script is the only battery
# indicator on the bar; nothing here may exit early except on a missing battery.
#
# Everything is read from sysfs. upower reports the same numbers, but it is a
# process spawn plus a bus round trip on every poll.

set -uo pipefail

# Pinned so ${#str} counts characters rather than bytes (the header contains a
# multi-byte "·" and is centred by length), and so awk always prints a decimal
# point regardless of the user's locale.
export LC_ALL=C.utf8

WARN=20   # %
CRIT=10   # %

# Percentage points a level has to climb back before its notification re-arms.
# Without it a battery wobbling across 20% re-notifies on every poll.
HYSTERESIS=3

state="${XDG_RUNTIME_DIR:-/tmp}/waybar-battery.state"
alert_state="$state.alerts"

# ---- helpers -------------------------------------------------------------

# read one sysfs file, failing on absent, unreadable and empty alike
slurp() {
	local v
	[ -r "$1" ] || return 1
	read -r v < "$1" 2>/dev/null || return 1
	[ -n "$v" ] || return 1
	printf '%s' "$v"
}

# same, but only for non-negative integers
slurp_int() {
	local v
	v=$(slurp "$1") || return 1
	[[ $v =~ ^-?[0-9]+$ ]] || return 1
	printf '%s' "$v"
}

# escape for pango markup, then for the JSON string — applied to the two
# strings that come from the kernel rather than from this script
g_esc=""
escape() {
	local s=${1//&/&amp;}
	s=${s//</&lt;}
	s=${s//>/&gt;}
	s=${s//\\/\\\\}
	g_esc=${s//\"/\\\"}
}

# write a state file atomically: a reader catching it mid-write would restart
# the EMA from zero, or re-fire a notification that was already latched
save() {
	local f=$1 tmp="$1.$$"
	shift
	if printf '%s\n' "$@" > "$tmp" 2>/dev/null; then
		mv -f "$tmp" "$f" 2>/dev/null || rm -f "$tmp" 2>/dev/null
	else
		rm -f "$tmp" 2>/dev/null
	fi
}

# ---- find the battery ----------------------------------------------------

# scope=Device marks a peripheral's battery (a mouse, a keyboard). The Corne is
# handled by corne.sh and reaches the bar through its own module, so anything
# that is not the system battery is skipped here.
bat=""
for d in /sys/class/power_supply/*; do
	[ "$(slurp "$d/type" 2>/dev/null)" = "Battery" ] || continue
	[ "$(slurp "$d/scope" 2>/dev/null)" = "Device" ] && continue
	bat="$d"
	[[ ${d##*/} == BAT* ]] && break
done

if [ -z "$bat" ]; then
	printf '{"text":"󰂑 --","class":"","tooltip":"no battery found"}\n'
	exit 0
fi

status=$(slurp "$bat/status") || status="Unknown"
capacity=$(slurp_int "$bat/capacity") || capacity=0
[ "$capacity" -lt 0 ] && capacity=0
[ "$capacity" -gt 100 ] && capacity=100

# ---- energy, charge and power --------------------------------------------

# Two sysfs layouts exist. Energy-based batteries publish µWh and µW directly;
# charge-based ones publish µAh and µA, which become watt-hours and watts only
# once multiplied by the present voltage. This machine is energy-based, but the
# config is a fork of a public repo and plenty of hardware is not.
#
# Figures are carried in milliwatt-hours and milliwatts so the rest of the
# script stays in integer arithmetic — awk is reserved for the two places where
# a fraction actually has to be printed.

mwh_now=""; mwh_full=""; mwh_design=""; mw=""

if e=$(slurp_int "$bat/energy_now"); then
	mwh_now=$(( e / 1000 ))
	f=$(slurp_int "$bat/energy_full")        && mwh_full=$(( f / 1000 ))
	f=$(slurp_int "$bat/energy_full_design") && mwh_design=$(( f / 1000 ))
	p=$(slurp_int "$bat/power_now")          && mw=$(( p < 0 ? -p / 1000 : p / 1000 ))
elif c=$(slurp_int "$bat/charge_now"); then
	uv=$(slurp_int "$bat/voltage_now") || uv=0
	if [ "$uv" -gt 0 ]; then
		# µAh × µV / 1e12 = Wh, so × 1000 for mWh: µAh × µV / 1e9
		mwh_now=$(( c / 1000 * uv / 1000000 ))
		f=$(slurp_int "$bat/charge_full")        && mwh_full=$(( f / 1000 * uv / 1000000 ))
		f=$(slurp_int "$bat/charge_full_design") && mwh_design=$(( f / 1000 * uv / 1000000 ))
		if i=$(slurp_int "$bat/current_now"); then
			[ "$i" -lt 0 ] && i=$(( -i ))
			mw=$(( i / 1000 * uv / 1000000 ))
		fi
	fi
fi

# ---- smooth the power reading --------------------------------------------

# An exponential moving average, alpha = 1/3, so roughly a four-poll time
# constant. power_now while charging is already filtered by the EC here (it
# moves in ~12 mW steps and never reverses), but under discharge it tracks the
# actual load, and a browser opening a tab would otherwise swing the time
# estimate by tens of minutes between two polls.
#
# One smoothed figure feeds the wattage, the %/hour and the time estimate alike,
# so the three always agree arithmetically. The average is dropped whenever the
# status changes: a charging figure must not bleed into the first discharging
# poll, where it would be both wrong and pointing the wrong way.

if [ -n "$mw" ]; then
	old_status=""; old_mw=""
	if [ -r "$state" ]; then
		read -r old_status old_mw < "$state" 2>/dev/null || true
	fi

	if [ "$old_status" = "$status" ] && [[ ${old_mw:-} =~ ^[0-9]+$ ]]; then
		mw=$(( (old_mw * 2 + mw + 1) / 3 ))
	fi

	save "$state" "$status $mw"
fi

# ---- charger ----------------------------------------------------------

# What a PD charger is rated at is the largest of the fixed-supply PDOs it
# advertises, and that list only exists under the attached partner's
# usb_power_delivery object.
#
# The obvious-looking shortcut, voltage_max x current_max on the ucsi source
# power supply, is a trap: ucsi_psy takes voltage_max from the LAST source PDO
# and current_max from the FIRST one, so whenever the top rail is
# current-limited the two belong to different PDOs and the product is a rating
# the charger never offered. A 45 W bank advertising 5/9/12/15 V at 3 A and
# 20 V at 2.25 A reads as 20 V x 3 A = 60 W that way.
#
# Programmable (PPS) PDOs are skipped on purpose. Their voltage x current
# ceiling can exceed the supply's actual rating -- the same 45 W bank
# advertises PPS 5-11 V at 5 A -- and chargers are rated by their fixed rails.

charger=""
mode=""
attached=0

for d in /sys/class/power_supply/*; do
	[ "$(slurp "$d/type" 2>/dev/null)" = "USB" ] || continue
	[ "$(slurp "$d/online" 2>/dev/null)" = "1" ] || continue
	attached=1

	# usb_type reads "C [PD] PD_PPS": the bracketed token is the mode in force
	if t=$(slurp "$d/usb_type"); then
		m=${t#*[}
		m=${m%%]*}
		[ "$m" != "$t" ] && mode=$m
	fi
	break
done

# the partner object appears only while something is plugged in; pd0/pd1 here
# are the laptop's own ports and describe what it can source, not what it gets
if [ "$attached" -eq 1 ]; then
	watts=0
	for pd in /sys/class/usb_power_delivery/pd*; do
		dev=$(readlink -f "$pd/device" 2>/dev/null) || continue
		[[ ${dev##*/} == *-partner ]] || continue

		for cap in "$pd"/source-capabilities/*:fixed_supply; do
			[ -d "$cap" ] || continue
			mv=$(slurp "$cap/voltage")         || continue
			ma=$(slurp "$cap/maximum_current") || continue
			mv=${mv%mV}
			ma=${ma%mA}
			[[ $mv =~ ^[0-9]+$ ]] && [[ $ma =~ ^[0-9]+$ ]] || continue

			w=$(( (mv * ma + 500000) / 1000000 ))
			[ "$w" -gt "$watts" ] && watts=$w
		done
		break
	done

	case "$mode" in
		C) mode="USB-C" ;;
	esac

	if [ "$watts" -gt 0 ]; then
		charger="${watts}W${mode:+ $mode}"
	else
		# attached, but the PDO list is not exposed -- say so rather than
		# inventing a wattage from the ucsi properties
		charger="${mode:-USB}"
	fi
fi

if [ -z "$charger" ]; then
	for d in /sys/class/power_supply/*; do
		[ "$(slurp "$d/type" 2>/dev/null)" = "Mains" ] || continue
		[ "$(slurp "$d/online" 2>/dev/null)" = "1" ] || continue
		charger="AC"
		break
	done
fi

# ---- assemble the rows ---------------------------------------------------

# "0h 16min", matching the format-time the built-in module was configured with
fmt_time() {
	printf '%dh %dmin' $(( $1 / 60 )) $(( $1 % 60 ))
}

labels=(); values=()
row() { labels+=("$1"); values+=("$2"); }

# The charge-stop threshold is the real ceiling when it is set: the battery
# stops there and reports "Not charging", so a "full in" computed against
# energy_full would count towards a level it will never reach.
limit=$(slurp_int "$bat/charge_control_end_threshold") || limit=100
if [ "$limit" -le 0 ] || [ "$limit" -gt 100 ]; then
	limit=100
fi

# Power and the rate it implies are shown whenever current is moving, including
# under "Unknown" — a status this hardware reports transiently on the dock, and
# where the wattage is still the thing worth reading. Only the time estimate is
# withheld there, because which way the energy is going is exactly what the
# status failed to say.
if [ -n "$mw" ] && [ "$mw" -gt 0 ] && [ "$status" != "Full" ]; then
	row "Power" "$(awk -v m="$mw" 'BEGIN{printf "%.1fW", m/1000}')"

	if [ -n "$mwh_full" ] && [ "$mwh_full" -gt 0 ]; then
		row "Rate" "$(awk -v m="$mw" -v f="$mwh_full" 'BEGIN{printf "%.1f%%/h", 100*m/f}')"

		case "$status" in
			Charging)
				target=$(( mwh_full * limit / 100 ))
				[ "$mwh_now" -lt "$target" ] &&
					row "Full in" "$(fmt_time $(( (target - mwh_now) * 60 / mw )))"
				;;
			Discharging)
				row "Empty in" "$(fmt_time $(( mwh_now * 60 / mw )))"
				;;
		esac
	fi
fi

[ -n "$charger" ] && row "Charger" "$charger"
[ "$limit" -lt 100 ] && row "Limit" "$limit%"

if [ -n "$mwh_full" ] && [ -n "$mwh_design" ] && [ "$mwh_design" -gt 0 ]; then
	row "Health" "$(( (100 * mwh_full + mwh_design / 2) / mwh_design ))%"
fi

cycles=$(slurp_int "$bat/cycle_count") && [ "$cycles" -gt 0 ] && row "Cycles" "$cycles"

# ---- bar -----------------------------------------------------------------

# The same ten-icon ramp the built-in module was configured with, indexed the
# way waybar indexes format-icons, plus its charging icon.
ICONS=("󰂎" "󰁻" "󰁼" "󰁽" "󰁾" "󰁿" "󰂀" "󰂁" "󰂂" "󰁹")

if [ "$status" = "Charging" ]; then
	icon="󰉁"
else
	n=$(( capacity / 10 ))
	[ "$n" -gt 9 ] && n=9
	icon="${ICONS[n]}"
fi

# states.css keys off these. The built-in applied the status and capacity
# classes together and #battery.charging sat last in the stylesheet, so charging
# already won over critical there; the priority here reproduces that.
if   [ "$status" = "Charging" ];  then class="charging"
elif [ "$capacity" -le "$CRIT" ]; then class="critical"
elif [ "$capacity" -le "$WARN" ]; then class="warning"
else                                   class=""
fi

# ---- theme colours -------------------------------------------------------

# Pango markup only takes literal hex, but the palette lives in
# current-theme.css and the theme switcher rewrites that file, so the colours
# are read from it at runtime rather than baked in here.
#
# Entries chain -- charging -> green -> #a6e3a1 -- so references are followed
# until a hex falls out. Anything ending at a GTK function (alpha(), shade())
# resolves to nothing, and paint() then emits the text unwrapped so it inherits
# whatever styles/tooltips.css set. That is the same fallback used when the
# theme file is missing entirely.

declare -A THEME=()
theme_css="${XDG_CONFIG_HOME:-$HOME/.config}/waybar/current-theme.css"
if [ -r "$theme_css" ]; then
	while read -r kw name val; do
		[ "$kw" = "@define-color" ] || continue
		THEME[$name]=${val%;}
	done < "$theme_css"
fi

# resolve a colour name to a hex, following @references
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
resolve charging;    C_CHARGING=$g_hex
resolve warning;     C_WARNING=$g_hex
resolve critical;    C_CRITICAL=$g_hex

# Single quotes on the attribute so the markup can go straight into the JSON
# string without a second round of escaping -- clock.jsonc's <span> does the
# same. The text is already pango- and JSON-escaped by the caller.
paint() {
	if [ -n "$1" ]; then
		printf "<span foreground='%s'>%s</span>" "$1" "$2"
	else
		printf '%s' "$2"
	fi
}

# ---- tooltip -------------------------------------------------------------

# Widths are measured on the plain text and the markup wrapped around the
# padded result afterwards -- ${#str} counts the span tags otherwise and every
# column drifts.

lw=0; vw=0
for i in "${!labels[@]}"; do
	[ ${#labels[i]} -gt "$lw" ] && lw=${#labels[i]}
	[ ${#values[i]} -gt "$vw" ] && vw=${#values[i]}
done

escape "$status"
head_plain="${capacity}%  ·  $g_esc"

# inner width: the block sits inside a 2-space indent, and the header, the
# gauge and the rules are all centred on that inner span rather than on the
# full row -- centring on the full row is what left the header a character
# short of the gauge's left edge
inner=$(( lw + 2 + vw ))
if [ ${#head_plain} -gt "$inner" ]; then
	# a long status ("Discharging") makes the header the widest thing in the
	# block. widen the value column to soak up the difference so the values
	inner=${#head_plain}                # still right-align on the rule's edge
	vw=$(( inner - lw - 2 ))
fi

# the state accent carries the gauge and the status word
case "$class" in
	charging) accent=$C_CHARGING ;;
	critical) accent=$C_CRITICAL ;;
	warning)  accent=$C_WARNING ;;
	*)        accent=$C_ACCENT ;;
esac

pad=$(( (inner - ${#head_plain}) / 2 ))
[ "$pad" -lt 0 ] && pad=0

# only the status word takes the accent; the percentage stays on the
# foreground colour so it reads as the headline figure
tooltip="  $(printf '%*s' "$pad" '')<b>${capacity}%</b>$(paint "$C_DIM" '  ·  ')$(paint "$accent" "<b>$g_esc</b>")"

# capacity gauge, filled to the nearest cell
bar_f=$(( capacity * inner / 100 ))
[ "$bar_f" -gt "$inner" ] && bar_f=$inner
fill=""; rest=""
for (( i = 0; i < inner; i++ )); do
	if [ "$i" -lt "$bar_f" ]; then fill+="█"; else rest+="░"; fi
done
tooltip+="\n  $(paint "$accent" "$fill")$(paint "$C_DIM" "$rest")"

rule=""
for (( i = 0; i < inner; i++ )); do rule+="─"; done
rule="\n  $(paint "$C_DIM" "$rule")"

# the rule after the live readings separates them from the figures that only
# move over weeks; SPLIT is the index of the last live row
split=-1
for i in "${!labels[@]}"; do
	case "${labels[i]}" in
		Power|Rate|"Full in"|"Empty in") split=$i ;;
	esac
done

tooltip+="$rule"
for i in "${!labels[@]}"; do
	printf -v l '%-*s' "$lw" "${labels[i]}"
	printf -v v '%*s'  "$vw" "${values[i]}"
	escape "$l"; l=$g_esc
	escape "$v"; v=$g_esc
	tooltip+="\n  $(paint "$C_DIM" "$l")  $(paint "$C_FG" "<b>$v</b>")"
	[ "$i" -eq "$split" ] && [ $(( i + 1 )) -lt ${#labels[@]} ] && tooltip+="$rule"
done

# ---- notifications -------------------------------------------------------

# Reimplements the built-in module's events block, same wording, icons, urgency
# and synchronous tag. Each level latches on the way down and only re-arms once
# the battery has climbed HYSTERESIS points back or gone on charge, so a level
# sitting on its threshold announces itself once rather than every five seconds.
#
# notify-send runs in the foreground on purpose: a backgrounded child outliving
# the script gets reaped before it reaches the bus, and the call costs ~20ms on
# a threshold crossing only. Its output goes to /dev/null so it can never touch
# the pipe waybar is reading this script's JSON from.

declare -A armed=()
if [ -r "$alert_state" ]; then
	while read -r k v; do
		[[ ${v:-} =~ ^[01]$ ]] && armed["$k"]=$v
	done < "$alert_state"
fi

announce() {
	notify-send "$@" -h string:x-canonical-private-synchronous:battery >/dev/null 2>&1
}

case "$status" in
	Discharging)
		armed[full]=1

		if [ "$capacity" -le "$CRIT" ]; then
			[ "${armed[crit]:-1}" -eq 1 ] &&
				announce "Battery Critical (${CRIT}%)" -u critical -i battery-010
			armed[crit]=0
		elif [ "$capacity" -ge $(( CRIT + HYSTERESIS )) ]; then
			armed[crit]=1
		fi

		if [ "$capacity" -le "$WARN" ]; then
			[ "$capacity" -gt "$CRIT" ] && [ "${armed[warn]:-1}" -eq 1 ] &&
				announce "Battery Low (${WARN}%)" -u critical -i battery-020
			armed[warn]=0
		elif [ "$capacity" -ge $(( WARN + HYSTERESIS )) ]; then
			armed[warn]=1
		fi
		;;

	Charging|Full)
		armed[warn]=1
		armed[crit]=1

		if [ "$capacity" -ge "$limit" ]; then
			[ "${armed[full]:-1}" -eq 1 ] &&
				announce "Battery Full (${capacity}%)" -i battery-100-charged
			armed[full]=0
		else
			armed[full]=1
		fi
		;;
esac

if [ ${#armed[@]} -gt 0 ]; then
	lines=()
	for k in "${!armed[@]}"; do lines+=("$k ${armed[$k]}"); done
	save "$alert_state" "${lines[@]}"
fi

printf '{"text":"%s %s%%","class":"%s","tooltip":"%s"}\n' \
	"$icon" "$capacity" "$class" "$tooltip"

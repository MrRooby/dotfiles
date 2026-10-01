#!/usr/bin/env bash
#
# CPU module for waybar: overall usage in the bar, per-thread usage and
# clocks in the tooltip.
#
# waybar's built-in cpu module can't take a custom tooltip-format (it only
# supports tooltip on/off), and it never exposes per-thread clocks — hence
# this replacement.
#
# /proc/stat counters are cumulative since boot, so the previous snapshot is
# kept on disk and every call reports the delta since waybar last polled.

set -uo pipefail

# Pinned so ${#str} counts characters rather than bytes: the rules, meters and
# separators are all multi-byte and every column is padded by length.
export LC_ALL=C.utf8

state="${XDG_RUNTIME_DIR:-/tmp}/waybar-cpu.state"

# ---- current snapshot ----------------------------------------------------

declare -A cur_total cur_idle
while read -r cpu rest; do
	case "$cpu" in
		cpu|cpu[0-9]*) ;;
		*) continue ;;
	esac
	# shellcheck disable=SC2086
	set -- $rest
	sum=0
	for v in "$@"; do sum=$((sum + v)); done
	cur_total["$cpu"]=$sum
	cur_idle["$cpu"]=$(( $4 + $5 ))   # idle + iowait
done < /proc/stat

# ---- previous snapshot ---------------------------------------------------

declare -A old_total old_idle
if [ -r "$state" ]; then
	while read -r cpu t i; do
		old_total["$cpu"]=$t
		old_idle["$cpu"]=$i
	done < "$state"
fi

{
	for cpu in "${!cur_total[@]}"; do
		printf '%s %s %s\n' "$cpu" "${cur_total[$cpu]}" "${cur_idle[$cpu]}"
	done
} > "$state"

# usage percentage for one cpu key, 0 on the very first run.
#
# The three readers below all set a global instead of echoing into $( ). At
# sixteen threads on a one-second poll that was sixteen forks a second for
# usage, sixteen more for the clock, and an awk on top of each.
g_use=0
usage_of() {
	local cpu=$1 dt di
	g_use=0
	[ -n "${old_total[$cpu]:-}" ] || return
	dt=$(( cur_total[$cpu] - old_total[$cpu] ))
	di=$(( cur_idle[$cpu] - old_idle[$cpu] ))
	[ "$dt" -le 0 ] && return
	g_use=$(( (100 * (dt - di) + dt / 2) / dt ))
}

# kHz -> "3.84". Integer maths rather than awk: scaling_cur_freq is already in
# kHz, so hundredths of a GHz is one division away.
g_fmt="-"
fmt_ghz() {
	local t
	if [ "${1:-0}" -le 0 ]; then g_fmt="-"; return; fi
	t=$(( ($1 + 5000) / 10000 ))
	printf -v g_fmt '%d.%02d' $(( t / 100 )) $(( t % 100 ))
}

# current clock of one thread, left in g_khz and g_ghz
g_khz=0; g_ghz="-"
clock_of() {
	local f="/sys/devices/system/cpu/cpu$1/cpufreq/scaling_cur_freq" v
	g_khz=0; g_ghz="-"
	[ -r "$f" ] || return
	read -r v < "$f" 2>/dev/null || return
	[[ $v =~ ^[0-9]+$ ]] || return
	g_khz=$v
	fmt_ghz "$v"
	g_ghz=$g_fmt
}

# ---- assemble ------------------------------------------------------------

usage_of cpu; total=$g_use
threads=$(nproc)

declare -a use clk
khz_sum=0
khz_max=0
for ((n = 0; n < threads; n++)); do
	usage_of "cpu$n"; use[n]=$g_use
	clock_of "$n";    clk[n]=$g_ghz
	khz_sum=$(( khz_sum + g_khz ))
	[ "$g_khz" -gt "$khz_max" ] && khz_max=$g_khz
done

if [ "$threads" -gt 0 ]; then fmt_ghz $(( khz_sum / threads )); else fmt_ghz 0; fi
avg_freq=$g_fmt
fmt_ghz "$khz_max"; max_freq=$g_fmt

read -r load1 load5 load15 tasks _ < /proc/loadavg

# Package power. RAPL's energy_uj is root-only on this kernel (the PLATYPUS
# mitigation) and k10temp exposes no power sensor, so amdgpu's PPT rail is
# the only readable figure -- on this APU it covers the whole package, cores
# included, not just the CPU. Labelled "pkg" rather than "cpu" for that reason.
watt="n/a"
for h in /sys/class/drm/card*/device/hwmon/hwmon*; do
	[ -r "$h/power1_input" ] || continue
	read -r uw < "$h/power1_input"
	dw=$(( uw / 100000 ))
	watt="$(( dw / 10 )).$(( dw % 10 )) W"
	break
done

# ---- power profile -------------------------------------------------------

# the icon doubles as the power profile indicator, and the profile names the
# header. read over the system bus rather than shelling out to tlp-stat, which
# takes the better part of a second and this runs once a second. tlp-pd serves
# the profile here.
profile=$(busctl get-property org.freedesktop.UPower.PowerProfiles \
	/org/freedesktop/UPower/PowerProfiles \
	org.freedesktop.UPower.PowerProfiles ActiveProfile 2>/dev/null | awk -F'"' '{print $2}')
case "$profile" in
	performance) icon="" ;;
	balanced)    icon="󰊚" ;;
	power-saver) icon="󰌪" ;;
	*)           icon="󰍛"; profile="unknown" ;;   # tlp-pd unavailable
esac

# states.css keys off these classes
if   [ "$total" -ge 90 ]; then class="critical"
elif [ "$total" -ge 75 ]; then class="warning"
else                          class=""
fi

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
resolve tooltip-ok;  C_OK=$g_hex
resolve warning;     C_WARM=$g_hex
resolve tooltip-br;  C_HOT=$g_hex
resolve critical;    C_CRIT=$g_hex

# ---- the load ramp -------------------------------------------------------

# Three bands, and the whole bar takes the colour of the value it is showing --
# green while there is room, yellow once it is working, red when it is pegged.
# The two lines are the 75 and 90 states.css already uses to colour this module
# in the bar, so a yellow meter and a yellow module mean the same thing.
#
# An earlier version graded each cell by its own position, which made every bar
# green at the base regardless of the reading and put the colour that mattered
# in a tip two pixels wide. Colour has to encode the value, not the axis.
g_ramp=""
ramp() {   # ramp <percent>
	if   [ "$1" -ge 90 ]; then g_ramp=$C_CRIT
	elif [ "$1" -ge 75 ]; then g_ramp=$C_WARM
	else                       g_ramp=$C_OK
	fi
}

# ---- drawing -------------------------------------------------------------

# Appending to a variable rather than returning through $( ): a span per cell
# would be a fork per cell, sixteen times a second.
g_out=""
add() {   # add <colour> <markup>
	if [ -n "$1" ]; then g_out+="<span foreground='$1'>$2</span>"; else g_out+="$2"; fi
}

# The fill is one colour -- the reading's -- against a dim trough. The tip
# resolves to an eighth of a cell (U+2588..U+258F are the left-aligned block
# eighths, so the partial is 0x2590 minus the remainder), because rounding a
# 12% thread down to nothing made an idle machine look switched off.
PARTIAL=("" "▏" "▎" "▍" "▌" "▋" "▊" "▉")

meter() {   # meter <percent> <cells>
	local pct=$1 n=$2 e f r i run=""

	e=$(( pct * n * 8 / 100 ))
	[ "$e" -lt 0 ] && e=0
	[ "$e" -gt $(( n * 8 )) ] && e=$(( n * 8 ))
	f=$(( e / 8 )); r=$(( e % 8 ))

	for (( i = 0; i < f; i++ )); do run+="█"; done
	if [ "$r" -gt 0 ]; then run+="${PARTIAL[r]}"; f=$(( f + 1 )); fi
	if [ -n "$run" ]; then ramp "$pct"; add "$g_ramp" "$run"; fi

	run=""
	for (( i = f; i < n; i++ )); do run+="░"; done
	[ -n "$run" ] && add "$C_DIM" "$run"
}

# ---- tooltip -------------------------------------------------------------

# Two columns of threads side by side; monospace keeps them aligned. The unit
# is stated once in the rows above instead of being repeated on all 16 lines,
# which is what made the tooltip so wide.
#
# " 00  ███▌░░░░   26%  3.84": index, an eight-cell load meter, usage, clock.
BAR_W=8
CELL_W=$(( 2 + 2 + BAR_W + 3 + 4 + 2 + 4 ))
GAP="      "
GRID_W=$(( 1 + CELL_W * 2 + ${#GAP} ))

# the figures that describe the package as a whole, in the label/value shape
# battery.sh uses: dim label, bright value
labels=(); values=()
row() { labels+=("$1"); values+=("$2"); }

row "Load"    "$load1  ·  $load5  ·  $load15"
row "Clock"   "$avg_freq GHz avg  ·  $max_freq peak"
row "Package" "$watt"
row "Tasks"   "${tasks/\// running of }"

lw=0
for i in "${!labels[@]}"; do
	[ ${#labels[i]} -gt "$lw" ] && lw=${#labels[i]}
done

width=$GRID_W
for i in "${!labels[@]}"; do
	[ $(( 1 + lw + 3 + ${#values[i]} )) -gt "$width" ] && width=$(( 1 + lw + 3 + ${#values[i]} ))
done

head_plain="${total}%  ·  $profile"
[ ${#head_plain} -gt "$width" ] && width=${#head_plain}

rule=""
for (( i = 0; i < width; i++ )); do rule+="─"; done

# the headline figure, the package meter, then the two blocks -- the same
# opening battery.sh and temperature.sh use
pad=$(( (width - ${#head_plain}) / 2 ))
[ "$pad" -lt 0 ] && pad=0
ramp "$total"

g_out="$(printf '%*s' "$pad" '')"
add "$g_ramp" "<b>${total}%</b>"
add "$C_DIM" "  ·  "
add "$C_HOT" "<b>$profile</b>"

g_out+="\n"
meter "$total" "$width"
g_out+="\n"
add "$C_DIM" "$rule"

g_out+="\n"
for i in "${!labels[@]}"; do
	printf -v l '%-*s' "$lw" "${labels[i]}"
	g_out+="\n "
	add "$C_DIM" "$l"
	g_out+="   "
	add "$C_FG" "<b>${values[i]}</b>"
done

g_out+="\n\n"
add "$C_DIM" "$rule"
g_out+="\n"

# one thread's cell, appended in place
cell() {
	local n=$1 pct
	pct=${use[n]}
	add "$C_DIM" "$(printf '%02d' "$n")"
	g_out+="  "
	meter "$pct" "$BAR_W"
	g_out+="   "
	ramp "$pct"
	add "$g_ramp" "$(printf '%3s%%' "$pct")"
	g_out+="  "
	add "$C_DIM" "$(printf '%4s' "${clk[n]}")"
}

half=$(( (threads + 1) / 2 ))
for ((r = 0; r < half; r++)); do
	g_out+="\n "
	cell "$r"
	m=$((r + half))
	if [ "$m" -lt "$threads" ]; then
		g_out+="$GAP"
		cell "$m"
	fi
done

printf '{"text":"%s %s%%","class":"%s","tooltip":"%s"}\n' \
	"$icon" "$total" "$class" "$g_out"

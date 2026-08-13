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

# Pinned so ${#str} counts characters rather than bytes (the header lines
# contain a multi-byte "·" and are centred by length), and so awk always
# prints a decimal point regardless of the user's locale.
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

# usage percentage for one cpu key, "0" on the very first run
usage_of() {
	local cpu=$1 dt di
	[ -n "${old_total[$cpu]:-}" ] || { echo 0; return; }
	dt=$(( cur_total[$cpu] - old_total[$cpu] ))
	di=$(( cur_idle[$cpu] - old_idle[$cpu] ))
	if [ "$dt" -le 0 ]; then echo 0; return; fi
	echo $(( (100 * (dt - di) + dt / 2) / dt ))
}

# current clock of one thread in GHz
clock_of() {
	local f="/sys/devices/system/cpu/cpu$1/cpufreq/scaling_cur_freq"
	if [ -r "$f" ]; then
		awk '{printf "%.2f", $1/1000000}' "$f"
	else
		printf '%s' "-"
	fi
}

# ---- assemble ------------------------------------------------------------

total=$(usage_of cpu)
threads=$(nproc)

declare -a use clk
freq_sum=0
for ((n = 0; n < threads; n++)); do
	use[n]=$(usage_of "cpu$n")
	clk[n]=$(clock_of "$n")
	freq_sum=$(awk -v a="$freq_sum" -v b="${clk[n]}" 'BEGIN{printf "%.4f", a + (b == "-" ? 0 : b)}')
done
avg_freq=$(awk -v s="$freq_sum" -v n="$threads" 'BEGIN{printf "%.2f", s/n}')

read -r load _ < /proc/loadavg

# Package power. RAPL's energy_uj is root-only on this kernel (the PLATYPUS
# mitigation) and k10temp exposes no power sensor, so amdgpu's PPT rail is
# the only readable figure — on this APU it covers the whole package, cores
# included, not just the CPU. Labelled "pkg" rather than "cpu" for that reason.
watt="n/a"
for h in /sys/class/drm/card*/device/hwmon/hwmon*; do
	[ -r "$h/power1_input" ] || continue
	read -r uw < "$h/power1_input"
	dw=$(( uw / 100000 ))
	watt="$(( dw / 10 )).$(( dw % 10 )) W"
	break
done

# Two columns of threads side by side; monospace keeps them aligned. The unit
# is stated once in the header instead of being repeated on all 16 rows, which
# is what made the tooltip so wide.
# no leading pad inside the columns: the tooltip's own CSS padding provides
# the margin, so the block sits symmetrically instead of 2 chars right
COL_W=13          # "00   8%  1.86"
GAP="      "
GRID_W=$(( COL_W * 2 + ${#GAP} ))

half=$(( (threads + 1) / 2 ))
grid=""
for ((r = 0; r < half; r++)); do
	l=$(printf '%02d %3s%%  %s' "$r" "${use[r]}" "${clk[r]}")
	m=$((r + half))
	if [ "$m" -lt "$threads" ]; then
		grid+="$l$GAP$(printf '%02d %3s%%  %s' "$m" "${use[m]}" "${clk[m]}")\n"
	else
		grid+="$l\n"
	fi
done

# centre a plain string over the grid, then let the caller add markup
center() {
	local text=$1 pad=$(( (GRID_W - ${#1}) / 2 ))
	[ "$pad" -lt 0 ] && pad=0
	printf '%*s' "$pad" ''
}

# Header is two short lines rather than one long one: as a single line it was
# wider than the grid and stretched the tooltip. Both are centred over the
# grid so the block reads as one column instead of a ragged left edge.
plain1="Total: ${total}%   ·   load ${load}"
plain2="avg ${avg_freq} GHz   ·   pkg ${watt}"
head1="$(center "$plain1")<b>${plain1}</b>"
head2="$(center "$plain2")${plain2}"
tooltip="${head1}\n${head2}\n\n${grid%\\n}"

# the icon doubles as the power profile indicator. read over the system bus
# rather than with powerprofilesctl, which is a python script and far too
# expensive to spawn once a second.
profile=$(busctl get-property net.hadess.PowerProfiles /net/hadess/PowerProfiles \
	net.hadess.PowerProfiles ActiveProfile 2>/dev/null | awk -F'"' '{print $2}')
case "$profile" in
	performance) icon="" ;;
	balanced)    icon="󰊚" ;;
	power-saver) icon="󰌪" ;;
	*)           icon="󰍛" ;;   # power-profiles-daemon unavailable
esac

# states.css keys off these classes
if   [ "$total" -ge 90 ]; then class="critical"
elif [ "$total" -ge 75 ]; then class="warning"
else                          class=""
fi

printf '{"text":"%s %s%%","class":"%s","tooltip":"%s"}\n' \
	"$icon" "$total" "$class" "$tooltip"

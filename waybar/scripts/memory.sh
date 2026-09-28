#!/usr/bin/env bash
#
# Memory module for waybar: usage in the bar, everything the kernel accounts
# for in the tooltip.
#
# waybar's built-in memory module interpolates {used}, {total}, {percentage}
# and {swapUsed} into one flat format string. It cannot break the total into
# what is anonymous and what is cache, cannot say a word about how the swap is
# backed, and on a machine swapping to zram that is the number that matters --
# 4.4 GiB of swap costing 917 MiB of the RAM it is supposed to be relieving is
# not something four replacements can express.
#
# Everything is read from /proc and /sys with builtins. `free` and `vmstat`
# report the same figures, but each is a process spawn on every poll.
#
# Requirements: none beyond a Linux 3.14+ kernel, for MemAvailable.

set -uo pipefail

# Pinned so ${#str} counts characters rather than bytes: the rules, meters and
# separators are all multi-byte and every column is padded by length.
export LC_ALL=C.utf8

WARN=75   # %
CRIT=90   # %

ICON="󰘚"
ICON_ALERT="󰀧"

# ---- /proc/meminfo -------------------------------------------------------

declare -A MEM=()
while read -r key val _; do
	MEM[${key%:}]=$val            # kibibytes, except the HugePages_* counts
done < /proc/meminfo

m() { printf '%s' "${MEM[$1]:-0}"; }

total=${MEM[MemTotal]:-0}
avail=${MEM[MemAvailable]:-0}

# Used is MemTotal - MemAvailable, the definition htop moved to once the kernel
# started publishing MemAvailable: it is the only one that answers "how much
# would I have to free before this machine starts hurting". The older
# total-free-buffers-cache arithmetic counts reclaimable slab as used and
# unreclaimable tmpfs as free, and gets both backwards.
used=$(( total - avail ))
[ "$used" -lt 0 ] && used=0

if [ "$total" -gt 0 ]; then
	pct=$(( (used * 100 + total / 2) / total ))
else
	pct=0
fi

swap_total=${MEM[SwapTotal]:-0}
swap_free=${MEM[SwapFree]:-0}
swap_used=$(( swap_total - swap_free ))
[ "$swap_used" -lt 0 ] && swap_used=0

if [ "$swap_total" -gt 0 ]; then
	swap_pct=$(( (swap_used * 100 + swap_total / 2) / swap_total ))
else
	swap_pct=0
fi

# ---- helpers -------------------------------------------------------------

# kibibytes -> "11.9 GiB". Integer maths with a rounding term rather than awk:
# this runs on every poll and awk would be a spawn for each of twenty rows.
g_hum=""
human() {
	local k=$1 v
	if [ "$k" -lt 0 ]; then k=0; fi
	if   [ "$k" -ge 1073741824 ]; then v=$(( (k * 10 + 536870912) / 1073741824 )); g_hum="TiB"
	elif [ "$k" -ge 1048576 ];    then v=$(( (k * 10 + 524288) / 1048576 ));      g_hum="GiB"
	elif [ "$k" -ge 1024 ];       then v=$(( (k * 10 + 512) / 1024 ));            g_hum="MiB"
	elif [ "$k" -gt 0 ];          then v=$(( k * 10 ));                           g_hum="KiB"
	else g_hum="0 B"; return
	fi
	printf -v g_hum '%d.%d %s' $(( v / 10 )) $(( v % 10 )) "$g_hum"
}

# same, from bytes -- zram and the vmstat page counters report in those
humanb() { human $(( ${1:-0} / 1024 )); }

# "14.3 / 38.7 GiB" -- the unit is dropped from the left side when both land in
# the same one, which they nearly always do
g_pair=""
pair() {   # pair <kib> <kib>
	local a b
	human "$1"; a=$g_hum
	human "$2"; b=$g_hum
	if [ "${a##* }" = "${b##* }" ]; then g_pair="${a% *} / $b"; else g_pair="$a / $b"; fi
}

# escape for pango markup, then for the JSON string: swap entries are paths
g_esc=""
escape() {
	local s=${1//&/\&amp;}
	s=${s//</\&lt;}
	s=${s//>/\&gt;}
	s=${s//\\/\\\\}
	g_esc=${s//\"/\\\"}
}

# ---- swap backing --------------------------------------------------------

# One row per active swap, because "4.4 GiB of 32 GiB used" says nothing about
# whether that cost a disk write or a compression pass. A zram device is asked
# what it actually holds: mm_stat carries the uncompressed size it is storing,
# the compressed size, and the RAM the allocator really took for it -- that
# last one is the honest cost, and it is already counted inside "used" above.
swap_rows=()
while read -r sfile stype ssize sused _; do
	[ "$sfile" = "Filename" ] && continue
	[[ ${ssize:-} =~ ^[0-9]+$ ]] || continue

	name=${sfile##*/}
	detail=""

	if [[ $sfile == /dev/zram* ]]; then
		mm="/sys/block/$name/mm_stat"
		if [ -r "$mm" ] && read -r orig compr memused _ < "$mm" \
			&& [[ $orig =~ ^[0-9]+$ ]] && [ "$orig" -gt 0 ]; then
			humanb "$orig";    o=$g_hum
			humanb "$memused"; u=$g_hum

			# one decimal of ratio, against the RAM actually taken rather than
			# the compressed size, so it reads as what it saved in practice
			if [ "${memused:-0}" -gt 0 ]; then
				r=$(( (orig * 10 + memused / 2) / memused ))
				detail="$o in $u · $(( r / 10 )).$(( r % 10 ))×"
			else
				detail="$o in $u"
			fi

			# "lzo-rle lzo lz4 [zstd] deflate" -- the bracketed one is in force
			alg=""
			if [ -r "/sys/block/$name/comp_algorithm" ]; then
				read -r line < "/sys/block/$name/comp_algorithm"
				for w in $line; do
					[ "${w:0:1}" = "[" ] && alg=${w:1:-1} && break
				done
			fi
			[ -n "$alg" ] && detail+=" · $alg"
		fi
	fi

	if [ -z "$detail" ]; then
		human "$sused"; a=$g_hum
		human "$ssize"; b=$g_hum
		detail="$a of $b"
	fi

	swap_rows+=("$name"$'\x1f'"$detail")
done < /proc/swaps

# ---- pressure and lifetime counters --------------------------------------

# PSI: the share of the last ten seconds in which something was stalled waiting
# on memory. "some" is any task blocked, "full" is every task blocked at once,
# which is the one that means the machine stopped.
psi=""
if [ -r /proc/pressure/memory ]; then
	while read -r kind a _; do
		[ "${a:0:6}" = "avg10=" ] || continue
		case $kind in
			some) psi_some=${a#avg10=} ;;
			full) psi_full=${a#avg10=} ;;
		esac
	done < /proc/pressure/memory
	if [ -n "${psi_some:-}" ]; then
		psi="some ${psi_some}%  ·  full ${psi_full:-0.00}%"
	fi
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
resolve tooltip-br;  C_ACCENT=$g_hex
resolve charging;    C_OK=$g_hex
resolve warning;     C_WARM=$g_hex
resolve critical;    C_CRIT=$g_hex

# Three bands, and the whole bar takes the colour of the value it is showing.
# Same two lines cpu.sh and temperature.sh draw, and the same ones states.css
# uses to colour this module in the bar.
g_ramp=""
ramp() {   # ramp <percent>
	if   [ "$1" -ge "$CRIT" ]; then g_ramp=$C_CRIT
	elif [ "$1" -ge "$WARN" ]; then g_ramp=$C_WARM
	else                            g_ramp=$C_OK
	fi
}

# ---- drawing -------------------------------------------------------------

g_out=""
add() {   # add <colour> <markup>
	if [ -n "$1" ]; then g_out+="<span foreground='$1'>$2</span>"; else g_out+="$2"; fi
}

# Fill in one colour against a dim trough, tip resolved to an eighth of a cell
# (U+2588..U+258F are the left-aligned block eighths, so the partial is 0x2590
# minus the remainder).
PARTIAL=("" "▏" "▎" "▍" "▌" "▋" "▊" "▉")

meter() {   # meter <percent> <cells>
	local p=$1 n=$2 e f r i run=""
	e=$(( p * n * 8 / 100 ))
	[ "$e" -lt 0 ] && e=0
	[ "$e" -gt $(( n * 8 )) ] && e=$(( n * 8 ))
	f=$(( e / 8 )); r=$(( e % 8 ))

	for (( i = 0; i < f; i++ )); do run+="█"; done
	if [ "$r" -gt 0 ]; then run+="${PARTIAL[r]}"; f=$(( f + 1 )); fi
	if [ -n "$run" ]; then ramp "$p"; add "$g_ramp" "$run"; fi

	run=""
	for (( i = f; i < n; i++ )); do run+="░"; done
	[ -n "$run" ] && add "$C_DIM" "$run"
}

# ---- rows ----------------------------------------------------------------

# kind: H heading, R sized row, T text row. A sized row's value is a figure
# and right-aligns into its own column; a text row carries a sentence -- a zram
# device's compression, a pressure pair -- and would drag that column four
# times wider if it shared it, which is exactly what it did at first.
kinds=(); as=(); bs=(); ps=()
head() { kinds+=(H); as+=("$1"); bs+=("${2:-}"); ps+=(""); }
row()  { kinds+=(R); as+=("$1"); bs+=("$2");     ps+=("${3:-}"); }
txt()  { kinds+=(T); as+=("$1"); bs+=("$2");     ps+=(""); }
kib()  { human "$2"; row "$1" "$g_hum" "${3:-}"; }

human "$total"; head "RAM" "$g_hum"
kib "Used"      "$used" "$pct"

# The two halves of "used" worth telling apart: what processes are actually
# holding, and what the kernel is only caching and would hand back under
# pressure. Cache folds in Buffers and the reclaimable half of Slab, which is
# what `free` counts as buff/cache and what MemAvailable assumes it can take.
kib "Anonymous" "$(m AnonPages)"
kib "Cache"     $(( $(m Buffers) + $(m Cached) + $(m SReclaimable) ))
kib "Available" "$avail"

if [ "$swap_total" -gt 0 ]; then
	human "$swap_total"; head "Swap" "$g_hum"
	kib "Used" "$swap_used" "$swap_pct"
	for r in "${swap_rows[@]}"; do
		txt "${r%%$'\x1f'*}" "${r#*$'\x1f'}"
	done
else
	head "Swap" "none"
fi

head "System"
commit_limit=${MEM[CommitLimit]:-0}
commit=${MEM[Committed_AS]:-0}
if [ "$commit_limit" -gt 0 ]; then
	cpct=$(( (commit * 100 + commit_limit / 2) / commit_limit ))
	[ "$cpct" -gt 100 ] && cpct=100
	pair "$commit" "$commit_limit"
	row "Committed" "$g_pair" "$cpct"
fi
[ -n "$psi" ] && txt "Pressure" "$psi"

# What the kernel keeps for itself and will not give back. SUnreclaim rather
# than Slab, because the reclaimable half of Slab is already in Cache above and
# counting it twice would make the rows add up to more than the machine has.
kib "Kernel" $(( $(m SUnreclaim) + $(m PageTables) + $(m KernelStack) ))

# ---- tooltip -------------------------------------------------------------

BAR_W=10

lw=0; vw=0
for i in "${!kinds[@]}"; do
	[ "${kinds[i]}" = H ] && continue
	[ ${#as[i]} -gt "$lw" ] && lw=${#as[i]}
	[ "${kinds[i]}" = R ] && [ ${#bs[i]} -gt "$vw" ] && vw=${#bs[i]}
done

# indent + label + gap + value + gap + meter + gap + percentage
width=$(( 3 + lw + 2 + vw + 3 + BAR_W + 2 + 4 ))
for i in "${!kinds[@]}"; do
	case ${kinds[i]} in
		H) n=$(( 1 + ${#as[i]} + 3 + ${#bs[i]} )) ;;
		T) n=$(( 3 + lw + 2 + ${#bs[i]} )) ;;
		*) continue ;;
	esac
	[ "$n" -gt "$width" ] && width=$n
done

pair "$used" "$total"; u_t=$g_pair
head_plain="${pct}%  ·  $u_t"
[ ${#head_plain} -gt "$width" ] && width=${#head_plain}

rule=""
for (( i = 0; i < width; i++ )); do rule+="─"; done

pad=$(( (width - ${#head_plain}) / 2 ))
[ "$pad" -lt 0 ] && pad=0
ramp "$pct"

g_out="$(printf '%*s' "$pad" '')"
add "$g_ramp" "<b>${pct}%</b>"
add "$C_DIM" "  ·  "
add "$C_ACCENT" "<b>$u_t</b>"

g_out+="\n"
meter "$pct" "$width"
g_out+="\n"
add "$C_DIM" "$rule"

for i in "${!kinds[@]}"; do
	if [ "${kinds[i]}" = H ]; then
		# a blank line before every group, the accent on the heading and the
		# group's total pushed out to the right edge -- same shape as
		# temperature.sh
		g_out+="\n\n "
		escape "${as[i]}"
		add "$C_ACCENT" "<b>$g_esc</b>"
		if [ -n "${bs[i]}" ]; then
			pad=$(( width - 1 - ${#as[i]} - ${#bs[i]} ))
			[ "$pad" -lt 3 ] && pad=3
			g_out+="$(printf '%*s' "$pad" '')"
			escape "${bs[i]}"
			add "$C_DIM" "$g_esc"
		fi
		continue
	fi

	printf -v l '%-*s' "$lw" "${as[i]}"
	escape "$l"; l=$g_esc
	g_out+="\n   "
	add "$C_DIM" "$l"
	g_out+="  "

	if [ "${kinds[i]}" = T ]; then
		escape "${bs[i]}"
		add "$C_FG" "$g_esc"
		continue
	fi

	printf -v v '%*s' "$vw" "${bs[i]}"
	escape "$v"
	add "$C_FG" "<b>$g_esc</b>"

	if [ -n "${ps[i]}" ]; then
		g_out+="   "
		meter "${ps[i]}" "$BAR_W"
		g_out+="  "
		ramp "${ps[i]}"
		add "$g_ramp" "$(printf '%3s%%' "${ps[i]}")"
	fi
done

# ---- bar -----------------------------------------------------------------

# states.css keys off these, the same thresholds the built-in module was
# configured with
if   [ "$pct" -ge "$CRIT" ]; then class="critical"; icon=$ICON_ALERT
elif [ "$pct" -ge "$WARN" ]; then class="warning";  icon=$ICON_ALERT
else                              class="";         icon=$ICON
fi

printf '{"text":"%s %s%%","class":"%s","tooltip":"%s"}\n' \
	"$icon" "$pct" "$class" "$g_out"

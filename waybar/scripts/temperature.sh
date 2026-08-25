#!/usr/bin/env bash
#
# Temperature module for waybar: CPU package temperature in the bar, every
# temperature sensor the kernel exposes in the tooltip.
#
# waybar's built-in temperature module reads one hwmon input and its
# tooltip-format understands only {temperatureC}/{temperatureF}, so there is no
# way to list the remaining sensors — hence this replacement. It also had to be
# pointed at a fixed chip path, which silently reported nothing on a machine
# without that chip.
#
# Sensors are discovered at runtime rather than hardcoded: hwmon indices are not
# stable across boots and which chips exist depends on the machine. Everything is
# read straight from sysfs and formatted with builtins — `sensors` reports the
# same numbers, but it and every awk in the formatting would be a process spawn
# on each poll.

set -uo pipefail

# Pinned so ${#str} counts characters rather than bytes (the header lines
# contain a multi-byte "·" and are centred by length).
export LC_ALL=C.utf8

WARN=80   # °C
CRIT=90   # °C

# ASCII unit separator, not tab: tab is IFS whitespace, so bash collapses runs
# of it and an empty limit field would shift every field after it
SEP=$'\x1f'

# ---- helpers -------------------------------------------------------------

# read one sysfs temperature file, failing on absent, unreadable and
# non-numeric values alike
read_temp() {
	local v
	[ -r "$1" ] || return 1
	read -r v < "$1" 2>/dev/null || return 1
	[[ $v =~ ^-?[0-9]+$ ]] || return 1
	printf '%s' "$v"
}

# milli-degrees -> "50.2", rounded to the tenth that actually moves. Integer
# maths rather than awk: this runs once per sensor per poll.
g_deg=""
degrees() {
	local m=$1 sign="" t
	if [ "$m" -lt 0 ]; then sign="-"; m=$(( -m )); fi
	t=$(( (m + 50) / 100 ))
	g_deg="$sign$(( t / 10 )).$(( t % 10 ))"
}

# escape for pango markup, then for the JSON string — labels come from the
# kernel and are pasted straight into both
g_esc=""
escape() {
	local s=${1//&/&amp;}
	s=${s//</&lt;}
	s=${s//>/&gt;}
	s=${s//\\/\\\\}
	g_esc=${s//\"/\\\"}
}

# Fill g_prio/g_group/g_alert for one hwmon chip. g_prio orders the tooltip so
# the sensors worth looking at come first; g_group is the heading text; g_alert
# is the fallback alert point in °C, used only for chips that declare no limit
# of their own — which on this machine means both k10temp and amdgpu.
#
# The CPU/GPU figure is Tjmax less a small margin: Zen 3 and its on-die Vega
# both stop at 100°C, and the SMU starts pulling clocks down a few degrees
# short of that, so 95 is where throttling is already under way. NVMe drives
# publish real thresholds and never reach the 75 below; it is there for the
# drives that publish nothing.
group_of() {
	local name=$1 dev=$2 b detail=""

	case "$name" in
		coretemp|k10temp|zenpower|cpu_thermal)
			g_prio=1; g_alert=95; g_group="CPU · $name" ;;
		amdgpu|radeon|nouveau|nvidia|i915|xe|gpu_thermal)
			g_prio=2; g_alert=95; g_group="GPU · $name" ;;
		nvme)
			# controller model rather than "nvme": tells the drives apart on
			# machines with more than one
			[ -r "$dev/model" ] && read -r detail < "$dev/model"
			g_prio=3; g_alert=75; g_group="SSD · ${detail:-${dev##*/}}" ;;
		drivetemp)
			# hwmon hangs off the scsi device; the block name is one level down
			for b in "$dev"/block/*; do
				[ -e "$b" ] && detail=${b##*/} && break
			done
			g_prio=3; g_alert=60; g_group="Disk · ${detail:-drivetemp}" ;;
		iwlwifi*|mt76*|ath*k*|rtw*|brcm*|phy[0-9]*)
			g_prio=4; g_alert=95; g_group="Wi-Fi · $name" ;;
		acpitz*)
			g_prio=6; g_alert=90; g_group="ACPI zone · $name" ;;
		thinkpad)
			g_prio=7; g_alert=90; g_group="ThinkPad EC" ;;
		BAT*|bat*|*battery*)
			g_prio=8; g_alert=60; g_group="Battery · $name" ;;
		*)
			g_prio=5; g_alert=90; g_group="$name" ;;
	esac
}

# ---- collect -------------------------------------------------------------

# prio <tab> chip-index <tab> group <tab> label <tab> milli <tab> limit-milli
# <tab> key <tab> labelled.  key identifies a sensor across boots (the hwmon
# index does not); labelled records whether the name came from the kernel or was
# synthesised, which decides who survives a duplicate pair.
rows=()

# resolved device path of every hwmon chip, so the thermal-zone pass can tell
# which zones are already covered
seen_devs=" "

collect_hwmon() {
	local h name idx dev f base n label labelled milli limit which v

	for h in /sys/class/hwmon/hwmon*; do
		[ -r "$h/name" ] || continue
		read -r name < "$h/name"
		idx=${h##*hwmon}

		dev=$(readlink -f "$h/device" 2>/dev/null) && seen_devs+="$dev "

		group_of "$name" "${dev:-}"

		for f in "$h"/temp*_input; do
			[ -e "$f" ] || continue
			milli=$(read_temp "$f") || continue

			# exactly 0 means "nothing wired up here" on every chip that does
			# this (the ThinkPad EC reports six such slots); a real 0°C reading
			# is not something a laptop sensor produces
			[ "$milli" -eq 0 ] && continue

			base=${f%_input}
			n=${base##*/temp}

			label=""; labelled=0
			[ -r "${base}_label" ] && read -r label < "${base}_label" && labelled=1

			# The lowest limit the chip declares, because a chip publishing both
			# puts its warning below its critical and the warning is the point
			# worth acting on: an NVMe drive is already throttling there. Some
			# chips park an unused limit at an absurd value, hence the ceiling.
			limit=""
			for which in crit max; do
				v=$(read_temp "${base}_${which}") || continue
				[ "$v" -gt 0 ] && [ "$v" -lt 200000 ] || continue
				if [ -z "$limit" ] || [ "$v" -lt "$limit" ]; then limit=$v; fi
			done

			rows+=("$g_prio$SEP$idx$SEP$g_group$SEP${label:-temp$n}$SEP$milli$SEP$limit$SEP${name// /_}:temp$n$SEP$labelled$SEP$g_alert")
		done
	done
}

# Thermal zones no hwmon chip already covers. Most zones are mirrored into
# hwmon, so dedupe on the resolved sysfs path rather than on the zone type.
collect_thermal() {
	local z zpath type milli trip

	for z in /sys/class/thermal/thermal_zone*; do
		[ -r "$z/type" ] || continue
		zpath=$(readlink -f "$z")
		[[ $seen_devs == *" $zpath "* ]] && continue

		milli=$(read_temp "$z/temp") || continue
		[ "$milli" -eq 0 ] && continue

		read -r type < "$z/type"

		# Same sanity check the hwmon path applies to crit/max: a zone with no
		# usable trip parks it at THERMAL_TEMP_INVALID (-274000 mC, i.e. below
		# absolute zero), and x86_pkg_temp and iwlwifi both do that here. Taken
		# verbatim it becomes a limit every reading is above, so the sensor
		# alerts permanently. An empty trip falls through to the category
		# default instead.
		trip=$(read_temp "$z/trip_point_0_temp") || trip=""
		[ -n "$trip" ] && { [ "$trip" -gt 0 ] && [ "$trip" -lt 200000 ]; } || trip=""

		rows+=("6${SEP}99${SEP}Thermal zone · $type$SEP${z##*/}$SEP$milli$SEP$trip${SEP}zone:${type// /_}${SEP}0${SEP}90")
	done
}

collect_hwmon
collect_thermal

if [ ${#rows[@]} -eq 0 ]; then
	printf '{"text":"󱃃 --","class":"","tooltip":"no temperature sensors found"}\n'
	exit 0
fi

mapfile -t rows < <(printf '%s\n' "${rows[@]}" | sort -t "$SEP" -k1,1n -k2,2n -s)

# split into parallel arrays: the rest of the script indexes them freely
prios=() groups=() labels=() millis=() limits=() keys=() labelled=() adefs=()
for r in "${rows[@]}"; do
	IFS=$SEP read -r p _ g l m lim k lb ad <<< "$r"
	prios+=("$p"); groups+=("$g"); labels+=("$l"); millis+=("$m")
	limits+=("$lim"); keys+=("$k"); labelled+=("$lb"); adefs+=("$ad")
done
count=${#groups[@]}

# ---- drop duplicate sensors ----------------------------------------------

# Several chips report the same physical sensor: on a ThinkPad the EC's CPU
# reading is also published as an ACPI thermal zone, and NVMe drives commonly
# mirror one of their vendor sensors into the spec-mandated "Composite". Which
# pairs collide is a per-machine fact, so it is measured rather than hardcoded.
#
# A pair has to agree on MIN_MATCH separate polls before either is hidden — two
# sensors sitting at the same whole degree for one poll is coincidence, not
# identity. Disagreements are counted rather than treated as proof of
# independence: two views of one sensor are read microseconds apart, so a 1°C
# step can land between the two reads and they briefly differ. Genuinely
# separate sensors disagree almost every poll, so the ratio separates them
# cleanly where a single mismatch would not.
#
# Both counters only ever grow, which makes the bookkeeping safe to lose: if two
# copies of the script race on the state file the worst case is a slower
# convergence, never a wrong verdict.

# Measured on the reference machine: the two real duplicate pairs agree on
# 94-100% of polls, while the closest genuinely distinct pair (the CPU die
# sensor against the EC's, which often round to the same degree) agrees on 34%.
# One disagreement per five agreements sits in the middle of that gap.
MIN_MATCH=30      # polls of agreement before a sensor is hidden
MATCH_RATIO=5     # ...tolerating one disagreement per this many agreements
DECAY_AT=1000     # halve both counters here, so old history stops outvoting new

state="${XDG_RUNTIME_DIR:-/tmp}/waybar-temperature.state"

declare -A hit=() miss=()
if [ -r "$state" ]; then
	while read -r a b h m; do
		# guard against a torn read: this file is rewritten every poll
		[[ ${h:-} =~ ^[0-9]+$ && ${m:-} =~ ^[0-9]+$ ]] || continue
		hit["$a $b"]=$h
		miss["$a $b"]=$m
	done < "$state"
fi

# Labels naming a computed value rather than a physical sensor. NVMe's
# "Composite" is the aggregate the drive reports to the host; on drives where it
# simply mirrors one of the real sensors (Lexar does this) the real one is the
# honest row to keep, so a derived label loses every duplicate pair it is in.
is_derived() {
	case "$1" in
		Composite) return 0 ;;
		*)         return 1 ;;
	esac
}

# survivor of a duplicate pair: prefer the sensor the kernel actually named,
# then the one carrying a real limit, then the more interesting chip
survives() {   # true if $1 should be kept over $2
	local i=$1 j=$2 li=0 lj=0

	[ "${labelled[i]}" != "${labelled[j]}" ] && { [ "${labelled[i]}" -eq 1 ]; return; }

	[ -n "${limits[i]}" ] && li=1
	[ -n "${limits[j]}" ] && lj=1
	[ "$li" != "$lj" ] && { [ "$li" -eq 1 ]; return; }

	[ "${prios[i]}" -le "${prios[j]}" ]
}

dupe=()
for ((i = 0; i < count; i++)); do dupe[i]=0; done

# Computed readings drop out before any pairing is considered — they are not
# measurements, so no amount of agreement history should decide their fate. The
# thresholds they carry are real, and on an NVMe drive they are usually the only
# ones declared at all, so they pass to that chip's physical sensors on the way
# out instead of leaving with the row.
for ((i = 0; i < count; i++)); do
	is_derived "${labels[i]}" || continue
	dupe[i]=1
	[ -n "${limits[i]}" ] || continue

	for ((j = 0; j < count; j++)); do
		[ "${groups[j]}" = "${groups[i]}" ] && [ -z "${limits[j]}" ] && limits[j]=${limits[i]}
	done
done

state_lines=()
for ((i = 0; i < count; i++)); do
	for ((j = i + 1; j < count; j++)); do
		pk="${keys[i]} ${keys[j]}"
		h=${hit[$pk]:-0}
		m=${miss[$pk]:-0}

		if [ "${millis[i]}" -eq "${millis[j]}" ]; then
			h=$(( h + 1 ))
		else
			m=$(( m + 1 ))
		fi

		if [ "$h" -ge "$DECAY_AT" ]; then
			h=$(( h / 2 )); m=$(( m / 2 ))
		fi

		state_lines+=("$pk $h $m")

		[ "$h" -ge "$MIN_MATCH" ] && [ $(( m * MATCH_RATIO )) -le "$h" ] || continue

		# skip if either end is already folded into another sensor, so three
		# copies of one reading collapse to one row rather than to none
		[ "${dupe[i]}" -eq 0 ] && [ "${dupe[j]}" -eq 0 ] || continue

		if survives "$i" "$j"; then w=$i; l=$j; else w=$j; l=$i; fi
		dupe[l]=1

		# The pair reports one reading, so the loser's threshold applies just as
		# well to the winner. Without this, folding away NVMe's "Composite" would
		# take the drive's throttle limits with it — it is the only sensor there
		# that declares any.
		[ -z "${limits[w]}" ] && limits[w]=${limits[l]}
	done
done

# Rename into place rather than truncating and rewriting: a reader that catches
# the file mid-write sees no pairs at all and starts the agreement history from
# zero, which throws away minutes of evidence and makes rows reappear.
if [ ${#state_lines[@]} -gt 0 ]; then
	tmp="$state.$$"
	if printf '%s\n' "${state_lines[@]}" > "$tmp" 2>/dev/null; then
		mv -f "$tmp" "$state" 2>/dev/null || rm -f "$tmp" 2>/dev/null
	else
		rm -f "$tmp" 2>/dev/null
	fi
fi

# indices that actually get shown; everything below iterates this
keep=()
for ((i = 0; i < count; i++)); do
	[ "${dupe[i]}" -eq 0 ] && keep+=("$i")
done

# The one number per sensor that counts as "too hot": what the chip declares if
# it declares anything, the category fallback otherwise. Computed here, after
# limits have been inherited from folded-away rows, so the tooltip's "!" and the
# notification below can never disagree about where the line is.
thrs=()
for ((i = 0; i < count; i++)); do
	if [ -n "${limits[i]}" ]; then
		thrs[i]=${limits[i]}
	else
		thrs[i]=$(( adefs[i] * 1000 ))
	fi
done

# ---- pick the bar reading ------------------------------------------------

hot=${keep[0]}
for i in "${keep[@]}"; do
	[ "${millis[i]}" -gt "${millis[hot]}" ] && hot=$i
done

# Preference order: the CPU's own die/package sensor, then any other CPU chip
# reading, then the EC's CPU sensor, then a generic zone, then whatever is
# hottest. Named sensors come first because Tdie/Tctl is what "CPU temperature"
# means on AMD and "Package id 0" on Intel.
cpu=-1
for want in Tdie Tctl "Package id 0"; do
	for i in "${keep[@]}"; do
		if [[ ${groups[i]} == CPU\ * && ${labels[i]} == "$want" ]]; then cpu=$i; break 2; fi
	done
done
if [ "$cpu" -lt 0 ]; then
	for i in "${keep[@]}"; do
		if [[ ${groups[i]} == CPU\ * ]]; then cpu=$i; break; fi
	done
fi
if [ "$cpu" -lt 0 ]; then
	for i in "${keep[@]}"; do
		if [[ ${groups[i]} == "ThinkPad EC" && ${labels[i]} == CPU ]]; then cpu=$i; break; fi
	done
fi
if [ "$cpu" -lt 0 ]; then
	for i in "${keep[@]}"; do
		if [[ ${groups[i]} == ACPI\ zone* || ${groups[i]} == Thermal\ zone* ]]; then cpu=$i; break; fi
	done
fi
[ "$cpu" -lt 0 ] && cpu=$hot

cpu_c=$(( (millis[cpu] + 500) / 1000 ))

# states.css keys off these classes
if   [ "$cpu_c" -ge "$CRIT" ]; then class="critical"; icon="󰀦"
elif [ "$cpu_c" -ge "$WARN" ]; then class="warning";  icon="󱃂"
elif [ "$cpu_c" -ge 60 ];      then class="";         icon="󱃂"
elif [ "$cpu_c" -ge 45 ];      then class="";         icon="󰔏"
else                                class="";         icon="󱃃"
fi

# ---- alerts --------------------------------------------------------------

# A notification that stays on screen until dismissed, raised when a sensor
# reaches the point where the hardware starts protecting itself.
#
# Nothing here reads a throttle flag, because this machine has none to read: AMD
# publishes no equivalent of Intel's core_throttle_count, and neither k10temp nor
# amdgpu declares a limit in hwmon. So a CPU or GPU alert is a temperature
# judgement (see g_alert in group_of), while a drive is held to the threshold it
# declares itself. The NVMe temp*_alarm flag is deliberately not consulted: it
# trips at the same warning temperature already covered by that threshold.

HYSTERESIS=5       # °C the sensor must fall before the alert re-arms
REPEAT_AFTER=300   # seconds before a still-hot sensor is announced again

alert_state="$state.alerts"

declare -A was=()
if [ -r "$alert_state" ]; then
	while read -r k ts; do
		[[ ${ts:-} =~ ^[0-9]+$ ]] || continue
		was["$k"]=$ts
	done < "$alert_state"
fi

now=${EPOCHSECONDS:-0}
alert_lines=()

for i in "${keep[@]}"; do
	prev=${was[${keys[i]}]:-}

	if [ "${millis[i]}" -ge "${thrs[i]}" ]; then
		# announce on the way in, then only once per REPEAT_AFTER: the same
		# synchronous tag means a re-announcement refreshes the existing popup
		# rather than stacking a second one, but it does bring the warning back
		# if it was dismissed while the sensor is still over the line
		if [ -z "$prev" ] || [ $(( now - prev )) -ge "$REPEAT_AFTER" ]; then
			degrees "${millis[i]}"; at=$g_deg
			degrees "${thrs[i]}";   lim=$g_deg

			case "${groups[i]}" in
				CPU*)       title="CPU thermal limit" ;;
				GPU*)       title="GPU thermal limit" ;;
				SSD*|Disk*) title="Drive thermal limit" ;;
				*)          title="Thermal limit" ;;
			esac

			# -t 0 rather than relying on the daemon: mako's [urgency=critical]
			# block already sets default-timeout=0, but stating it here keeps
			# the "until dismissed" promise independent of that config.
			#
			# Run in the foreground on purpose. Backgrounding this loses
			# notifications outright — a child outliving the script gets reaped
			# before it reaches the bus — and it buys nothing, since the call
			# costs ~20ms and only happens on a threshold crossing. Its output
			# still goes to /dev/null so it can never touch the pipe waybar is
			# reading this script's JSON from.
			notify-send -u critical -t 0 -i dialog-warning \
				-h "string:x-canonical-private-synchronous:thermal-${keys[i]}" \
				"$title" \
				"${groups[i]#* · } · ${labels[i]} reached ${at} °C (limit ${lim} °C)" \
				>/dev/null 2>&1
			prev=$now
		fi
		alert_lines+=("${keys[i]} $prev")

	elif [ -n "$prev" ] && [ "${millis[i]}" -ge $(( thrs[i] - HYSTERESIS * 1000 )) ]; then
		# still inside the hysteresis band: stay latched, so a sensor sitting on
		# its threshold and wobbling does not re-announce on every crossing
		alert_lines+=("${keys[i]} $prev")
	fi
done

if [ ${#alert_lines[@]} -gt 0 ]; then
	tmp="$alert_state.$$"
	if printf '%s\n' "${alert_lines[@]}" > "$tmp" 2>/dev/null; then
		mv -f "$tmp" "$alert_state" 2>/dev/null || rm -f "$tmp" 2>/dev/null
	else
		rm -f "$tmp" 2>/dev/null
	fi
else
	rm -f "$alert_state" 2>/dev/null
fi

# ---- tooltip -------------------------------------------------------------

# widest label, so the value column lines up across every group
lw=0
for i in "${keep[@]}"; do
	[ ${#labels[i]} -gt "$lw" ] && lw=${#labels[i]}
done

VAL_W=6                                   # "-10.0" .. "100.0"
row_w=$(( 2 + lw + 2 + VAL_W + 5 ))       # indent + label + gap + value + " °C" + marker
for i in "${keep[@]}"; do
	[ ${#groups[i]} -gt "$row_w" ] && row_w=${#groups[i]}
done

body=""
last=""
line=""
for i in "${keep[@]}"; do
	if [ "${groups[i]}" != "$last" ]; then
		[ -n "$body" ] && body+="\n"
		escape "${groups[i]}"
		body+="<b>$g_esc</b>\n"
		last=${groups[i]}
	fi

	degrees "${millis[i]}"
	printf -v line '  %-*s  %*s °C' "$lw" "${labels[i]}" "$VAL_W" "$g_deg"
	escape "$line"
	body+="$g_esc"

	# ▲ marks the hottest sensor, ! anything at or past its alert threshold —
	# cheaper than spending a whole column on a number that never changes. Same
	# threshold the notification uses, so the two always agree.
	[ "$i" -eq "$hot" ] && body+=" ▲"
	[ "${millis[i]}" -ge "${thrs[i]}" ] && body+=" <b>!</b>"
	body+="\n"
done

# centre a plain string over the body block
pad_for() {
	local n=$(( (row_w - ${#1}) / 2 ))
	[ "$n" -lt 0 ] && n=0
	printf -v g_pad '%*s' "$n" ''
}

degrees "${millis[cpu]}"; cpu_f=$g_deg
degrees "${millis[hot]}"; hot_f=$g_deg

# "SSD · Lexar…" -> "SSD": the ▲ in the body pinpoints the sensor, so the
# header only needs the category and stays narrower than the grid
plain1="CPU $cpu_f °C"
plain2="peak ${groups[hot]%% ·*} $hot_f °C"

pad_for "$plain1"; escape "$plain1"
tooltip="$g_pad<b>$g_esc</b>\n"
pad_for "$plain2"; escape "$plain2"
tooltip+="$g_pad$g_esc\n\n"
tooltip+="${body%\\n}"

printf '{"text":"%s %d°C","class":"%s","tooltip":"%s"}\n' \
	"$icon" "$cpu_c" "$class" "$tooltip"

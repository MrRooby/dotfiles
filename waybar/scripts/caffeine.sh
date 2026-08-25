#!/usr/bin/env bash
#
# Caffeine toggle for waybar: keep the machine fully awake, lid closed included.
#
#   caffeine.sh          -> waybar json for the current state
#   caffeine.sh toggle   -> flip it, then repaint the module
#   caffeine.sh lid      -> what sway's lid:on bindswitch runs, see below
#
# Three separate things shut this laptop down and all of them have to be held
# off:
#
#   logind   HandleLidSwitch=suspend, so closing the lid suspends outright.
#   hypridle runs hyprlock at 300s and powers the outputs off at 360s.
#   sway     `bindswitch --locked lid:on exec ...` locks the moment the lid
#            shuts, independently of the other two.
#
# One systemd inhibitor covers the first two. logind obviously honours its own
# lock, and hypridle checks for a systemd idle inhibitor before firing its
# timers unless ignore_systemd_inhibit is set -- ~/.config/hypr/hypridle.conf
# has no general block at all, so it sits at the default of false and the lock
# holds it. That is why waybar's built-in idle_inhibitor module is not enough
# here: it speaks only the wayland idle protocol and never reaches logind, so
# the lid would still suspend.
#
# Sway is the one that cannot be inhibited. It is not a systemd citizen: it
# never looks at logind's inhibitor list, it just runs the command bound to
# the switch. So ~/.config/sway/config runs `caffeine.sh lid` instead of
# hyprlock directly, and the lid subcommand below drops the lock screen when
# the inhibitor is held. Without that the machine stays awake with the lid
# shut but you come back to a lock screen anyway.
#
# --mode=block rather than delay: a delay lock only buys a few seconds before
# the suspend proceeds anyway. Block-mode locks on these four are granted to an
# active local session by the stock polkit rules, so none of this needs sudo.
#
# The lock is a `sleep infinity` held under setsid, so it outlives a waybar
# restart -- as a plain child it would die with the bar and silently re-enable
# sleep while the module still showed "on".

set -uo pipefail

SIGNAL=8

WHO="waybar-caffeine"
WHY="Caffeine toggled on from waybar"
WHAT="idle:sleep:handle-lid-switch:handle-suspend-key"

# ---- state ---------------------------------------------------------------

# PID of our inhibitor, empty when none is held.
#
# Asks logind rather than scanning process cmdlines. `pgrep -f` on the tag
# would also match any shell that merely mentions it -- including the one that
# starts this script from a terminal -- and a false positive here means the
# module claims the machine is awake when nothing is holding it. logind's own
# list is the thing that actually decides whether we sleep, so it is the honest
# source. Columns are WHO UID USER PID COMM WHAT WHY MODE.
holder() {
	local pid
	pid=$(systemd-inhibit --list 2>/dev/null | awk -v w="$WHO" '$1 == w { print $4; exit }')
	[ -n "$pid" ] || return 1
	printf '%s' "$pid"
}

# ---- actions -------------------------------------------------------------

# logind registers or drops the lock a moment after the process appears or
# dies, so both actions wait for it to actually take effect -- up to half a
# second. Without this the state printed at the bottom of this same run is the
# old one, and the icon would not flip until the next 10s poll.
settle() {   # settle held|gone
	local n
	for n in 1 2 3 4 5 6 7 8 9 10; do
		if [ "$1" = held ]; then
			holder >/dev/null && return 0
		else
			holder >/dev/null || return 0
		fi
		sleep 0.05
	done
	return 1
}

start() {
	# setsid detaches the lock from waybar's process group; without it the
	# inhibitor dies with the bar and sleep quietly comes back.
	setsid --fork systemd-inhibit \
		--what="$WHAT" --mode=block --who="$WHO" --why="$WHY" \
		sleep infinity >/dev/null 2>&1

	settle held
}

stop() {
	local pid
	# No pkill sweep here on purpose. The lock exists exactly as long as the
	# process holding it does, so if logind lists nothing then nothing is
	# inhibiting -- a sweep could only ever match something logind already
	# forgot, while a loose `pkill -f` on the tag risks killing the very shell
	# that invoked this script.
	pid=$(holder) && kill "$pid" 2>/dev/null

	settle gone
}

# ---- main ----------------------------------------------------------------

# sway runs this on the lid switch in place of hyprlock (see the note at the
# top). Sway never consults logind's inhibitor list, so the lock that stops the
# suspend cannot stop the lock screen -- the check has to happen here, in the
# command sway execs. exec so no shell lingers behind hyprlock.
if [ "${1:-}" = "lid" ]; then
	holder >/dev/null && exit 0
	exec hyprlock
fi

if [ "${1:-}" = "toggle" ]; then
	if holder >/dev/null; then stop; else start; fi
	pkill -RTMIN+$SIGNAL waybar 2>/dev/null
fi

if holder >/dev/null; then
	printf '{"text":"󰅶","class":"active","tooltip":"Caffeine: on\\nlid close, sleep and idle inhibited"}\n'
else
	printf '{"text":"󰛉","class":"inactive","tooltip":"Caffeine: off"}\n'
fi

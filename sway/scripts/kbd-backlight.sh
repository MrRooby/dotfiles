#!/usr/bin/env bash
#
# Carry the keyboard backlight across sleep.
#
#   kbd-backlight.sh save      -> on the way into sleep
#   kbd-backlight.sh restore   -> on the way out
#
# hypridle runs both, from before_sleep_cmd and after_sleep_cmd. The laptop
# comes back from suspend with the backlight off whatever it was set to, and
# nothing puts it back: systemd-backlight does this job across a reboot, not
# across a suspend.
#
# The level is written back twice, two seconds apart. Once is enough when the
# keyboard's controller is already up; the second write is for when it is still
# settling and drops the first. And it is written whether or not sysfs already
# shows that level -- what sysfs reports after a resume can be the level from
# before the suspend, not what the keyboard is doing.
#
# The flock keeps a save from overtaking a restore that is still at it. A
# laptop that wakes for a moment and goes straight back to sleep gets the two
# within seconds of each other, and a save reading the level in between would
# record "off" as the setting to remember.

set -uo pipefail

led=""
for d in /sys/class/leds/*::kbd_backlight; do
	[ -r "$d/brightness" ] || continue
	led=$d
	break
done
[ -n "$led" ] || exit 0

state="${XDG_RUNTIME_DIR:-/tmp}/kbd-backlight.state"

exec 9>"$state.lock"
flock 9

case "${1:-}" in
	save)
		cat "$led/brightness" > "$state"
		;;
	restore)
		[ -r "$state" ] || exit 0
		read -r want < "$state" || exit 0
		[[ $want =~ ^[0-9]+$ ]] || exit 0

		# through logind, which lets the session's user set it without root
		brightnessctl -q -d "${led##*/}" set "$want"
		sleep 2
		brightnessctl -q -d "${led##*/}" set "$want"
		;;
	*)
		echo "usage: ${0##*/} save|restore" >&2
		exit 2
		;;
esac

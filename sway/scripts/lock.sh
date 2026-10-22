#!/usr/bin/env bash
#
# Lock the screen: the lock sound, then hyprlock.
#
# Everything that locks runs this -- the keybinding in sway's config,
# hypridle's lock_cmd, which is where `loginctl lock-session`, the idle timeout
# and suspend all end up, and caffeine.sh for the lid. Nothing announces a lock
# under sway for event-sounds.sh to listen for: sway has no event for it and
# hyprlock does not set logind's LockedHint, so the sound has to be played by
# whoever starts the lock screen.
#
# Only one hyprlock may run: a second one on top of the first holds its own
# claim on the fingerprint reader, and one of the two then never exits after
# unlock, which blocks every later lock. Closing the lid runs this script twice
# in the same instant -- sway's lid switch and hypridle's before_sleep -- and a
# pidof check alone lets both through. The flock makes it atomic: one caller at
# a time gets to look and start, the other leaves.

exec 9>"${XDG_RUNTIME_DIR:-/tmp}/hyprlock-start.lock"
flock -n 9 || exit 0

pidof hyprlock >/dev/null && exit 0

"$(dirname "$(readlink -f "$0")")/event-sounds.sh" play lock 9>&- &
exec hyprlock 9>&-

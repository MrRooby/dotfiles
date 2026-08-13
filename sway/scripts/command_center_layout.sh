#!/bin/zsh

# 1. Launch terminals with target titles and commands
foot -T "layout_shell" &
foot -T "layout_btop" -e btop &
foot -T "layout_cmatrix" -e cmatrix -C red -a &

# 2. Allow the compositor time to map the windows
sleep 0.2

# 3. Apply exact positioning and dimensions
swaymsg '[title="layout_shell"] floating enable, move absolute position 1941 44, resize set 708 824'
swaymsg '[title="layout_btop"] floating enable, move absolute position 2675 45, resize set 1152 820'
swaymsg '[title="layout_cmatrix"] floating enable, move absolute position 1939 889, resize set 1876 172'

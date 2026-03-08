#!/bin/bash

CHOICE=$(dialog --clear \
--title "Dotfiles Manager" \
--menu "Choose action:" 15 50 4 \
1 "Push config → repo" \
2 "Pull repo → config" \
3 "Add new folder" \
4 "Exit" \
3>&1 1>&2 2>&3)

clear

case $CHOICE in
    1) echo "Push configs";;
    2) echo "Pull configs";;
    3) echo "Add folder";;
    4) exit;;
esac

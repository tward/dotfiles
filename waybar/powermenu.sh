#!/bin/sh
# fuzzel-based power menu for waybar's custom/power module.
chosen=$(printf '%s\n' "Shutdown" "Reboot" "Logout" "Suspend" | fuzzel --dmenu --prompt "power> ")

case "$chosen" in
    Shutdown) systemctl poweroff ;;
    Reboot)   systemctl reboot ;;
    Logout)   niri msg action quit ;;
    Suspend)  systemctl suspend ;;
esac

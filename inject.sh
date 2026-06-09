#!/bin/bash
TEXT="$1"
if [ -z "$TEXT" ]; then exit 1; fi
UID_VAL=$(id -u)

OLD=$(pbpaste 2>/dev/null)
printf '%s' "$TEXT" | pbcopy
launchctl asuser $UID_VAL osascript -e 'tell application "System Events" to keystroke "v" using command down'
sleep 1
launchctl asuser $UID_VAL osascript -e 'tell application "System Events" to key code 36'
sleep 0.3
printf '%s' "$OLD" | pbcopy

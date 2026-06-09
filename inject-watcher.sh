#!/bin/bash
TRIGGER="/tmp/voiceinput_inject.txt"
HELPER="/Users/I027910/Desktop/ju/projects/VoiceInput/inject-helper"

> "$TRIGGER"
echo "inject-watcher running, watching $TRIGGER"

while true; do
    TEXT=$(cat "$TRIGGER" 2>/dev/null)
    if [ -n "$TEXT" ]; then
        > "$TRIGGER"
        "$HELPER" "$TEXT"
    fi
    sleep 0.2
done

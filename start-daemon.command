#!/bin/bash
cd "$(dirname "$0")"
if pgrep -f "inject-helper --daemon" > /dev/null; then
    echo "inject-helper daemon already running"
else
    exec ./inject-helper --daemon
fi

#!/bin/sh
# Builds the nylon macOS menu app (nylon-macos repo) and starts it.
# No argument: it uses the file picked in its menu (or ./central.yaml). With one: that file.
# Anything after it goes to the app, e.g. -metrics http://127.0.0.1:9091/metrics
set -eu

app=$(cd "$(dirname "$0")/.." && pwd)

swift build -c release --package-path "$app"
pkill -x Nylon 2>/dev/null || true # don't stack menu bar icons
central=${1:-}; [ $# -gt 0 ] && shift
"$app/.build/release/Nylon" ${central:+-central "$central"} "$@" >/dev/null 2>&1 &
echo "Nylon running (pid $!). Stop it with Quit in its menu or: pkill -x Nylon"

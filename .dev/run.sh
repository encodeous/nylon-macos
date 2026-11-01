#!/bin/sh
# Builds the nylon macOS menu app (nylon-macos repo) and starts it. The helper only lets in a build signed with your
# team, so set one in Config/Local.xcconfig first, or try the UI with a pretend helper: .dev/run.sh -fake YES
# Arguments go to the app.
set -eu

app=$(cd "$(dirname "$0")/.." && pwd)

xcodebuild -project "$app/nylon.xcodeproj" -scheme nylon -configuration Debug -derivedDataPath "$app/build/DerivedData" \
    build -quiet
# don't stack status items; matched by path, since the nylon daemon has the same process name
pkill -f 'nylon.app/Contents/MacOS/nylon( |$)' 2>/dev/null || true
"$app/build/DerivedData/Build/Products/Debug/nylon.app/Contents/MacOS/nylon" "$@" >/dev/null 2>&1 &
echo "nylon running (pid $!). Stop it with Quit in its menu or: pkill -f 'nylon.app/Contents/MacOS/nylon( |\$)'"

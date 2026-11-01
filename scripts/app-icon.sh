#!/bin/sh
# Build phase: AppIcon.icns from nylon's logo (SCRIPT_INPUT_FILE_1, in the nylon submodule), so the app always uses
# the logo the main repo has. Each size macOS asks for, drawn at 80% so it has the margin other app icons have.
set -eu

tmp=$(mktemp -d) # the build sandbox only lets it write its output, and temporary files
trap 'rm -rf "$tmp"' EXIT
iconset=$tmp/AppIcon.iconset
mkdir "$iconset"
for size in 16 32 128 256 512; do
    for scale in 1 2; do
        px=$((size * scale))
        png=$iconset/icon_${size}x${size}$([ $scale = 2 ] && echo @2x || true).png
        sips -s format png -z $((px * 8 / 10)) $((px * 8 / 10)) "$SCRIPT_INPUT_FILE_1" --out "$png" >/dev/null
        sips -p $px $px "$png" >/dev/null
    done
done
iconutil -c icns "$iconset" -o "$SCRIPT_OUTPUT_FILE_0"

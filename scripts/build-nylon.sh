#!/bin/sh
# Build phase: the nylon binary from the nylon repo (NYLON_DIR, the submodule by default) for each architecture this
# build targets, as one universal binary at SCRIPT_OUTPUT_FILE_0 (Contents/Helpers/nylon), signed like the app.
# Go comes from PATH, mise or Homebrew; the toolchain nylon's go.mod names is used either way (Go fetches it if needed).
set -eu

export PATH="$PATH:$HOME/.local/share/mise/shims:/opt/homebrew/bin:/usr/local/go/bin"
if ! command -v go >/dev/null; then
    echo "error: Go isn't installed. nylon.app bundles nylon, which is written in Go: https://go.dev/dl"
    exit 1
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
binaries=""
for arch in $ARCHS; do
    case $arch in
    arm64) goarch=arm64 ;;
    x86_64) goarch=amd64 ;;
    *) echo "error: no Go architecture for $arch"; exit 1 ;;
    esac
    # same flags as nylon's Dockerfile, plus -trimpath so the binary doesn't depend on where it was built
    CGO_ENABLED=0 GOOS=darwin GOARCH=$goarch go -C "$NYLON_DIR" build -trimpath -buildvcs=false -ldflags "-s -w" \
        -o "$tmp/nylon-$arch" .
    binaries="$binaries $tmp/nylon-$arch"
done

mkdir -p "$(dirname "$SCRIPT_OUTPUT_FILE_0")"
# shellcheck disable=SC2086 # one argument per binary
lipo -create $binaries -output "$SCRIPT_OUTPUT_FILE_0"
codesign --force --options runtime --identifier com.encodeous.nylon.daemon --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" \
    "$SCRIPT_OUTPUT_FILE_0"

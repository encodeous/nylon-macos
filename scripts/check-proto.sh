#!/bin/sh
# Build phase: fails if Shared/Generated/nylon_ipc.pb.swift (SCRIPT_INPUT_FILE_2) wasn't generated from the nylon
# repo's current proto (SCRIPT_INPUT_FILE_1), e.g. after a submodule update without scripts/proto.sh.
set -eu

hash=$(shasum -a 256 "$SCRIPT_INPUT_FILE_1" | cut -d' ' -f1)
if ! head -1 "$SCRIPT_INPUT_FILE_2" | grep -q "sha256 $hash"; then
    echo "error: Shared/Generated/nylon_ipc.pb.swift doesn't match $SCRIPT_INPUT_FILE_1. Run scripts/proto.sh."
    exit 1
fi
touch "$SCRIPT_OUTPUT_FILE_0"

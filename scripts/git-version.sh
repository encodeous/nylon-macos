#!/bin/sh
# Build phase: stamps the built app's Info.plist with which commit it was built from (NylonGitDescribe), shown on the
# About tab: the tag on a tagged commit (v1.2.0), commits past the last tag otherwise (v1.2.0-3-gabc1234), "-dirty" with
# uncommitted changes, and the bare commit when there's no tag yet.
set -eu

describe=$(git -C "$SRCROOT" describe --tags --always --dirty 2>/dev/null || echo unknown)
plist="$TARGET_BUILD_DIR/$INFOPLIST_PATH"
/usr/libexec/PlistBuddy -c "Delete :NylonGitDescribe" "$plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :NylonGitDescribe string $describe" "$plist"

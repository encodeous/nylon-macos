#!/bin/sh
# Builds dist/nylon.dmg: nylon.app next to an Applications shortcut to drag it onto.
#
# With a team in Config/Local.xcconfig, the app and the DMG are signed with your Developer ID. Without one they're
# signed ad hoc, and the app's first launch needs "Open Anyway" in System Settings.
#
# Environment, all optional:
#   VERSION, BUILD_NUMBER   the app's version (e.g. 1.2.0) and build number, instead of Config/Base.xcconfig's
#   NOTARY_PROFILE          notarize with this keychain profile, from `xcrun notarytool store-credentials`
#   NOTARY_KEY, NOTARY_KEY_ID, NOTARY_ISSUER
#                           or with this App Store Connect API key (.p8 file), its ID and its issuer ID
#   REQUIRE_SIGNING=1       fail rather than build an ad hoc DMG when there's no team or Developer ID identity (CI)
set -eu
cd "$(dirname "$0")/.."

# Build settings that override the xcconfigs
set -- -project nylon.xcodeproj -scheme nylon -configuration Release
[ -n "${VERSION:-}" ] && set -- "$@" MARKETING_VERSION="$VERSION"
[ -n "${BUILD_NUMBER:-}" ] && set -- "$@" CURRENT_PROJECT_VERSION="$BUILD_NUMBER"
# a build setting's value (the app's; the helper's comes second)
setting() {
    name=$1
    shift
    xcodebuild "$@" -showBuildSettings 2>/dev/null | awk -v name="$name" '$1 == name { print $3; exit }'
}
team=$(setting DEVELOPMENT_TEAM "$@")
style=$(setting CODE_SIGN_STYLE "$@" | tr '[:upper:]' '[:lower:]')
if [ -z "$team" ] && [ -n "${REQUIRE_SIGNING:-}" ]; then
    echo "error: no DEVELOPMENT_TEAM in Config/Local.xcconfig, and REQUIRE_SIGNING is set" >&2
    exit 1
fi

archive=build/nylon.xcarchive
stage=build/dmg # what the DMG shows
rm -rf dist "$archive" "$stage" build/export
xcodebuild "$@" -derivedDataPath build/DerivedData -archivePath "$archive" archive -quiet

mkdir -p "$stage" dist
if [ -n "$team" ]; then
    # Signs it with Developer ID, for apps shipped outside the App Store. Manual signing (CI) names the certificate;
    # automatic signing finds it.
    cat >build/ExportOptions.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>developer-id</string>
	<key>teamID</key>
	<string>$team</string>
	<key>signingStyle</key>
	<string>$style</string>
	<key>signingCertificate</key>
	<string>Developer ID Application</string>
</dict>
</plist>
EOF
    xcodebuild -exportArchive -archivePath "$archive" -exportOptionsPlist build/ExportOptions.plist \
        -exportPath build/export -quiet
    cp -R build/export/nylon.app "$stage/"
else
    cp -R "$archive/Products/Applications/nylon.app" "$stage/"
fi
ln -s /Applications "$stage/Applications"
hdiutil create -volname nylon -srcfolder "$stage" -format UDZO dist/nylon.dmg

[ -n "$team" ] || exit 0
identity=$(security find-identity -v -p codesigning | grep "Developer ID Application: .*($team)" | awk 'NR == 1 { print $2 }')
if [ -z "$identity" ]; then
    echo "error: no Developer ID Application certificate for team $team in the keychain" >&2
    exit 1
fi
codesign --sign "$identity" --timestamp dist/nylon.dmg
if [ -n "${NOTARY_PROFILE:-}" ]; then
    xcrun notarytool submit dist/nylon.dmg --keychain-profile "$NOTARY_PROFILE" --wait
elif [ -n "${NOTARY_KEY:-}" ]; then
    xcrun notarytool submit dist/nylon.dmg --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" --wait
else
    exit 0
fi
xcrun stapler staple dist/nylon.dmg

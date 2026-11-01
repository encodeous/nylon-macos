# Building nylon for Mac

You need Xcode 16.3 or later (the pinned SwiftProtobuf needs Swift 6.1) and [Go](https://go.dev/dl). The app bundles nylon, built from the `nylon` submodule, and takes its icon and IPC protocol from there, so clone with it:

```bash
git clone --recurse-submodules git@github.com:encodeous/nylon-macos.git
```

In a clone without it, run `git submodule update --init`.

## Signing

Out of the box the app is signed ad hoc, which needs no Apple account. The helper only lets in an app signed by its own team, though, so to use it, copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` and set your Team ID (Membership details at [developer.apple.com/account](https://developer.apple.com/account)). `Local.xcconfig` is gitignored.

`Local.xcconfig` can also point the build at another nylon checkout with `NYLON_DIR`, e.g. `$(SRCROOT)/../nylon`.

## Run it in Xcode

1. Open `nylon.xcodeproj`. Xcode fetches the Swift packages the first time.
2. Pick a scheme in the toolbar:
   - **nylon**: the real app. Signed with your team, it can install and use the helper.
   - **nylon (fake)**: the app with a pretend helper (two networks and a log that grows), for working on the UI. Works signed ad hoc.
3. Press ⌘R. The app has no Dock icon; it shows nylon's icon in the menu bar and opens Settings when the helper isn't set up.
4. ⌘U runs the tests.

Building runs Go to compile nylon, so Go needs to be on your PATH, in mise, or in `/opt/homebrew/bin`.

To use the real helper while you change the app, install it once from a Debug build copied somewhere stable, e.g. `/Applications/nylon.app`. Later Debug builds with the same version find it by its Mach service name and use its pairing, so rebuilding the app never reinstalls the helper. A helper from a release DMG won't do: it only lets in apps signed with Developer ID, which Debug builds aren't, and its version differs. Its logs are in `/Library/Logs/nylon`.

From a terminal, `.dev/run.sh` builds the Debug app and starts it; arguments go to the app, e.g. `.dev/run.sh -fake YES`. `xcodebuild -scheme nylon -derivedDataPath build/DerivedData test` runs the tests.

## After updating the submodule

`Shared/Generated/nylon_ipc.pb.swift` is generated from `nylon/protocol/nylon_ipc.proto` and committed, so building needs no protobuf tools. A build phase compares the proto's hash with the one stamped in the generated file, and fails if the proto changed:

```bash
scripts/proto.sh
```

regenerates it. It needs `protoc`, and builds `protoc-gen-swift` from the SwiftProtobuf version `Package.resolved` pins, so the code matches the library the app links.

## Publish a DMG

### From your Mac

```bash
scripts/dmg.sh
```

writes `dist/nylon.dmg`. With a team in `Local.xcconfig`, the app and the DMG are signed with your Developer ID Application certificate (Xcode → Settings → Accounts → Manage Certificates to make one). `VERSION=1.2.0 BUILD_NUMBER=12` set the app's version.

To notarize, so it opens without "Open Anyway", save App Store Connect credentials in your keychain once, then name the profile:

```bash
xcrun notarytool store-credentials nylon-notary
```

```bash
NOTARY_PROFILE=nylon-notary scripts/dmg.sh
```

### From GitHub Actions

Pushing a tag that starts with `v` runs `.github/workflows/release.yml`: it builds the app at that version, signs it with the Developer ID certificate, notarizes it, and attaches `nylon.dmg` to a GitHub release for the tag.

```bash
git tag v1.2.0
```

```bash
git push origin v1.2.0
```

It needs these repository secrets (Settings → Secrets and variables → Actions):

| Secret | What |
|---|---|
| `APPLE_TEAM_ID` | Your Team ID. |
| `DEVELOPER_ID_CERTIFICATE` | Your Developer ID Application certificate and its private key, as a base64 `.p12`. In Keychain Access, export the certificate (with its key) as a `.p12`, then `base64 -i certificate.p12 \| pbcopy`. |
| `DEVELOPER_ID_CERTIFICATE_PASSWORD` | The password you gave the `.p12`. |
| `NOTARY_KEY` | An App Store Connect API key's `.p8` file, pasted as is. Make one under Users and Access → Integrations → App Store Connect API, with the Developer role. |
| `NOTARY_KEY_ID` | That key's ID. |
| `NOTARY_ISSUER` | The issuer ID shown above the keys. |

## Scripts

| | |
|---|---|
| `scripts/dmg.sh` | Archives, signs, packages and optionally notarizes the app. |
| `scripts/proto.sh` | Regenerates the Swift protobuf code. |
| `scripts/build-nylon.sh` | Build phase: nylon from the submodule, universal, into `Contents/Helpers/nylon`. |
| `scripts/check-proto.sh` | Build phase: fails if the generated protobuf code is stale. |
| `scripts/app-icon.sh` | Build phase: the app icon from nylon's logo. |

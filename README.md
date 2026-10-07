# Nylon Mac App

A menu bar app that lists the nodes in your [nylon](https://github.com/encodeous/nylon) network.

## Install

For Apple Silicon Macs on macOS 14 or later.

1. Open `Nylon.dmg` and drag Nylon onto Applications.
2. Open Nylon. Apple hasn't notarized the app, so macOS blocks it the first time. Go to System Settings → Privacy & Security, find "Nylon was blocked", and click Open Anyway. Or clear the block from a terminal:

   ```bash
   xattr -dr com.apple.quarantine /Applications/Nylon.app
   ```

3. Nylon opens its Settings window the first time. Click "Choose…" and pick your `central.yaml`. The app remembers it. To change it later, click the nylon icon in the menu bar, then "Settings…".

4. For latency, turn on nylon's metrics endpoint. Add this to `node.yaml` and restart nylon:

   ```yaml
   observability_addr: 127.0.0.1:9090
   ```

   Without it the menu says "Not running". If nylon listens somewhere else, change "Metrics URL" in Settings. The app doesn't need root.

`Packaging/package.sh` builds the DMG and writes it to `dist/Nylon.dmg`.

## Run it from source

1. Install the Command Line Tools if you don't have them: `xcode-select --install`
2. From this folder, build and start it:

   ```bash
   swift build -c release && .build/release/Nylon
   ```

3. Follow steps 3 and 4 of Install.

To skip Settings, pass the file: `.build/release/Nylon -central /path/to/central.yaml`. With no file chosen, it reads `central.yaml` in the current directory, like `nylon run`. If nylon serves metrics somewhere else, pass `-metrics http://127.0.0.1:<port>/metrics`.

## Try it without nylon

`.dev/` has a fake network and a fake nylon `/metrics` that returns new latencies on every request. From this folder, in two terminals:

```bash
python3 .dev/fake-metrics.py
```

```bash
.dev/run.sh .dev/central.yaml -metrics http://127.0.0.1:9091/metrics
```

## Test

```bash
swift test -Xswiftc -plugin-path -Xswiftc "$(xcode-select -p)/usr/lib/swift/host/plugins/testing"
```

The `-plugin-path` flag is only needed without full Xcode.

# How nylon for Mac works

```
nylon.app (each user)  --XPC-->  nylon-helper (root)  --/var/run/nylon/<network>.sock-->  nylon (root), one per network
```

| Part | Where | What it does |
|---|---|---|
| The app | `nylon.app/Contents/MacOS/nylon` | The UI, running as the user. |
| The helper | `nylon.app/Contents/MacOS/nylon-helper` | Launch daemon, registered with `SMAppService` from `Contents/Library/LaunchDaemons/com.encodeous.nylon.helper.plist`. Runs the networks' nylons and answers the app over XPC. |
| nylon | `nylon.app/Contents/Helpers/nylon`, installed to `/Library/PrivilegedHelperTools/com.encodeous.nylon/nylon` | Built from the `nylon` submodule. The helper runs the installed copy, one process per network. Also the `nylon` command, if the user installs it. |

Code lives in `App/` (the app only), `Helper/` (the helper only) and `Shared/` (both, and the tests).

## Trust

The helper runs as root, so the question is who it obeys.

1. **Code signature.** The helper only accepts XPC connections from a program signed by its own team with the identifier `com.encodeous.nylon`, and the app only talks to a helper signed by its own team as `com.encodeous.nylon.helper` (`Shared/CodeSigning.swift`). Release builds also require Developer ID, which a developer's own Apple Development certificate doesn't meet, and no `get-task-allow` entitlement, so a debugger can't be attached to an app the helper trusts. Debug builds accept development-signed apps, to work from Xcode. Signed ad hoc, the helper has no team to check against, so it accepts no one.
2. **Pairing.** The app makes two P-256 keys in the Secure Enclave (`App/Helper/AppKeys.swift`); the private halves never leave the chip.
   - The *read* key signs requests that only look: state, status, config, probe, log.
   - The *write* key signs everything that changes anything, and needs Touch ID or the user's password every time it's used. The app reuses an approval for five minutes.

   Only administrators pair, because nylon's config can run commands as root (`pre_up`, `post_up` and the like in `node.yaml`), so whoever controls nylon has root anyway. The helper takes the caller's uid from the XPC connection, so the kernel's word, not the app's, and checks it's in the `admin` group. Each pairing, the first after an install too, also needs an administrator's approval: the app asks for the `com.encodeous.nylon.admin` authorization right, which shows macOS's administrator prompt, and proves it holds the keys it's pairing by signing the request with its new read key (so there's no Touch ID prompt on top). The helper keeps the pairings in `/Library/Application Support/nylon/pairings.json`, one per user, each with both public keys, the user and when; only the user who made a pairing can use it. Changes also check the caller is still an administrator, so taking someone out of the admin group takes away their control. If the helper can't read its pairings file, nothing pairs and no request is accepted until uninstalling clears it.

   The admin right is never removed: anyone may create an authorization right that doesn't exist, so a removed one could be put back as "allow". The helper sets the right's rule at launch, checks the rule is still "administrator, every time" before trusting an approval, and refuses connections if it isn't. The rule keeps an approval good for 10 seconds and doesn't share it, so the helper can check the approval the app was just given, and nothing else can use it. With no time at all, the approval would expire before the helper checks it.
3. **Requests.** Before each request the app asks the helper for a challenge: 32 random bytes, good once, for a minute, on that connection only, with at most 16 open per connection. The request is JSON holding the challenge, its pairing's read key and the action, signed with that pairing's key for the action (`Shared/Signing.swift`). The helper checks the signature, then spends the challenge, so a captured request can't be replayed and a bad signature can't use up a challenge. For write actions the app gets Touch ID first and the challenge after, so a slow prompt can't outlast it. Pairing answers a challenge the same way.

4. **What runs as root.** The app belongs to the user who installed it, so the helper never runs the nylon inside it. It copies `Contents/Helpers/nylon` into `/Library/PrivilegedHelperTools/com.encodeous.nylon/`, owned by root, checks the copy is signed by its team as `com.encodeous.nylon.daemon` (the same rules as step 1), then moves it into place. Networks, `nylon verify` and the `nylon` command all use that copy. A new app version's nylon is installed the same way the next time the helper needs it, and one that fails the check never is.

This is meant to hold even if the team's signing certificate leaks: a program signed with it gets past step 1, but can't pair without an administrator, and can't change anything without a paired write key, which only exists in a Mac's Secure Enclave and needs the user each time.

## Installing and removing the helper

- **Install:** the app registers the helper with `SMAppService`, the user allows it under Login Items, then pairs the app with an administrator's approval.
- **Unpair:** removes this app's pairing. The helper keeps running, for anyone else paired.
- **Uninstall:** needs an administrator, not a pairing, so any user can remove a helper someone else set up. The helper stops every network and removes every pairing, the installed nylon and its `/usr/local/bin/nylon` link, then exits, and the app unregisters it. Each network's config (its private key and `central.yaml`) and the logs stay, so installing again finds the networks; only pairing starts over. If the helper doesn't answer, the app unregisters it anyway and says the cleanup didn't happen.
- **App deleted:** the helper checks every minute that its app is still there. Gone two checks in a row (an update replaces the app for a moment), it stops its networks, removes the installed nylon and the `nylon` link, and exits; launchd can't start a helper whose binary is gone. Moving the app looks the same, so after moving it, open it to set the helper up again.
- **Helper crashed:** nylon runs in its own process group, so it outlives a helper that crashes or is killed. At launch the helper asks each of its networks' sockets which process serves it, and adopts the ones running its installed nylon. Stopping signals every network at once, then waits, inside launchd's 30 second `ExitTimeOut`.
- **Old helper:** if the helper's version isn't the app's, the app offers to update it, which unregisters and registers it again so launchd runs the new one.

By hand, if all else fails:

```bash
sudo launchctl bootout system/com.encodeous.nylon.helper
sudo rm "/Library/Application Support/nylon/pairings.json"
sudo rm -r /Library/PrivilegedHelperTools/com.encodeous.nylon
```

and `sudo rm /usr/local/bin/nylon` if it links there. Leave the `com.encodeous.nylon.admin` authorization right: it only ever asks for an administrator. That leaves the networks' config in `/Library/Application Support/nylon/networks` and the logs in `/Library/Logs/nylon`; delete those too only if you mean to lose the nodes' private keys.

## Networks

Each network the app runs is its own nylon daemon (its own `nylon run` process), named by its `node.yaml`'s `interface_name` (nylon's default is `nylon`). On macOS that isn't the name of an interface: nylon asks for a `utun` and the kernel picks the next free one, e.g. `utun4`, which nylon's status reports. nylon still names its IPC socket after `interface_name`, so it names the network, and `sudo nylon status -i <name>` reaches it. Two networks need different names because their sockets would clash.

- Config: `/Library/Application Support/nylon/networks/<name>/` (`central.yaml`, `node.yaml`, `settings.json` with start at boot). Root-only.
- Log: `/Library/Logs/nylon/<name>.log`, opened for appending; checked every minute, and past 10 MB copied to `.log.1` and emptied, so the running nylon carries on writing.
- Importing writes the files to a root-only staging folder, runs `nylon verify <central> --node <node>`, and only then installs them. It refuses a `node.yaml` whose `interface_name` a nylon running outside the app already serves, or whose `port` another network uses.
- The helper runs each network with `nylon run -c … -n …`, restarts it with backoff if it exits on its own, and stops them all when it's stopped.
- A socket in `/var/run/nylon` that answers, under a name that isn't one of the helper's networks, is a nylon started another way. It shows as a read-only network: status, but no config, log, start or stop.

## Logs

The app follows a network's log through the helper (`log(network:from:)`, read key, since it only looks). The helper reads `/Library/Logs/nylon/<name>.log` from a byte offset, or about the last 64 KB the first time, and returns whole lines, at most 1 MB, with the offset to ask from next (`Shared/LogChunk.swift`). If the log is now shorter than the offset, it was rotated or truncated, so the reply starts from its beginning and says so. The Activity tab asks once a second and keeps the last 5,000 lines. A nylon started outside the app logs wherever it was set up to, so the helper can't show it.

## The helper's XPC interface

`Shared/HelperProtocol.swift`. Five calls, all JSON:

- `hello` → version, and every pairing's read key (so an app can tell whether it's paired, and whether anyone is).
- `challenge` → a fresh challenge for one `pair` or `perform` on this connection.
- `pair(keys, challenge, proof, authorization)` → an error, or none; needs an administrator.
- `uninstall(authorization)` → stops every network and removes every pairing, keeping the networks' config; needs an administrator, no pairing.
- `perform(request, signature)` → the action's result, or an error.

| Action | Key | Returns |
|---|---|---|
| `state` | read | Every network and its status, and the `nylon` command's state |
| `status(network)` | read | nylon's `StatusResponse` |
| `central(network)` | read | The network's `central.yaml` |
| `node(network)` | write | The network's `node.yaml`, for the config editor. It holds the private key, so it needs the write key |
| `probe(network, peer)` | read | nylon's `ProbeResponse` |
| `log(network, from)` | read | A `LogChunk` |
| `start`, `stop`, `reload(network)` | write | State (`reload`: nylon's `ReloadResponse`) |
| `importConfig(central, node)` | write | State |
| `remove(network)` | write | State |
| `setStartAtBoot(network, on)` | write | State |
| `setCommandLineTool(installed)` | write | State |
| `unpair` | write | State; removes the pairing that signed it |

## Talking to nylon

nylon's IPC socket is `/var/run/nylon/<network>.sock`, root-only. Both sides send `NYLN` and a big-endian `uint16` version, then frames of a big-endian `uint32` length and that many bytes of protobuf (`nylon/protocol/nylon_ipc.proto`). The helper opens a connection per request (`Shared/NylonIPC.swift`).

## The `nylon` command

"Install the nylon command" makes `/usr/local/bin/nylon` a link to the installed nylon, so the CLI is the same version as the daemons. The helper won't touch a `/usr/local/bin/nylon` that isn't such a link. nylon's sockets are root-only, so the command needs sudo; it doesn't go through the helper.

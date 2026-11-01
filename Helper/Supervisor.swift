import Foundation

// The networks on this Mac: the ones the helper runs, each in its own folder, and any nylon started another way,
// which it only reads from. Everything runs on queue.
final class Supervisor {
    let queue = DispatchQueue(label: "nylon.supervisor")
    private var networks: [String: Network] = [:]
    private var housekeeping: DispatchSourceTimer?

    init() {
        let folders = (try? FileManager.default.contentsOfDirectory(at: Paths.networks, includingPropertiesForKeys: nil)) ?? []
        for folder in folders where !folder.lastPathComponent.hasPrefix(".")
            && FileManager.default.fileExists(atPath: folder.appendingPathComponent("node.yaml").path) {
            let name = folder.lastPathComponent
            networks[name] = Network(name: name, queue: queue)
        }
    }

    // At launch: take back our networks' nylons that are still running (the helper crashed or was killed, and they
    // weren't), start the networks set to start at boot, and rotate big logs every minute.
    func launched() {
        queue.async {
            try? self.installNylon()
            for network in self.networks.values {
                if let pid = NylonIPC.serverPID(Paths.socket(network.name)), executable(of: pid) == Paths.installedNylon.path {
                    network.adopt(pid)
                } else if network.startAtBoot {
                    try? self.start(network.name)
                }
            }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 60, repeating: 60)
            timer.setEventHandler { self.networks.values.forEach { $0.rotateLog() } }
            timer.resume()
            self.housekeeping = timer
        }
    }

    func state() -> HelperState {
        let ours = networks.values.map(\.state)
        let external = externalNetworks().map { HelperState.Network(name: $0, status: .external, startAtBoot: false) }
        return HelperState(networks: (ours + external).sorted { $0.name < $1.name }, commandLineTool: commandLineTool())
    }

    // The socket of a network's nylon, ours or external.
    func socket(_ name: String) throws -> URL {
        if let network = networks[name] {
            guard network.running else { throw Failure("\(name) isn't running.") }
        } else if !externalNetworks().contains(name) {
            throw Failure("There's no network called \(name).")
        }
        return Paths.socket(name)
    }

    func network(_ name: String) throws -> Network {
        guard let network = networks[name] else { throw Failure("The helper doesn't run a network called \(name).") }
        return network
    }

    func start(_ name: String) throws {
        let network = try network(name)
        guard !network.running else { return }
        if NylonIPC.answers(Paths.socket(name)) { throw Failure("A nylon started outside this app is already running \(name).") }
        try installNylon()
        try network.start()
    }

    // Stops every network at once: launchd gives the helper 20 seconds to exit, not 10 for each network.
    func stopAll() {
        networks.values.forEach { $0.beginStopping() }
        let deadline = Date().addingTimeInterval(10)
        networks.values.forEach { $0.finishStopping(by: deadline) }
    }

    // Uninstalling: stops every network and removes the pairings, the installed nylon and the nylon link. Each
    // network's config (its private key and central.yaml) and the logs stay, so installing again finds them; only
    // pairing starts over.
    func uninstall() {
        stopAll()
        removeInstalledNylon()
        try? FileManager.default.removeItem(at: Paths.pairings)
        try? FileManager.default.removeItem(at: Paths.staging)
    }

    // The app was deleted: removes the nylon command and the nylon the helper installed, keeping the config.
    func removeInstalledNylon() {
        if commandLineTool() == .installed { try? FileManager.default.removeItem(at: Paths.commandLineTool) }
        try? FileManager.default.removeItem(at: Paths.installedNylonFolder)
    }

    // Adds the network node names, or updates it. Only config nylon's own `nylon verify` accepts gets installed, and
    // only if it doesn't clash with another network. The network's folder is swapped in one step, and a network that
    // was running, or waiting to restart, starts again with the new config.
    func importConfig(central: Data, node: Data) throws {
        guard central.count < 1 << 20, node.count < 1 << 20 else { throw Failure("Config files are too large.") }
        try installNylon()
        try? FileManager.default.removeItem(at: Paths.staging)
        defer { try? FileManager.default.removeItem(at: Paths.staging) }
        let stagedCentral = Paths.staging.appendingPathComponent("central.yaml"), stagedNode = Paths.staging.appendingPathComponent("node.yaml")
        try Paths.writePrivate(central, to: stagedCentral)
        try Paths.writePrivate(node, to: stagedNode)
        try verify(central: stagedCentral, node: stagedNode)

        // nylon accepted interface_name, so it's a plain name; still, it becomes a path
        let config = try NodeConfig(yaml: String(decoding: node, as: UTF8.self))
        guard !config.interface.contains("/"), !config.interface.hasPrefix(".") else { throw Failure("Bad interface_name.") }
        if let conflict = networkConflict(config, with: networks.values.compactMap(\.config), external: externalNetworks()) {
            throw Failure(conflict)
        }

        let network = networks[config.interface] ?? Network(name: config.interface, queue: queue)
        let wasRunning = network.runningOrRestarting
        network.stop()
        try Paths.makePrivate(Paths.networks)
        let old = Paths.networks.appendingPathComponent(".\(network.name).old")
        try? FileManager.default.removeItem(at: old)
        if FileManager.default.fileExists(atPath: network.folder.path) {
            try? FileManager.default.copyItem(at: network.folder.appendingPathComponent("settings.json"),
                                              to: Paths.staging.appendingPathComponent("settings.json"))
            try FileManager.default.moveItem(at: network.folder, to: old)
        }
        try FileManager.default.moveItem(at: Paths.staging, to: network.folder)
        try? FileManager.default.removeItem(at: old)
        networks[network.name] = network
        if wasRunning {
            do { try network.start() } catch { throw Failure("Imported, but nylon didn't start: \(error)") }
        }
    }

    func remove(_ name: String) throws {
        let network = try network(name)
        network.stop()
        try FileManager.default.removeItem(at: network.folder)
        networks[name] = nil
    }

    // Links /usr/local/bin/nylon to the nylon the helper runs, so the CLI is always the same version as the daemons.
    func setCommandLineTool(installed: Bool) throws {
        let link = Paths.commandLineTool
        switch (commandLineTool(), installed) {
        case (.other(let path), _):
            throw Failure("\(path) is another nylon. Remove it first if you want this one.")
        case (.installed, false):
            try FileManager.default.removeItem(at: link)
        case (.notInstalled, true):
            try installNylon()
            try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: Paths.installedNylon)
        default:
            break
        }
    }

    private func commandLineTool() -> HelperState.CommandLineTool {
        let path = Paths.commandLineTool.path
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: path) else {
            return FileManager.default.fileExists(atPath: path) ? .other(path: path) : .notInstalled
        }
        return target == Paths.installedNylon.path ? .installed : .other(path: path)
    }

    // Copies the bundled nylon into installedNylon when it's changed, and checks the copy is signed by this team as
    // com.encodeous.nylon.daemon before putting it in place. The app belongs to a user, so the nylon that runs as root
    // is a copy only root can change. A bundled nylon that fails the check is never installed.
    private func installNylon() throws {
        let fm = FileManager.default
        let installed = try? Data(contentsOf: Paths.installedNylon)
        if let installed, installed == (try? Data(contentsOf: Paths.bundledNylon)) { return }
        do {
            guard let team = ownTeamID() else { throw Failure("The helper isn't signed with a team.") }
            for folder in [Paths.installedNylonFolder.deletingLastPathComponent(), Paths.installedNylonFolder] {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                try fm.setAttributes([.ownerAccountID: 0, .groupOwnerAccountID: 0, .posixPermissions: 0o755], ofItemAtPath: folder.path)
            }
            let copy = Paths.installedNylonFolder.appendingPathComponent(".nylon.new")
            try? fm.removeItem(at: copy)
            try fm.copyItem(at: Paths.bundledNylon, to: copy)
            try fm.setAttributes([.ownerAccountID: 0, .groupOwnerAccountID: 0, .posixPermissions: 0o755], ofItemAtPath: copy.path)
            guard isSigned(copy, identifier: "com.encodeous.nylon.daemon", team: team) else {
                try? fm.removeItem(at: copy)
                throw Failure("The nylon in the app isn't signed by this app's developer.")
            }
            guard rename(copy.path, Paths.installedNylon.path) == 0 else { throw Failure("Couldn't install nylon: \(String(cString: strerror(errno)))") }
        } catch where installed != nil {
            log("keeping the installed nylon: \(error)") // still runs the last good one
        }
    }

    // Names of nylons the helper didn't start: sockets that answer, other than our networks' names.
    private func externalNetworks() -> [String] {
        let sockets = (try? FileManager.default.contentsOfDirectory(at: Paths.sockets, includingPropertiesForKeys: nil)) ?? []
        return sockets.filter { $0.pathExtension == "sock" }.map { $0.deletingPathExtension().lastPathComponent }
            .filter { networks[$0] == nil && NylonIPC.answers(Paths.socket($0)) }
    }

    private func verify(central: URL, node: URL) throws {
        let process = Process()
        let output = Pipe()
        process.executableURL = Paths.installedNylon
        process.arguments = ["verify", central.path, "--node", node.path]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure("nylon rejected the config: \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }
}

// The path of pid's executable.
func executable(of pid: pid_t) -> String? {
    var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    return proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : nil
}

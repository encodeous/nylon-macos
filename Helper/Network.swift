import Foundation

// One network: its config folder, and the nylon the helper runs for it. Used only on the supervisor's queue.
final class Network {
    private struct Settings: Codable {
        var startAtBoot = false
    }

    let name: String // interface_name
    let folder: URL
    var central: URL { folder.appendingPathComponent("central.yaml") }
    var node: URL { folder.appendingPathComponent("node.yaml") }
    private var settingsFile: URL { folder.appendingPathComponent("settings.json") }
    private var log: URL { Paths.logs.appendingPathComponent("\(name).log") }
    private static let maxLog: UInt64 = 10 << 20 // past this, rotated to .log.1
    private let queue: DispatchQueue
    // The nylon running for this network: one the helper started (child), or one it found running at launch, e.g.
    // after the helper crashed, and watches by pid (adopted).
    private var child: Process?
    private var adopted: DispatchSourceProcess?
    private var pid: pid_t?
    private var startedAt = Date()
    private var stopping = false
    private var restartPending = false
    private var lastFailure: String?
    private var restarts = 0

    init(name: String, queue: DispatchQueue) {
        self.name = name
        self.queue = queue
        folder = Paths.networks.appendingPathComponent(name)
    }

    var running: Bool { pid != nil }
    var runningOrRestarting: Bool { pid != nil || restartPending }
    var config: NodeConfig? { (try? String(contentsOf: node, encoding: .utf8)).flatMap { try? NodeConfig(yaml: $0) } }

    var startAtBoot: Bool {
        (try? Data(contentsOf: settingsFile)).flatMap { try? decodeJSON(Settings.self, $0) }?.startAtBoot ?? false
    }

    func setStartAtBoot(_ on: Bool) throws {
        try Paths.writePrivate(encodeJSON(Settings(startAtBoot: on)), to: settingsFile)
    }

    var state: HelperState.Network {
        let status: HelperState.Network.Status
        if pid != nil {
            status = NylonIPC.answers(Paths.socket(name)) ? .running : .starting
        } else if let lastFailure {
            status = .failed(lastFailure)
        } else {
            status = .stopped
        }
        return HelperState.Network(name: name, status: status, startAtBoot: startAtBoot)
    }

    func start() throws {
        guard pid == nil else { return }
        stopping = false
        restartPending = false
        lastFailure = nil
        try launch()
    }

    // Takes over a nylon of ours that's already running, found by its socket.
    func adopt(_ pid: pid_t) {
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        source.setEventHandler { [weak self] in self?.exited(status: nil) }
        source.resume()
        adopted = source
        self.pid = pid
        startedAt = Date()
    }

    // Asks nylon to stop; it removes its routes and interface on SIGTERM. finishStopping waits for it.
    func beginStopping() {
        stopping = true
        restartPending = false
        restarts = 0
        lastFailure = nil
        if let pid { kill(pid, SIGTERM) }
    }

    // Waits for nylon to exit until deadline, then kills it.
    func finishStopping(by deadline: Date) {
        guard let pid else { return }
        while alive(pid) && Date() < deadline { usleep(50_000) }
        if alive(pid) { kill(pid, SIGKILL) }
        forget()
    }

    func stop() {
        beginStopping()
        finishStopping(by: Date().addingTimeInterval(10))
    }

    func logChunk(from: UInt64?) throws -> LogChunk {
        try readLog(log, from: from)
    }

    // Copies a big log to .log.1 and empties it. nylon writes in append mode, so it carries on at the new end.
    func rotateLog() {
        guard let size = try? FileManager.default.attributesOfItem(atPath: log.path)[.size] as? UInt64, size > Self.maxLog else { return }
        let old = log.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: old)
        guard (try? FileManager.default.copyItem(at: log, to: old)) != nil else { return }
        truncate(log.path, 0)
    }

    private func launch() throws {
        try FileManager.default.createDirectory(at: Paths.logs, withIntermediateDirectories: true)
        rotateLog()
        let fd = open(log.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw Failure("Couldn't open \(log.path): \(String(cString: strerror(errno)))") }
        let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let process = Process()
        process.executableURL = Paths.installedNylon
        process.arguments = ["run", "-c", central.path, "-n", node.path]
        process.currentDirectoryURL = folder
        process.standardOutput = output
        process.standardError = output
        process.terminationHandler = { [weak self] p in self?.queue.async { if p === self?.child { self?.exited(status: p.terminationStatus) } } }
        try process.run()
        child = process
        pid = process.processIdentifier
        startedAt = Date()
    }

    // nylon exited without being asked to: try again, waiting longer each time, in case the network comes back.
    private func exited(status: Int32?) {
        let ranFor = Date().timeIntervalSince(startedAt)
        forget()
        if stopping { return }
        if ranFor > 5 * 60 { restarts = 0 } // a crash after a long run starts the backoff over
        lastFailure = "nylon exited\(status.map { " with status \($0)" } ?? ""). \(lastLogLine())"
        scheduleRestart()
    }

    private func scheduleRestart() {
        restarts += 1
        restartPending = true
        queue.asyncAfter(deadline: .now() + min(pow(2, Double(restarts)), 60)) { [weak self] in
            guard let self, self.restartPending, self.pid == nil else { return }
            self.restartPending = false
            do {
                try self.launch()
            } catch {
                self.lastFailure = "Couldn't start nylon: \(error)"
                self.scheduleRestart()
            }
        }
    }

    private func forget() {
        adopted?.cancel()
        adopted = nil
        child = nil
        pid = nil
    }

    private func alive(_ pid: pid_t) -> Bool {
        if let child { return child.isRunning }
        return kill(pid, 0) == 0
    }

    private func lastLogLine() -> String {
        guard let file = try? FileHandle(forReadingFrom: log) else { return "" }
        defer { try? file.close() }
        let size = (try? file.seekToEnd()) ?? 0
        try? file.seek(toOffset: size - min(size, 4096))
        let tail = String(decoding: (try? file.readToEnd()) ?? Data(), as: UTF8.self)
        return tail.split(separator: "\n").last.map(String.init) ?? ""
    }
}

import Foundation

// nylon-helper: started by launchd as root, for the nylon app's XPC connections and to start nylon at boot.

let supervisor = Supervisor()

// Only the nylon app signed by the same team gets in. Signed ad hoc, the helper can't tell its app from any other
// program, so it lets nothing in.
final class Listener: NSObject, NSXPCListenerDelegate {
    let team = ownTeamID()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard let team else {
            log("refusing connection: the helper isn't signed with a team")
            return false
        }
        // An approval of the admin right only means something while its rule still asks for an administrator.
        guard Pairings.rightIsIntact() else {
            log("refusing connection: the admin right isn't what the helper set")
            return false
        }
        connection.setCodeSigningRequirement(signingRequirement(identifier: Helper.appIdentifier, team: team))
        connection.exportedInterface = NSXPCInterface(with: HelperXPC.self)
        connection.exportedObject = Session(uid: connection.effectiveUserIdentifier)
        connection.resume()
        return true
    }
}

// One app connection. Each request answers a challenge the helper issued on it, so a captured one can't be replayed.
// Everything runs on supervisor.queue.
final class Session: NSObject, HelperXPC {
    private let uid: uid_t // the macOS user on the other end, as the kernel says
    private var challenges = Challenges()

    init(uid: uid_t) {
        self.uid = uid
    }

    // Whether they're an administrator is looked up each time, so taking someone out of the admin group takes effect.
    private var caller: Caller { Caller(uid: uid, isAdministrator: isAdministrator(uid)) }

    func hello(reply: @escaping (Data) -> Void) {
        supervisor.queue.async {
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
            reply((try? encodeJSON(HelperHello(version: version, paired: (Pairings.load() ?? []).map(\.keys.read)))) ?? Data())
        }
    }

    func challenge(reply: @escaping (Data) -> Void) {
        supervisor.queue.async { reply(self.challenges.issue()) }
    }

    func pair(keys keysData: Data, challenge: Data, proof: Data, authorization: Data, reply: @escaping (String?) -> Void) {
        supervisor.queue.async {
            do {
                let keys = try decodeJSON(PairingKeys.self, keysData)
                try checkPairing(keys: keys, keysData: keysData, challenge: challenge, proof: proof, challenges: &self.challenges,
                                 caller: self.caller, approved: Pairings.authorized(authorization))
                try Pairings.add(Pairing(keys: keys, uid: self.uid, user: userName(self.uid), since: Date()))
                log("paired an app for \(userName(self.uid))")
                reply(nil)
            } catch {
                reply("\(error)")
            }
        }
    }

    func uninstall(authorization: Data, reply: @escaping (String?) -> Void) {
        supervisor.queue.async {
            guard Pairings.authorized(authorization) else { return reply("An administrator has to approve uninstalling.") }
            supervisor.uninstall()
            log("uninstalled by \(userName(self.uid))")
            reply(nil)
            // Exit rather than keep serving with no pairings, even if the app fails to unregister the helper.
            supervisor.queue.asyncAfter(deadline: .now() + 1) { exit(0) }
        }
    }

    func perform(request: Data, signature: Data, reply: @escaping (Data?, String?) -> Void) {
        supervisor.queue.async {
            do {
                let (pairing, action) = try checkRequest(request, signature: signature, challenges: &self.challenges,
                                                         pairings: Pairings.load() ?? [], caller: self.caller)
                reply(try self.run(action, for: pairing), nil)
            } catch {
                reply(nil, "\(error)")
            }
        }
    }

    // Runs on supervisor.queue.
    private func run(_ action: HelperAction, for pairing: Pairing) throws -> Data {
        switch action {
        case .state: break
        case .status(let network): return try nylon(network, .with { $0.status = .init() }).status.serializedData()
        case .probe(let network, let peer):
            return try nylon(network, .with { $0.probe = .with { $0.peerID = peer } }).probe.serializedData()
        case .reload(let network): return try nylon(network, .with { $0.reload = .init() }).reload.serializedData()
        case .central(let network): return try Data(contentsOf: supervisor.network(network).central) // not an external one's
        case .node(let network): return try Data(contentsOf: supervisor.network(network).node)
        case .log(let network, let from): return try encodeJSON(supervisor.network(network).logChunk(from: from))
        case .start(let network): try supervisor.start(network)
        case .stop(let network): try supervisor.network(network).stop()
        case .setStartAtBoot(let network, let on): try supervisor.network(network).setStartAtBoot(on)
        case .importConfig(let central, let node): try supervisor.importConfig(central: central, node: node)
        case .remove(let network): try supervisor.remove(network)
        case .setCommandLineTool(let installed): try supervisor.setCommandLineTool(installed: installed)
        case .unpair: try Pairings.remove(pairing)
        }
        return try encodeJSON(supervisor.state())
    }

    private func nylon(_ network: String, _ request: Proto_IpcRequest) throws -> Proto_IpcResponse {
        try NylonIPC.request(supervisor.socket(network), request)
    }
}

func userName(_ uid: uid_t) -> String {
    getpwuid(uid).map { String(cString: $0.pointee.pw_name) } ?? "uid \(uid)"
}

func log(_ message: String) {
    FileHandle.standardError.write(Data("nylon-helper: \(message)\n".utf8))
}

Pairings.registerRight()
supervisor.launched()

// The helper runs from inside nylon.app. If the app is deleted, stop its networks and exit rather than run them with
// nothing left to stop them; launchd can't start a helper whose binary is gone. Two checks a minute apart, since an
// update replaces the app for a moment.
var missing = 0
let orphanCheck = DispatchSource.makeTimerSource(queue: supervisor.queue)
orphanCheck.schedule(deadline: .now() + 60, repeating: 60)
orphanCheck.setEventHandler {
    missing = FileManager.default.fileExists(atPath: Paths.helper.path) ? 0 : missing + 1
    guard missing >= 2 else { return }
    log("nylon.app is gone; stopping its networks and exiting")
    supervisor.stopAll()
    supervisor.removeInstalledNylon()
    exit(0)
}
orphanCheck.resume()

// launchd stops the helper with SIGTERM; stop the nylons too rather than leave them unwatched.
signal(SIGTERM, SIG_IGN)
let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: supervisor.queue)
term.setEventHandler {
    supervisor.stopAll()
    exit(0)
}
term.resume()

let delegate = Listener()
let listener = NSXPCListener(machServiceName: Helper.machService)
listener.delegate = delegate
listener.resume()
dispatchMain()

import CryptoKit
import Foundation
import Testing
@testable import NylonApp

// Software keys stand in for the Secure Enclave ones: same curve and signature format.
private struct Keys {
    let read = P256.Signing.PrivateKey()
    let write = P256.Signing.PrivateKey()
    var pairing: PairingKeys { PairingKeys(read: read.publicKey.x963Representation, write: write.publicKey.x963Representation) }
}

private let admin = Caller(uid: 501, isAdministrator: true)

private func pairing(_ keys: Keys, uid: uid_t = 501) -> Pairing {
    Pairing(keys: keys.pairing, uid: uid, user: "user\(uid)", since: Date())
}

private func request(_ action: HelperAction, challenge: Data, from keys: Keys) -> Data {
    try! encodeJSON(SignedRequest(challenge: challenge, pairing: keys.pairing.read, action: action))
}

private func sign(_ data: Data, with key: P256.Signing.PrivateKey) -> Data {
    try! key.signature(for: data).derRepresentation
}

// Checks action from keys' pairing, signed with key, against a fresh challenge.
private func check(_ action: HelperAction, from keys: Keys, signedWith key: P256.Signing.PrivateKey, pairings: [Pairing],
                   caller: Caller = admin) throws -> HelperAction {
    var challenges = Challenges()
    let data = request(action, challenge: challenges.issue(), from: keys)
    return try checkRequest(data, signature: sign(data, with: key), challenges: &challenges, pairings: pairings, caller: caller).1
}

@Test func acceptsSignedRequests() throws {
    let keys = Keys()
    #expect(try check(.status(network: "nylon"), from: keys, signedWith: keys.read, pairings: [pairing(keys)]) == .status(network: "nylon"))
    #expect(try check(.stop(network: "nylon"), from: keys, signedWith: keys.write, pairings: [pairing(keys)]) == .stop(network: "nylon"))
}

// The read key, which signs without Touch ID, can't change anything.
@Test func changesNeedTheWriteKey() {
    let keys = Keys()
    let changes: [HelperAction] = [.start(network: "nylon"), .stop(network: "nylon"), .reload(network: "nylon"),
                                   .importConfig(central: Data(), node: Data()), .remove(network: "nylon"),
                                   .setStartAtBoot(network: "nylon", true), .setCommandLineTool(installed: true), .unpair]
    for action in changes {
        #expect(throws: Failure("The app's signature doesn't match its pairing.")) {
            try check(action, from: keys, signedWith: keys.read, pairings: [pairing(keys)])
        }
    }
}

// Each paired app signs with its own keys, and the helper checks them against that pairing alone, used only by the
// user who made it.
@Test func servesEachPairing() throws {
    let alice = Keys(), bob = Keys(), mallory = Keys()
    let pairings = [pairing(alice), pairing(bob, uid: 502)]
    let bobCaller = Caller(uid: 502, isAdministrator: true)
    #expect(try check(.stop(network: "nylon"), from: bob, signedWith: bob.write, pairings: pairings, caller: bobCaller) == .stop(network: "nylon"))
    #expect(throws: Failure("This app isn't paired with the nylon helper.")) {
        try check(.status(network: "nylon"), from: bob, signedWith: bob.read, pairings: pairings) // bob's keys, used by alice
    }
    #expect(throws: Failure("The app's signature doesn't match its pairing.")) {
        try check(.stop(network: "nylon"), from: bob, signedWith: alice.write, pairings: pairings, caller: bobCaller) // alice's key, claiming bob's pairing
    }
    #expect(throws: Failure("This app isn't paired with the nylon helper.")) {
        try check(.status(network: "nylon"), from: mallory, signedWith: mallory.read, pairings: pairings)
    }
}

// Someone taken out of the admin group can still look, but not change anything.
@Test func changesNeedAnAdministrator() throws {
    let keys = Keys()
    let demoted = Caller(uid: 501, isAdministrator: false)
    #expect(try check(.status(network: "nylon"), from: keys, signedWith: keys.read, pairings: [pairing(keys)], caller: demoted) == .status(network: "nylon"))
    #expect(throws: Failure("Only an administrator's account can change nylon's networks.")) {
        try check(.stop(network: "nylon"), from: keys, signedWith: keys.write, pairings: [pairing(keys)], caller: demoted)
    }
}

// A challenge works once, only on the connection that issued it, and only for a minute.
@Test func challengesWorkOnce() {
    let keys = Keys()
    var challenges = Challenges()
    let used = "The request's challenge is used, expired or from another connection."
    let data = request(.status(network: "nylon"), challenge: challenges.issue(), from: keys)
    let signature = sign(data, with: keys.read)
    #expect(throws: Never.self) { try checkRequest(data, signature: signature, challenges: &challenges, pairings: [pairing(keys)], caller: admin) }
    #expect(throws: Failure(used)) { try checkRequest(data, signature: signature, challenges: &challenges, pairings: [pairing(keys)], caller: admin) } // replayed

    var other = Challenges()
    let elsewhere = request(.status(network: "nylon"), challenge: other.issue(), from: keys) // issued on another connection
    #expect(throws: Failure(used)) {
        try checkRequest(elsewhere, signature: sign(elsewhere, with: keys.read), challenges: &challenges, pairings: [pairing(keys)], caller: admin)
    }

    let start = Date()
    let old = challenges.issue(now: start)
    let expired = !challenges.spend(old, now: start.addingTimeInterval(Challenges.lifetime))
    let fresh = challenges.issue(now: start)
    let inTime = challenges.spend(fresh, now: start.addingTimeInterval(Challenges.lifetime - 1))
    #expect(expired && inTime)
}

// Only a few are open at once: issuing more forgets the oldest.
@Test func challengesAreFew() {
    var challenges = Challenges()
    let start = Date()
    let first = challenges.issue(now: start)
    let rest = (1...Challenges.limit).map { challenges.issue(now: start.addingTimeInterval(Double($0))) }
    let forgotten = !challenges.spend(first, now: start.addingTimeInterval(20))
    let kept = rest.map { challenges.spend($0, now: start.addingTimeInterval(20)) }
    #expect(forgotten && kept.allSatisfy { $0 })
}

// A bad signature doesn't use up the challenge, so someone without the keys can't spend it.
@Test func rejectsEditsWithoutSpendingTheChallenge() {
    let keys = Keys()
    var challenges = Challenges()
    let challenge = challenges.issue()
    let status = request(.status(network: "nylon"), challenge: challenge, from: keys)
    let probe = request(.probe(network: "nylon", peer: "bob"), challenge: challenge, from: keys) // changed after signing
    #expect(throws: Failure("The app's signature doesn't match its pairing.")) {
        try checkRequest(probe, signature: sign(status, with: keys.read), challenges: &challenges, pairings: [pairing(keys)], caller: admin)
    }
    #expect(throws: Never.self) { try checkRequest(status, signature: sign(status, with: keys.read), challenges: &challenges, pairings: [pairing(keys)], caller: admin) }
}

private func pair(_ keys: Keys, proofKey: P256.Signing.PrivateKey? = nil, caller: Caller = admin, approved: Bool = true) throws {
    var challenges = Challenges()
    let challenge = challenges.issue()
    let data = try encodeJSON(keys.pairing)
    let proof = sign(pairingMessage(challenge: challenge, keys: data), with: proofKey ?? keys.read)
    try checkPairing(keys: keys.pairing, keysData: data, challenge: challenge, proof: proof, challenges: &challenges,
                     caller: caller, approved: approved)
}

// Only an administrator's account pairs, with an administrator's approval each time, the first one too: nylon's
// config can run commands as root.
@Test func pairingNeedsAnAdministrator() {
    #expect(throws: Never.self) { try pair(Keys()) }
    #expect(throws: Failure("An administrator has to approve pairing.")) { try pair(Keys(), approved: false) }
    #expect(throws: Failure("Only an administrator's account can control nylon's helper.")) {
        try pair(Keys(), caller: Caller(uid: 502, isAdministrator: false))
    }
}

// The bundled nylon passes the check the helper makes before installing it; the wrong identifier doesn't.
@Test func checksNylonsSignature() throws {
    guard let team = ownTeamID() else { return } // signed ad hoc: there's no team to check against
    let nylon = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/nylon")
    #expect(isSigned(nylon, identifier: "com.encodeous.nylon.daemon", team: team))
    #expect(!isSigned(nylon, identifier: "com.encodeous.nylon", team: team))
    #expect(!isSigned(nylon, identifier: "com.encodeous.nylon.daemon", team: "ABCDE12345"))
    #expect(!isAdministrator(uid_t(bitPattern: -2))) // nobody
}

// The proof must come from the read key being paired, answering a challenge from this connection.
@Test func pairingNeedsItsOwnProof() {
    let keys = Keys()
    #expect(throws: Failure("The pairing request wasn't signed with its own read key.")) { try pair(keys, proofKey: Keys().read) }
    var challenges = Challenges()
    let challenge = randomBytes(32) // not issued here
    let data = try! encodeJSON(keys.pairing)
    #expect(throws: Failure("The pairing request's challenge is used, expired or from another connection.")) {
        try checkPairing(keys: keys.pairing, keysData: data, challenge: challenge,
                         proof: sign(pairingMessage(challenge: challenge, keys: data), with: keys.read), challenges: &challenges,
                         caller: admin, approved: true)
    }
    #expect(isPublicKey(keys.pairing.write) && !isPublicKey(Data(repeating: 4, count: 65)))
}

// The same bytes nylon's Go side expects (nylon/ipc/ipc.go).
@Test func framesLikeNylon() throws {
    #expect(NylonIPC.hello == Data([0x4e, 0x59, 0x4c, 0x4e, 0x00, 0x01]))
    #expect(try NylonIPC.readHello(NylonIPC.hello) == 1)
    #expect(throws: Failure.self) { try NylonIPC.readHello(Data("errno=".utf8)) }

    let frame = try NylonIPC.frame(Proto_IpcRequest.with { $0.id = 1; $0.status = .init() }.serializedData())
    #expect(frame == Data([0, 0, 0, 4, 0x08, 0x01, 0x12, 0x00])) // what nylon's e2e test sends
    #expect(try NylonIPC.frameLength(frame.prefix(4)) == 4)
    #expect(throws: Failure.self) { try NylonIPC.frameLength(Data([0x01, 0x00, 0x00, 0x01])) }
}

@Test func readsNodeConfig() throws {
    #expect(try NodeConfig(yaml: "id: alice\nport: 57175\n").interface == "nylon")
    #expect(try NodeConfig(yaml: "id: alice\nport: 57175\ninterface_name: nylon-test\n") == NodeConfig(yaml: "port: 57175\ninterface_name: nylon-test"))
    #expect(try NodeConfig(yaml: "port: 57175\ninterface_name: \"\"\n").interface == "nylon") // empty means nylon's default too
    #expect(try NodeConfig(yaml: "port: 57175\ndns:\n  interface_name: nested\n").interface == "nylon") // not the top-level key
    #expect(try NodeConfig(yaml: "port: 51820\n").port == 51820)
    #expect(throws: (any Error).self) { try NodeConfig(yaml: "interface_name: [") }
    #expect(throws: (any Error).self) { try NodeConfig(yaml: "id: alice\n") } // nylon requires a port
}

// A second network needs its own interface_name and port; importing a network's config again updates it.
@Test func keepsNetworksApart() throws {
    let home = try NodeConfig(yaml: "port: 57175\n") // interface "nylon"
    let lab = try NodeConfig(yaml: "port: 57176\ninterface_name: lab\n")
    #expect(networkConflict(lab, with: [home], external: []) == nil)
    #expect(networkConflict(try NodeConfig(yaml: "port: 57180\n"), with: [home, lab], external: []) == nil) // updates home
    #expect(networkConflict(try NodeConfig(yaml: "port: 57175\ninterface_name: lab\n"), with: [home, lab], external: [])
        == "The network nylon already uses port 57175. Set a different port in node.yaml.")
    #expect(networkConflict(lab, with: [home], external: ["lab"])
        == "A nylon started outside this app already uses the interface lab. Set a different interface_name in node.yaml.")
}

import Foundation

// The helper: a launch daemon that runs as root, owns nylon, and does what an app asks if the app proves it holds the
// keys of one of its pairings.
enum Helper {
    static let machService = "com.encodeous.nylon.helper"
    static let plistName = "com.encodeous.nylon.helper.plist" // in nylon.app/Contents/Library/LaunchDaemons
    static let appIdentifier = "com.encodeous.nylon"
    static let helperIdentifier = "com.encodeous.nylon.helper"
    // The authorization right for what only an administrator may do: pair an app, and uninstall the helper. The app
    // shows the prompt, with its own wording for each.
    static let adminRight = "com.encodeous.nylon.admin"
}

// The XPC interface. Arguments and replies are JSON, so both sides share Codable types instead of NSSecureCoding.
@objc protocol HelperXPC {
    // HelperHello. Works for any caller the code signature check let in.
    func hello(reply: @escaping (Data) -> Void)
    // A fresh challenge for one pair or perform on this connection. It's good once, for a minute.
    func challenge(reply: @escaping (Data) -> Void)
    // PairingKeys, a challenge, proof (pairingMessage signed with the new read key), and an externalized
    // AuthorizationRef holding Helper.adminRight. Replies with an error, or nil.
    func pair(keys: Data, challenge: Data, proof: Data, authorization: Data, reply: @escaping (String?) -> Void)
    // An externalized AuthorizationRef holding Helper.adminRight. Stops every network and removes every user's
    // pairing, keeping the networks' config, so the app can unregister it. Needs no pairing. Replies with an error, or nil.
    func uninstall(authorization: Data, reply: @escaping (String?) -> Void)
    // A SignedRequest and its signature. Replies with the action's result, or an error.
    func perform(request: Data, signature: Data, reply: @escaping (Data?, String?) -> Void)
}

struct HelperHello: Codable {
    var version: String
    var paired: [Data] // each pairing's read key, so an app can tell whether it's paired, and whether anyone is
}

// Public keys, in X9.63 form, of the two Secure Enclave keys an app made.
struct PairingKeys: Codable, Equatable {
    var read: Data // signs requests that only look
    var write: Data // signs requests that change anything; needs Touch ID or the user's password
}

// An app the helper does what it asks: its keys, and the macOS user who paired it. Only that user can use it.
struct Pairing: Codable, Equatable {
    var keys: PairingKeys
    var uid: uid_t
    var user: String
    var since: Date
}

// The macOS user on the other end of an XPC connection, as the kernel says.
struct Caller {
    var uid: uid_t
    var isAdministrator: Bool
}

// What an app signs with its new read key to pair, proving it holds the keys it's pairing.
func pairingMessage(challenge: Data, keys: Data) -> Data {
    Data("nylon pairing".utf8) + challenge + keys
}

struct SignedRequest: Codable {
    var challenge: Data // from the helper, so a captured request can't be replayed
    var pairing: Data // the read key of the pairing whose keys signed it
    var action: HelperAction
}

// Most actions name a network by its interface_name, which also names its nylon's socket.
enum HelperAction: Codable, Equatable {
    case state // HelperState
    case status(network: String) // nylon's StatusResponse, as protobuf
    case central(network: String) // the central.yaml that network runs with
    case node(network: String) // its node.yaml, private key and all, so it needs the write key
    case probe(network: String, peer: String) // nylon's ProbeResponse, as protobuf
    case log(network: String, from: UInt64?) // LogChunk: the log from an offset, or its last 64 KB when from is nil
    case start(network: String)
    case stop(network: String)
    case reload(network: String)
    case importConfig(central: Data, node: Data) // adds the network node.yaml names, or updates it
    case remove(network: String)
    case setStartAtBoot(network: String, Bool)
    case setCommandLineTool(installed: Bool)
    case unpair // removes the pairing that signed it

    // Anything that changes state needs the write key, so Touch ID or the user's password. Only looking doesn't.
    var needsWriteKey: Bool {
        switch self {
        case .state, .status, .central, .probe, .log: false
        case .node, .start, .stop, .reload, .importConfig, .remove, .setStartAtBoot, .setCommandLineTool, .unpair: true
        }
    }
}

struct HelperState: Codable, Equatable {
    struct Network: Codable, Equatable {
        enum Status: Codable, Equatable {
            case stopped, starting, running
            case external // a nylon the helper didn't start; it only reads from it
            case failed(String)
        }
        var name: String // interface_name
        var status: Status
        var startAtBoot: Bool
    }
    enum CommandLineTool: Codable, Equatable {
        case notInstalled, installed
        case other(path: String) // something else is at /usr/local/bin/nylon; the helper leaves it alone
    }
    var networks: [Network]
    var commandLineTool: CommandLineTool
}

struct Failure: LocalizedError, CustomStringConvertible, Equatable {
    let description: String
    init(_ description: String) { self.description = description }
    var errorDescription: String? { description }
}

func encodeJSON(_ value: some Encodable) throws -> Data { try JSONEncoder().encode(value) }
func decodeJSON<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T { try JSONDecoder().decode(type, from: data) }

func randomBytes(_ count: Int) -> Data { Data((0..<count).map { _ in .random(in: .min ... .max) }) }

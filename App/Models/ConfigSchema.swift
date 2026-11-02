import Foundation
import Network
import Yams

// What node.yaml and central.yaml may hold, for the editor's completions and checks. Written from nylon's config
// types (nylon/state/config.go, prefix_health.go) until nylon can generate it. nylon verify still has the last word
// when the helper installs a file.
indirect enum SchemaType {
    case string, bool, key, prefix, address, duration
    case integer(ClosedRange<Int>)
    case list(SchemaType)
    case object([String: SchemaField])
    case prefixHealth // a prefix entry, whose fields depend on its type

    var name: String {
        switch self {
        case .string: "text"
        case .bool: "true or false"
        case .key: "key"
        case .prefix: "IP prefix"
        case .address: "IP address"
        case .duration: "duration"
        case .integer: "number"
        case .list(let of): "list of \(of.name)"
        case .object, .prefixHealth: "map"
        }
    }
}

struct SchemaField {
    var type: SchemaType
    var doc: String
    var required = false
}

enum ConfigKind: String, Codable, Hashable {
    case node, central
    var fileName: String { "\(rawValue).yaml" }
}

enum ConfigSchema {
    static func root(_ kind: ConfigKind) -> [String: SchemaField] { kind == .node ? node : central }

    static let node: [String: SchemaField] = [
        "key": .init(type: .key, doc: "This node's private key", required: true),
        "id": .init(type: .string, doc: "Unique ID of this node", required: true),
        "port": .init(type: .integer(1...65535), doc: "UDP port nylon listens on", required: true),
        "use_system_routing": .init(type: .bool, doc: "All packets from peers come out of the nylon interface"),
        "no_tun": .init(type: .bool, doc: "Relay only, with no interface; needs no addresses or prefixes for this node in central.yaml"),
        "no_net_configure": .init(type: .bool, doc: "Don't configure system networking at all"),
        "dns_resolvers": .init(type: .list(.string), doc: "DNS resolvers for endpoints and config repos, as ip:port"),
        "interface_name": .init(type: .string, doc: "Names this network and its nylon socket. Changing it makes a new network"),
        "log_path": .init(type: .string, doc: "If set, nylon also logs to this file"),
        "observability_addr": .init(type: .string, doc: "HTTP address for /metrics, /healthz, /readyz and /discovery, e.g. 127.0.0.1:9090"),
        "unexclude_ips": .init(type: .list(.prefix), doc: "Split tunnel: removes these from the network's excluded ranges"),
        "exclude_ips": .init(type: .list(.prefix), doc: "Split tunnel: adds these to the network's excluded ranges"),
        "pre_up": .init(type: .list(.string), doc: "Commands run as root, in order, before the interface comes up"),
        "pre_down": .init(type: .list(.string), doc: "Commands run as root, in order, before the interface goes down"),
        "post_up": .init(type: .list(.string), doc: "Commands run as root, in order, after the interface comes up"),
        "post_down": .init(type: .list(.string), doc: "Commands run as root, in order, after the interface goes down"),
    ]

    private static let member: [String: SchemaField] = [
        "id": .init(type: .string, doc: "Unique node ID", required: true),
        "pubkey": .init(type: .key, doc: "The node's public key", required: true),
        "addresses": .init(type: .list(.address), doc: "The node's nylon addresses; the first is its primary"),
        "prefixes": .init(type: .list(.prefixHealth), doc: "Prefixes the node advertises"),
    ]

    static let central: [String: SchemaField] = [
        "dist": .init(type: .object([
            "key": .init(type: .key, doc: "Distribution public key, also a shared secret for the network", required: true),
            "repos": .init(type: .list(.string), doc: "Where nylon checks for newer config: file: paths or https URLs"),
        ]), doc: "How config updates are distributed"),
        "routers": .init(type: .list(.object(member.merging([
            "endpoints": .init(type: .list(.string), doc: "Where others can reach it: ip:port or a domain, re-resolved often"),
        ]) { a, _ in a })), doc: "Nodes that run nylon and route"),
        "clients": .init(type: .list(.object(member)), doc: "Plain WireGuard clients"),
        "graph": .init(type: .list(.string), doc: "Who peers with whom: \"a, b, c\" or groups like \"Group1 = a, b\""),
        "timestamp": .init(type: .integer(0...Int.max), doc: "Config version, set by nylon seal"),
        "exclude_ips": .init(type: .list(.prefix), doc: "Split tunnel: ranges excluded for the whole network"),
    ]

    // the fields of each prefix health type
    static let prefixTypes: [String: [String: SchemaField]] = [
        "static": [
            "prefix": .init(type: .prefix, doc: "The prefix to advertise", required: true),
            "metric": .init(type: .integer(0...Int(UInt32.max)), doc: "Metric to advertise it with"),
        ],
        "ping": [
            "prefix": .init(type: .prefix, doc: "The prefix to advertise", required: true),
            "addr": .init(type: .address, doc: "Address to ping", required: true),
            "max_failures": .init(type: .integer(1...Int(Int32.max)), doc: "Failures before it's withdrawn"),
            "delay": .init(type: .duration, doc: "Time between pings, e.g. 10s"),
            "bind_if": .init(type: .string, doc: "Local interface to ping from"),
            "metric": .init(type: .integer(0...Int(UInt32.max)), doc: "Fixed metric instead of the ping's round trip time"),
        ],
        "http": [
            "prefix": .init(type: .prefix, doc: "The prefix to advertise", required: true),
            "url": .init(type: .string, doc: "URL that must answer with success", required: true),
            "delay": .init(type: .duration, doc: "Time between checks"),
            "metric": .init(type: .integer(0...Int(UInt32.max)), doc: "Fixed metric instead of the request's duration"),
        ],
    ]

    // Every key the file can have, with its doc, for completions
    static func keys(_ kind: ConfigKind) -> [String: String] {
        var all: [String: String] = [:]
        func walk(_ fields: [String: SchemaField]) {
            for (name, field) in fields {
                all[name] = all[name] ?? field.doc
                walk(field.type)
            }
        }
        func walk(_ type: SchemaType) {
            switch type {
            case .object(let fields): walk(fields)
            case .list(let of): walk(of)
            case .prefixHealth:
                all["type"] = "static, ping or http"
                prefixTypes.values.forEach(walk)
            default: break
            }
        }
        walk(root(kind))
        return all
    }
}

struct ConfigProblem: Equatable {
    var line: Int // 1-based
    var message: String
}

// Checks text against the schema. Not a replacement for nylon verify, just quick feedback while typing.
enum ConfigValidator {
    static func validate(_ text: String, kind: ConfigKind) -> [ConfigProblem] {
        let node: Yams.Node?
        do {
            node = try Yams.compose(yaml: text)
        } catch let error as YamlError {
            return [problem(error)]
        } catch {
            return [ConfigProblem(line: 1, message: "\(error)")]
        }
        guard let node else { return [ConfigProblem(line: 1, message: "The file is empty")] }
        var problems: [ConfigProblem] = []
        check(node, against: .object(ConfigSchema.root(kind)), path: "", into: &problems)
        return problems.sorted { $0.line < $1.line }
    }

    private static func check(_ node: Yams.Node, against type: SchemaType, path: String, into problems: inout [ConfigProblem]) {
        let line = node.mark?.line ?? 1
        func fail(_ message: String) { problems.append(ConfigProblem(line: line, message: path.isEmpty ? message : "\(path): \(message)")) }
        if node.null != nil || node.scalar?.string.isEmpty == true {
            if case .list = type { return } // an empty list
            if case .string = type { return }
        }
        switch type {
        case .object(let fields):
            guard let mapping = node.mapping else { return fail("should be a map") }
            check(mapping, fields: fields, path: path, line: line, into: &problems)
        case .prefixHealth:
            guard let mapping = node.mapping else { return fail("should be a map") }
            let kind = mapping["type"]?.string ?? ""
            guard let fields = ConfigSchema.prefixTypes[kind] else {
                return fail(kind.isEmpty ? "needs a type: static, ping or http" : "type should be static, ping or http, not \(kind)")
            }
            check(mapping, fields: fields.merging(["type": SchemaField(type: .string, doc: "")]) { a, _ in a }, path: path, line: line, into: &problems)
        case .list(let of):
            guard let sequence = node.sequence else { return fail("should be a list") }
            for (i, item) in sequence.enumerated() { check(item, against: of, path: "\(path)[\(i)]", into: &problems) }
        default:
            guard let value = node.scalar?.string else { return fail("should be \(type.name)") }
            if let message = checkScalar(value, type) { fail(message) }
        }
    }

    private static func check(_ mapping: Yams.Node.Mapping, fields: [String: SchemaField], path: String, line: Int, into problems: inout [ConfigProblem]) {
        for (keyNode, value) in mapping {
            let key = keyNode.string ?? ""
            let at = path.isEmpty ? key : "\(path).\(key)"
            guard let field = fields[key] else {
                problems.append(ConfigProblem(line: keyNode.mark?.line ?? line, message: "Unknown key \(at)"))
                continue
            }
            check(value, against: field.type, path: at, into: &problems)
        }
        let present = Set(mapping.keys.compactMap(\.string))
        for (name, field) in fields where field.required && !present.contains(name) {
            problems.append(ConfigProblem(line: line, message: "Missing \(path.isEmpty ? name : "\(path).\(name)")"))
        }
    }

    private static func checkScalar(_ value: String, _ type: SchemaType) -> String? {
        switch type {
        case .string: return nil
        case .bool: return ["true", "false"].contains(value) ? nil : "should be true or false"
        case .integer(let range): return Int(value).map(range.contains) == true ? nil : "should be a number from \(range.lowerBound) to \(range.upperBound)"
        case .key: return Data(base64Encoded: value)?.count == 32 ? nil : "should be a base64 key"
        case .address: return isAddress(value) ? nil : "\(value) isn't an IP address"
        case .prefix: return isPrefix(value) ? nil : "should be an IP prefix like 10.20.0.0/16"
        case .duration:
            // Go's duration syntax, and more than zero (nylon rejects a zero delay)
            guard value.range(of: #"^(\d+(\.\d+)?(ns|us|µs|ms|s|m|h))+$"#, options: .regularExpression) != nil else { return "should be a duration like 10s" }
            return value.contains(where: { ("1"..."9").contains($0) }) ? nil : "should be more than zero"
        default: return "should be \(type.name)"
        }
    }

    // Like Go's netip: IPv4 is four plain decimal parts (no "10.1", no leading zeros), IPv6 has no zone
    private static func isAddress(_ value: String) -> Bool {
        if value.contains(":") { return !value.contains("%") && IPv6Address(value) != nil }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { part in
            guard let n = Int(part), (0...255).contains(n), part.allSatisfy(\.isASCII) else { return false }
            return part == "0" || !part.hasPrefix("0")
        }
    }

    // Like netip.ParsePrefix: an address, a slash and a length that fits it
    private static func isPrefix(_ value: String) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let bits = Int(parts[1]) else { return false }
        guard isAddress(String(parts[0])) else { return false }
        return (0...(parts[0].contains(":") ? 128 : 32)).contains(bits)
    }

    private static func problem(_ error: YamlError) -> ConfigProblem {
        switch error {
        case .scanner(_, let problem, let mark, _), .parser(_, let problem, let mark, _):
            return ConfigProblem(line: mark.line, message: problem.prefix(1).uppercased() + problem.dropFirst())
        default:
            return ConfigProblem(line: 1, message: "\(error)")
        }
    }
}

import Foundation
import Yams

// The parts of central.yaml the app shows: who's in the network, what each node owns, and where updates come from.
struct CentralSummary: Equatable {
    struct Node: Equatable {
        var id: String
        var prefixes: [String] // its addresses as /32 or /128, and the prefixes it advertises
    }

    var nodes: [Node] // routers, then clients
    var routers: Int
    var clients: Int
    var repos: [String]
    var timestamp: Int64

    private struct File: Decodable {
        struct Member: Decodable {
            struct Prefix: Decodable { var prefix: String? }
            var id: String
            var addresses: [String]?
            var prefixes: [Prefix]?
        }
        struct Dist: Decodable { var repos: [String]? }
        var routers: [Member]?
        var clients: [Member]?
        var dist: Dist?
        var timestamp: Int64?
    }

    init(yaml: String) throws {
        let file = try YAMLDecoder().decode(File.self, from: yaml)
        let routers = file.routers ?? [], clients = file.clients ?? []
        // like nylon's expandNodeAddresses: each address is also a prefix the node advertises
        nodes = (routers + clients).map { member in
            let addresses = (member.addresses ?? []).map { $0.contains(":") ? "\($0)/128" : "\($0)/32" }
            return Node(id: member.id, prefixes: addresses + (member.prefixes ?? []).compactMap(\.prefix))
        }
        self.routers = routers.count
        self.clients = clients.count
        repos = file.dist?.repos ?? []
        timestamp = file.timestamp ?? 0
    }
}

// How much of the network this node can reach. A node is reachable when this one has a usable route to any prefix it
// owns. Routes are matched by prefix, not by the router that advertises them, since a gateway advertises its clients'
// prefixes under its own ID. Nodes that own no prefix can't be checked, so they aren't counted.
struct NetworkHealth: Equatable {
    var reachable: Int
    var total: Int
    var reached: [String]
    var unreachable: [String]
    var unchecked: [String] // nodes with no address or prefix to route to

    // A gateway holds a sleeping passive client's prefixes at INFM/2 (nylon's core/router_algo.go), so a route at or
    // past it doesn't mean the node can be reached.
    private static let heldMetric = Format.infiniteMetric / 2

    var healthy: Bool { reachable == total }

    init(status: Proto_StatusResponse, central: CentralSummary) {
        let me = status.node.nodeID
        let usable = Set(status.routes.selected.filter { $0.pubRoute.fd.metric < Self.heldMetric }.map(\.pubRoute.source.prefix))
        let others = central.nodes.filter { $0.id != me }
        unchecked = others.filter(\.prefixes.isEmpty).map(\.id)
        let checked = others.filter { !$0.prefixes.isEmpty }
        let unreachable = checked.filter { !$0.prefixes.contains(where: usable.contains) }.map(\.id)
        self.unreachable = unreachable
        reached = checked.map(\.id).filter { !unreachable.contains($0) }
        total = checked.count
        reachable = reached.count
    }

    var summary: String {
        "\(reachable) of \(total) nodes reachable"
    }

    // for hover help
    var detail: String {
        var parts: [String] = []
        if !unreachable.isEmpty { parts.append("Can't reach \(unreachable.joined(separator: ", "))") }
        if !unchecked.isEmpty { parts.append("Not counted, no address: \(unchecked.joined(separator: ", "))") }
        return parts.joined(separator: ". ")
    }
}

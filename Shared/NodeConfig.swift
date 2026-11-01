import Foundation
import Yams

// The parts of node.yaml the helper needs to keep networks apart: interface_name, which names the network and its
// nylon's IPC socket, and port, which two nylons can't share.
struct NodeConfig: Decodable, Equatable {
    private let interfaceName: String?
    let port: UInt16
    private enum CodingKeys: String, CodingKey { case interfaceName = "interface_name", port }

    init(yaml: String) throws {
        self = try YAMLDecoder().decode(NodeConfig.self, from: yaml)
    }

    // nylon's default when it's unset or empty (nylon/core/nylon.go)
    var interface: String { interfaceName.flatMap { $0.isEmpty ? nil : $0 } ?? "nylon" }
}

// Why new can't join the networks already on this Mac, or nil if it can. A network with new's interface is the one
// being updated, so it doesn't count; external is the interfaces of nylons the helper didn't start.
func networkConflict(_ new: NodeConfig, with networks: [NodeConfig], external: [String]) -> String? {
    if external.contains(new.interface) {
        return "A nylon started outside this app already uses the interface \(new.interface). Set a different interface_name in node.yaml."
    }
    if let other = networks.first(where: { $0.interface != new.interface && $0.port == new.port }) {
        return "The network \(other.interface) already uses port \(new.port). Set a different port in node.yaml."
    }
    return nil
}

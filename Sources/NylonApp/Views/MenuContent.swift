import AppKit
import SwiftUI

struct MenuContent: View {
    @ObservedObject var store: NodeStore
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text(store.peers == nil ? "Not running, or observability_addr isn't set" : "Running")
        if let nodes = store.nodes {
            ForEach(nodes, id: \.name) { NodeRow(node: $0, peer: store.peers?[$0.name]) }
        } else {
            Text("Can't read \(store.path)")
        }
        Divider()
        Button("Settings…") { showSettings(openSettings) }
        Button("Quit") { NSApplication.shared.terminate(nil) }
    }
}

// A node's name, IP and, for a peer, its latency or whether it's connected. Clicking it copies the IP.
struct NodeRow: View {
    let node: Node
    let peer: Peer? // nil when the node isn't a peer of this one, e.g. this device itself

    var body: some View {
        Button(label) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(node.address ?? "", forType: .string)
        }
        .disabled(node.address == nil)
    }

    private var label: String {
        var label = "\(node.name)  \(node.address ?? "no address")"
        if let peer { label += "  \(statusText(peer))" }
        return label
    }
}

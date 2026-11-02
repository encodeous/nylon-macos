import SwiftUI

// The network at a glance: this node, its totals, its peers and what it advertises.
struct OverviewTab: View {
    let status: Proto_StatusResponse
    let live: NodeStore.Live

    var body: some View {
        let node = status.node
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Card {
                    Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 14) {
                        GridRow {
                            Fact(label: "Node", value: node.nodeID)
                            Fact(label: "Address", value: addresses, mono: true)
                            Fact(label: "Interface", value: "\(node.interface) · UDP \(node.listenPort)", mono: true)
                        }
                        GridRow {
                            Fact(label: "Public key", value: node.publicKey, mono: true, copyable: true).gridCellColumns(2)
                            Fact(label: "Config version", value: Format.configVersion(node.configTimestamp))
                        }
                    }
                    .padding(16)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    if let health = live.health {
                        StatTile(label: "Reachable", value: "\(health.reachable) of \(health.total)",
                                 help: health.detail.isEmpty ? "Nodes this node has a route to" : health.detail)
                    }
                    StatTile(label: "Peers", value: "\(node.stats.neighbourCount)", help: "Nodes connected directly to this one")
                    StatTile(label: "Sent", value: Format.bytes(node.stats.txBytes), help: "Total sent since nylon started")
                    StatTile(label: "Received", value: Format.bytes(node.stats.rxBytes), help: "Total received since nylon started")
                }

                TitledGroup("Peers") {
                    PeersTable(peers: status.neighbours)
                }

                TitledGroup("Advertised by this node") {
                    AdvertisementsTable(advertisements: node.advertised, seqnos: node.seqnos)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // this node's own /32s and /128s, which nylon advertises for its addresses
    private var addresses: String {
        let own = status.node.advertised.map(\.prefix).filter { $0.hasSuffix("/32") || $0.hasSuffix("/128") }
            .map { String($0.split(separator: "/")[0]) }
        return own.isEmpty ? "—" : own.joined(separator: ", ")
    }
}

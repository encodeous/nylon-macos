import SwiftUI

// Each peer: its endpoints, which one nylon uses, and the routes it advertises. Probing asks nylon to try every
// endpoint now.
struct PeersTab: View {
    let store: NodeStore
    let network: String
    let status: Proto_StatusResponse
    @State private var selection: String?
    @State private var probes: [String: Proto_ProbeResponse] = [:] // by peer
    @State private var probing = false
    @State private var probeError: String?

    // A plain stack, not an HSplitView: AppKit's split view runs up under the toolbar, where the rest of the tabs don't
    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(status.neighbours, id: \.peerID) { peer in
                        PeerListRow(peer: peer, selected: peer.peerID == selection) { selection = peer.peerID }
                    }
                }
                .padding(8)
            }
            .frame(width: 210)
            Divider()
            if let peer = status.neighbours.first(where: { $0.peerID == selection }) {
                detail(peer)
            } else {
                ContentUnavailableView("No Peer Selected", systemImage: "person.2")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { if selection == nil { selection = status.neighbours.first?.peerID } }
        .onChange(of: selection) { probeError = nil }
    }

    private func detail(_ peer: Proto_NeighbourInfo) -> some View {
        let probe = probes[peer.peerID]
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(peer.peerID).font(.title2.weight(.semibold))
                            if peer.passiveClient { Tag(text: "Client", color: .orange, help: "Connects to this node; nylon doesn't dial it") }
                        }
                        Fact(label: "Public key", value: peer.publicKey, mono: true, copyable: true)
                    }
                    Spacer()
                    Button(probe == nil ? "Probe Endpoints" : "Probe Again", systemImage: "dot.radiowaves.left.and.right") { run(peer.peerID) }
                        .disabled(probing)
                        .help("Try every endpoint of \(peer.peerID) now")
                }
                if let probeError { Text(probeError).foregroundStyle(.red).textSelection(.enabled) }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    StatTile(label: "Latency", value: Format.latency(peer.bestMetric), help: "Metric \(Format.metric(peer.bestMetric))")
                    StatTile(label: "Last handshake", value: Format.ago(unix: peer.transport.handshakeUnix), help: "When the tunnel last renewed its keys")
                    StatTile(label: "Sent", value: Format.bytes(peer.transport.txBytes), help: "Sent to \(peer.peerID)")
                    StatTile(label: "Received", value: Format.bytes(peer.transport.rxBytes), help: "Received from \(peer.peerID)")
                }

                TitledGroup("Endpoints") {
                    EndpointsTable(peer: peer, probe: probe)
                }

                TitledGroup("Advertised routes") {
                    RoutesTable(rows: peer.routes.map(RouteRow.init), highlight: peer.peerID)
                }

                if !peer.advertised.isEmpty {
                    TitledGroup("Advertised to \(peer.peerID)") {
                        AdvertisementsTable(advertisements: peer.advertised)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
    }

    private func run(_ peer: String) {
        probing = true
        Task {
            do {
                probes[peer] = try await store.probe(network, peer: peer)
                probeError = nil
            } catch {
                probeError = "\(error)"
            }
            probing = false
        }
    }
}

private struct PeerListRow: View {
    let peer: Proto_NeighbourInfo
    let selected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 2) {
                Text(peer.peerID).fontWeight(.medium)
                Text(peer.passiveClient ? "Client" : Format.latency(peer.bestMetric))
                    .font(.caption)
                    .foregroundStyle(selected ? Color.white.opacity(0.85) : .secondary)
            }
            .foregroundStyle(selected ? Color.white : .primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

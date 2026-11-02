import SwiftUI

// The tabs' tables: native, so they sort by a column's real value (latency by metric, sizes by bytes), alternate row
// backgrounds like Finder, and show or hide columns from the header's right-click menu. Extra columns start hidden.
// Columns' ideal widths are small on purpose: a table starts at the sum of them and only stretches to fill, never
// squeezes, so a big ideal on a many-column table pushes it past the window.

// The inset table style's measured row and header heights, and the inset above its rows (there's none below); a table
// in a tab that scrolls is as tall as its rows
private let rowHeight: CGFloat = 24
private let headerHeight: CGFloat = 28
private let rowsInset: CGFloat = 5

extension View {
    // A table that's one part of a scrolling tab: full width, as tall as its rows, scrolling with the tab
    func stackedTable(rows: Int) -> some View {
        tableStyle(.inset)
            .alternatingRowBackgrounds()
            .scrollDisabled(true)
            .frame(height: headerHeight + rowsInset + rowHeight * CGFloat(max(rows, 1)) + 1)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor)))
    }
}

private func mono(_ text: String) -> some View {
    Text(text).font(.system(.body, design: .monospaced))
}

private func metricText(_ metric: UInt32) -> some View {
    Text(Format.metric(metric)).foregroundStyle(Format.isReachable(metric) ? .primary : Color.orange)
}

// MARK: peers

struct PeerRow: Identifiable {
    var id: String
    var client: String
    var metric: UInt32
    var handshake: Int64
    var sent: UInt64
    var received: UInt64
    var key: String
    var endpoints: Int
    var activeEndpoints: Int
    var prefixes: Int // prefixes the peer itself advertises
    var addresses: String
    var seqno: UInt32
    var transportEndpoint: String

    init(_ peer: Proto_NeighbourInfo) {
        id = peer.peerID
        client = peer.passiveClient ? "Client" : "Router"
        metric = peer.bestMetric
        handshake = peer.transport.handshakeUnix
        sent = peer.transport.txBytes
        received = peer.transport.rxBytes
        key = peer.publicKey
        endpoints = peer.endpoints.count
        activeEndpoints = peer.endpoints.filter(\.active).count
        let own = peer.routes.filter { $0.pubRoute.source.nodeID == peer.peerID }
        prefixes = own.count
        addresses = own.map(\.pubRoute.source.prefix).filter { $0.hasSuffix("/32") || $0.hasSuffix("/128") }
            .map { String($0.split(separator: "/")[0]) }.joined(separator: ", ")
        seqno = own.map(\.pubRoute.fd.seqno).max() ?? 0
        transportEndpoint = peer.transport.hasEndpoint ? peer.transport.endpoint : ""
    }
}

struct PeersTable: View {
    let peers: [Proto_NeighbourInfo]
    @State private var order = [KeyPathComparator(\PeerRow.id)]
    @State private var columns = TableColumnCustomization<PeerRow>()

    var body: some View {
        let rows = peers.map(PeerRow.init).sorted(using: order)
        Table(rows, sortOrder: $order, columnCustomization: $columns) {
            Group {
                TableColumn("Peer", value: \PeerRow.id) { Text($0.id).fontWeight(.medium) }
                .width(min: 60, ideal: 80)
                    .customizationID("peer")
                TableColumn("Latency", value: \PeerRow.metric) { Text(Format.latency($0.metric)).help("Metric \(Format.metric($0.metric))") }
                .width(min: 50, ideal: 60)
                    .alignment(.trailing).customizationID("latency")
                TableColumn("Metric", value: \PeerRow.metric) { metricText($0.metric) }
                .width(min: 50, ideal: 60)
                    .alignment(.trailing).customizationID("metric")
                TableColumn("Last handshake", value: \PeerRow.handshake) { Text(Format.ago(unix: $0.handshake)) }
                .width(min: 60, ideal: 80)
                    .customizationID("handshake")
                TableColumn("Sent", value: \PeerRow.sent) { Text(Format.bytes($0.sent)) }
                .width(min: 50, ideal: 60)
                    .alignment(.trailing).customizationID("sent")
                TableColumn("Received", value: \PeerRow.received) { Text(Format.bytes($0.received)) }
                .width(min: 50, ideal: 60)
                    .alignment(.trailing).customizationID("received")
            }
            Group {
                TableColumn("Kind", value: \PeerRow.client) { Text($0.client) }
                .width(min: 60, ideal: 80).customizationID("kind").defaultVisibility(.hidden)
                TableColumn("Addresses", value: \PeerRow.addresses) { mono($0.addresses) }
                .width(min: 90, ideal: 120)
                    .customizationID("addresses").defaultVisibility(.hidden)
                TableColumn("Prefixes", value: \PeerRow.prefixes) { Text("\($0.prefixes)") }
                .width(min: 50, ideal: 60)
                    .alignment(.trailing).customizationID("prefixes").defaultVisibility(.hidden)
                TableColumn("Seqno", value: \PeerRow.seqno) { Text("\($0.seqno)") }
                .width(min: 50, ideal: 60)
                    .alignment(.trailing).customizationID("seqno").defaultVisibility(.hidden)
                TableColumn("Endpoints", value: \PeerRow.endpoints) { Text("\($0.activeEndpoints) of \($0.endpoints) active") }
                .width(min: 60, ideal: 80)
                    .customizationID("endpoints").defaultVisibility(.hidden)
                TableColumn("Transport endpoint", value: \PeerRow.transportEndpoint) { mono($0.transportEndpoint) }
                .width(min: 90, ideal: 120)
                    .customizationID("transport").defaultVisibility(.hidden)
                TableColumn("Public key", value: \PeerRow.key) { mono($0.key) }
                .width(min: 90, ideal: 120)
                    .customizationID("key").defaultVisibility(.hidden)
            }
        }
        .stackedTable(rows: rows.count)
    }
}

// MARK: advertisements

struct AdvertisementRow: Identifiable {
    var id: String { "\(router) \(prefix)" }
    var prefix: String
    var router: String
    var metric: UInt32
    var expiry: Int64
    var state: String
    var seqno: UInt32
}

struct AdvertisementsTable: View {
    let advertisements: [Proto_Advertisement]
    var seqnos: [Proto_SeqnoEntry] = []
    @State private var order = [KeyPathComparator(\AdvertisementRow.prefix)]
    @State private var columns = TableColumnCustomization<AdvertisementRow>()

    var body: some View {
        let rows = advertisements.map { adv in
            AdvertisementRow(prefix: adv.prefix, router: adv.nodeID, metric: adv.metric, expiry: adv.expiryUnix,
                             state: adv.passiveHold ? "Passive hold" : "Advertised",
                             seqno: seqnos.first { $0.prefix == adv.prefix }?.seqno ?? 0)
        }.sorted(using: order)
        Table(rows, sortOrder: $order, columnCustomization: $columns) {
            TableColumn("Prefix", value: \AdvertisementRow.prefix) { mono($0.prefix) }
                .width(min: 90, ideal: 120).customizationID("prefix")
            TableColumn("Metric", value: \AdvertisementRow.metric) { metricText($0.metric) }
                .width(min: 50, ideal: 60).alignment(.trailing).customizationID("metric")
            TableColumn("Expires", value: \AdvertisementRow.expiry) { Text(Format.expiry(unix: $0.expiry)) }
                .width(min: 60, ideal: 80).customizationID("expires")
            TableColumn("State", value: \AdvertisementRow.state) { Text($0.state).foregroundStyle($0.state == "Advertised" ? Color.green : .orange) }
                .width(min: 90, ideal: 120)
                .customizationID("state")
            TableColumn("Router", value: \AdvertisementRow.router) { Text($0.router) }
                .width(min: 60, ideal: 80).customizationID("router").defaultVisibility(.hidden)
            TableColumn("Seqno", value: \AdvertisementRow.seqno) { Text("\($0.seqno)") }
                .width(min: 50, ideal: 60)
                .alignment(.trailing).customizationID("seqno").defaultVisibility(.hidden)
        }
        .stackedTable(rows: rows.count)
    }
}

// MARK: endpoints

struct EndpointRow: Identifiable {
    var id: Int // its place in nylon's list: the same address can be listed twice, configured and remote
    var address: String
    var resolved: String
    var metric: UInt32
    var rtt: Int64
    var stableRTT: Int64
    var state: String
    var active: Bool
    var probe: String
    var probeOK: Bool
}

struct EndpointsTable: View {
    let peer: Proto_NeighbourInfo
    let probe: Proto_ProbeResponse?
    @State private var order = [KeyPathComparator(\EndpointRow.metric)]
    @State private var columns = TableColumnCustomization<EndpointRow>()

    var body: some View {
        let best = peer.bestEndpoint
        let rows = peer.endpoints.enumerated().map { index, endpoint in
            var words = [endpoint.active ? "Active" : "Inactive"]
            if endpoint == best { words.append("best") }
            if endpoint.remoteInit { words.append("remote") }
            let result = probe?.results.first { $0.address == endpoint.address }
            return EndpointRow(id: index, address: endpoint.address, resolved: endpoint.hasResolved ? endpoint.resolved : "Unresolved",
                               metric: endpoint.metric, rtt: endpoint.filteredRttNs, stableRTT: endpoint.stabilizedRttNs,
                               state: words.joined(separator: ", "), active: endpoint.active,
                               probe: probeText(result), probeOK: result?.status == .endpointProbeReplied)
        }.sorted(using: order)
        Table(rows, sortOrder: $order, columnCustomization: $columns) {
            TableColumn("Address", value: \EndpointRow.address) { mono($0.address) }
                .width(min: 90, ideal: 120).customizationID("address")
            TableColumn("Resolved", value: \EndpointRow.resolved) { mono($0.resolved) }
                .width(min: 90, ideal: 120).customizationID("resolved")
            TableColumn("Metric", value: \EndpointRow.metric) { metricText($0.metric) }
                .width(min: 50, ideal: 60).alignment(.trailing).customizationID("metric")
            TableColumn("RTT", value: \EndpointRow.rtt) { Text(Format.duration(nanoseconds: $0.rtt)) }
                .width(min: 50, ideal: 60)
                .alignment(.trailing).customizationID("rtt")
            TableColumn("Stable RTT", value: \EndpointRow.stableRTT) { Text(Format.duration(nanoseconds: $0.stableRTT)).help("The round trip time nylon routes by") }
                .width(min: 50, ideal: 60)
                .alignment(.trailing).customizationID("stable")
            // a probe's result joins the state, rather than a column of its own that's empty until you probe
            TableColumn("State", value: \EndpointRow.state) { row in
                Text(row.probe.isEmpty ? row.state : "\(row.state) · \(row.probe)")
                    .foregroundStyle(row.active && (row.probe.isEmpty || row.probeOK) ? Color.green : .orange)
            }
            .width(min: 90, ideal: 120)
            .customizationID("state")
        }
        .stackedTable(rows: rows.count)
    }

    private func probeText(_ result: Proto_EndpointProbeResult?) -> String {
        switch result?.status {
        case .endpointProbeReplied: "probe OK, \(Format.duration(nanoseconds: result!.latencyNs))"
        case .endpointProbeTimeout: "probe timed out"
        case .endpointProbeSendError: "probe send error"
        case .endpointProbeResolveError: "probe resolve error"
        default: "" // not probed yet
        }
    }
}

// MARK: routes

struct RouteRow: Identifiable {
    var id: String { "\(router) \(prefix) \(via)" }
    var prefix: String
    var via: String
    var router: String
    var seqno: UInt32
    var metric: UInt32
    var expiry: Int64
    var retractedBy: String
}

// A peer's routes (via is empty), or the routes nylon selected (via is the next hop)
struct RoutesTable: View {
    let rows: [RouteRow]
    var showVia = false
    var highlight: String? // a peer's own prefixes stand out among those it passes on
    @State private var order = [KeyPathComparator(\RouteRow.prefix)]
    @State private var columns = TableColumnCustomization<RouteRow>()

    var body: some View {
        let rows = rows.sorted(using: order)
        Table(rows, sortOrder: $order, columnCustomization: $columns) {
            Group {
                TableColumn("Prefix", value: \RouteRow.prefix) { row in
                    mono(row.prefix).foregroundStyle(row.router == highlight ? Color.green : .primary)
                }
                .width(min: 90, ideal: 120)
                .customizationID("prefix")
                TableColumn("Via", value: \RouteRow.via) { Text($0.via.isEmpty ? "None" : $0.via).foregroundStyle($0.via.isEmpty ? .secondary : .primary) }
                .width(min: 60, ideal: 80)
                    .customizationID("via").defaultVisibility(showVia ? .automatic : .hidden)
                TableColumn("Router", value: \RouteRow.router) { Text($0.router) }
                .width(min: 60, ideal: 80).customizationID("router")
                TableColumn("Seqno", value: \RouteRow.seqno) { Text("\($0.seqno)") }
                .width(min: 50, ideal: 60).alignment(.trailing).customizationID("seqno")
                TableColumn("Metric", value: \RouteRow.metric) { metricText($0.metric) }
                .width(min: 50, ideal: 60)
                    .alignment(.trailing).customizationID("metric")
            }
            Group {
                TableColumn("Expires", value: \RouteRow.expiry) { Text(Format.expiry(unix: $0.expiry)) }
                .width(min: 60, ideal: 80)
                    .customizationID("expires").defaultVisibility(showVia ? .hidden : .automatic)
                TableColumn("Retracted by", value: \RouteRow.retractedBy) { Text($0.retractedBy) }
                .width(min: 90, ideal: 120).customizationID("retracted").defaultVisibility(.hidden)
            }
        }
        .stackedTable(rows: rows.count)
    }
}

extension RouteRow {
    init(_ route: Proto_SelRoute) {
        self.init(prefix: route.pubRoute.source.prefix, via: route.nh, router: route.pubRoute.source.nodeID,
                  seqno: route.pubRoute.fd.seqno, metric: route.pubRoute.fd.metric, expiry: route.expireAtUnix,
                  retractedBy: route.retractedBy.joined(separator: ", "))
    }

    init(_ route: Proto_NeighRoute) {
        self.init(prefix: route.pubRoute.source.prefix, via: "", router: route.pubRoute.source.nodeID,
                  seqno: route.pubRoute.fd.seqno, metric: route.pubRoute.fd.metric, expiry: route.expireAtUnix, retractedBy: "")
    }

    init(_ distance: Proto_FeasibilityDistance) {
        self.init(prefix: distance.source.prefix, via: "", router: distance.source.nodeID, seqno: distance.fd.seqno,
                  metric: distance.fd.metric, expiry: 0, retractedBy: "")
    }
}

// MARK: small tables

struct NextHopRow: Identifiable {
    var id: String { prefix }
    var prefix: String
    var nextHop: String
}

// The forward and exit tables: where each prefix goes next
struct NextHopTable: View {
    let entries: [Proto_RouteTableEntry]
    @State private var order = [KeyPathComparator(\NextHopRow.prefix)]

    var body: some View {
        let rows = entries.map { NextHopRow(prefix: $0.prefix, nextHop: $0.blackhole ? "Blackhole" : $0.nh) }.sorted(using: order)
        Table(rows, sortOrder: $order) {
            TableColumn("Prefix", value: \NextHopRow.prefix) { mono($0.prefix) }
                .width(min: 90, ideal: 120)
            TableColumn("Next hop", value: \NextHopRow.nextHop) { row in
                Text(row.nextHop).foregroundStyle(row.nextHop == "Blackhole" ? Color.red : .primary)
                    .help(row.nextHop == "Blackhole" ? "Dropped: no usable route" : "")
            }
                .width(min: 60, ideal: 80)
        }
        .stackedTable(rows: rows.count)
    }
}

struct SeqnoRow: Identifiable {
    var id: String { prefix }
    var prefix: String
    var seqno: UInt32
}

struct SeqnosTable: View {
    let seqnos: [Proto_SeqnoEntry]
    @State private var order = [KeyPathComparator(\SeqnoRow.prefix)]

    var body: some View {
        let rows = seqnos.map { SeqnoRow(prefix: $0.prefix, seqno: $0.seqno) }.sorted(using: order)
        Table(rows, sortOrder: $order) {
            TableColumn("Prefix", value: \SeqnoRow.prefix) { mono($0.prefix) }
                .width(min: 90, ideal: 120)
            TableColumn("Seqno", value: \SeqnoRow.seqno) { Text("\($0.seqno)") }
                .width(min: 50, ideal: 60).alignment(.trailing)
        }
        .stackedTable(rows: rows.count)
    }
}

import Foundation

// A pretend helper, for working on the UI without the real one: launch the app with `-fake YES` (the "nylon (fake)"
// scheme does). Its networks answer with made-up status, config and a log that grows. It needs no signing, so it
// works in ad hoc builds.
@MainActor
final class FakeHelper {
    private var networks = [
        HelperState.Network(name: "homelab", status: .running, startAtBoot: true),
        HelperState.Network(name: "nylon", status: .external, startAtBoot: false),
        HelperState.Network(name: "work", status: .stopped, startAtBoot: false),
    ]
    private var commandLineTool = HelperState.CommandLineTool.notInstalled
    private var configs: [String: (central: String, node: String)] = [
        "homelab": (FakeHelper.central, FakeHelper.node(id: "charlie", interface: "homelab", port: 57175)),
        "work": (FakeHelper.central, FakeHelper.node(id: "charlie", interface: "work", port: 57176)),
    ]

    func perform(_ action: HelperAction) throws -> Data {
        switch action {
        case .state, .unpair: break
        case .status(let name):
            guard network(name)?.isUp == true else { throw Failure("\(name) isn't running.") }
            return try Self.status(interface: name).serializedData()
        case .central(let name):
            guard let config = configs[name] else { throw Failure("The helper doesn't run a network called \(name).") }
            return Data(config.central.utf8)
        case .node(let name):
            guard let config = configs[name] else { throw Failure("The helper doesn't run a network called \(name).") }
            return Data(config.node.utf8)
        case .probe(_, let peer):
            let endpoints = Self.status(interface: "").neighbours.first { $0.peerID == peer }?.endpoints ?? []
            return try Proto_ProbeResponse.with {
                $0.results = endpoints.map { endpoint in
                    .with {
                        $0.address = endpoint.address
                        if endpoint.hasResolved { $0.resolved = endpoint.resolved }
                        $0.status = endpoint.active ? .endpointProbeReplied : .endpointProbeTimeout
                        $0.latencyNs = endpoint.filteredRttNs - 400_000
                    }
                }
            }.serializedData()
        case .reload: return try Proto_ReloadResponse.with { $0.result = .applied }.serializedData()
        case .log(_, let from): // a line a second, like a quiet nylon
            let line = "time=\(Date().ISO8601Format()) level=INFO msg=\(from == nil ? "\"nylon started\"" : "\"probe\" peer=bob rtt=31.0ms")\n"
            return try encodeJSON(LogChunk(text: line, next: (from ?? 0) + 1, restarted: false))
        case .importConfig(let central, let node):
            let config = try NodeConfig(yaml: String(decoding: node, as: UTF8.self))
            configs[config.interface] = (String(decoding: central, as: UTF8.self), String(decoding: node, as: UTF8.self))
            if network(config.interface) == nil {
                networks.append(.init(name: config.interface, status: .stopped, startAtBoot: false))
            }
        case .stop(let name): set(name) { $0.status = .stopped }
        case .start(let name):
            set(name) { $0.status = .starting }
            Task { // like nylon bringing its interface up
                try? await Task.sleep(for: .seconds(2))
                self.set(name) { if $0.status == .starting { $0.status = .running } }
            }
        case .remove(let name):
            networks.removeAll { $0.name == name }
            configs[name] = nil
        case .setStartAtBoot(let name, let on): set(name) { $0.startAtBoot = on }
        case .setCommandLineTool(let installed): commandLineTool = installed ? .installed : .notInstalled
        }
        return try encodeJSON(HelperState(networks: networks.sorted { $0.name < $1.name }, commandLineTool: commandLineTool))
    }

    private func network(_ name: String) -> HelperState.Network? { networks.first { $0.name == name } }

    private func set(_ name: String, _ change: (inout HelperState.Network) -> Void) {
        if let i = networks.firstIndex(where: { $0.name == name }) { change(&networks[i]) }
    }

    private static func node(id: String, interface: String, port: Int) -> String {
        """
        key: 0NcrMcaS1tORCTA88L5ZPE+H6yUMV4e5vRp6iypnPW8=
        id: \(id)
        port: \(port)
        interface_name: \(interface)
        dns_resolvers:
          - 1.1.1.1:53
        exclude_ips:
          - 10.20.0.0/16
        post_up:
          - route add 192.168.50.0/24 -interface utun4

        """
    }

    private static let central = """
        dist:
          key: 7PaN6DmAayz4KnDnsXSXJH+Oy0TFGeoM4FEbQfLriVY=
          repos:
            - file:central.nybundle
            - https://static.example.com/network1.nybundle
        routers:
          - id: alice
            pubkey: xmfAovAKN4AY5ocK5s+/VsG9I27KrQ13Vzb0HOsLKAs=
            addresses: [10.0.0.1]
          - id: bob
            pubkey: 4GfHHSyVpXc+wkbjyIIONERa6Xf5EafB0nVGZLf2r2o=
            addresses: [10.0.0.2, 10.1.0.2]
            endpoints: ['192.168.1.1:57175', 'nylon.example.org']
          - id: eve
            pubkey: 2mXTTD+FYdtJm/v1vSHz8qimvCucjW9vY+nLYacXJFE=
            addresses: [10.0.0.3]
          - id: public
            pubkey: dJcUE1qnXCQ5x8pMhFb/MZab7YrBaaHcrgfbmQI0MW4=
            addresses: [10.0.0.4]
            endpoints: ['123.123.123.123:57175']
          - id: charlie
            pubkey: WcCkKijU0brYnRzxk867HTDyYFf/cqiKTTOLSxtWoFc=
            addresses: [10.0.0.5]
        clients:
          - id: client1
            pubkey: SBI+yvF30Ba4xo0GKTtKHSSfbXAnRNFTBwydJyJp6Rk=
            addresses: [10.0.0.7]
        exclude_ips:
          - 192.168.0.0/24
        graph:
          - alice, bob, eve, public, charlie, client1
        timestamp: 1740832962209309000

        """

    // A node with four peers, one of them a client, that reaches every node in central except eve's second route
    private static func status(interface: String) -> Proto_StatusResponse {
        let now = Int64(Date().timeIntervalSince1970)
        func endpoint(_ address: String, resolved: String? = nil, rtt: Int64?, remote: Bool = false) -> Proto_EndpointInfo {
            .with {
                $0.address = address
                if let resolved { $0.resolved = resolved }
                $0.active = rtt != nil
                $0.remoteInit = remote
                $0.metric = rtt.map { UInt32($0 / 1000) } ?? .max
                $0.filteredRttNs = rtt ?? 0
                $0.stabilizedRttNs = rtt ?? 0
            }
        }
        func route(_ prefix: String, _ router: String, seqno: UInt32, metric: UInt32, expires: Int64 = 180) -> Proto_NeighRoute {
            .with {
                $0.pubRoute = .with { $0.source = .with { $0.nodeID = router; $0.prefix = prefix }; $0.fd = .with { $0.seqno = seqno; $0.metric = metric } }
                $0.expireAtUnix = now + expires
            }
        }
        func peer(_ id: String, _ key: String, _ endpoints: [Proto_EndpointInfo], routes: [Proto_NeighRoute], handshake: Int64,
                  tx: UInt64, rx: UInt64, client: Bool = false) -> Proto_NeighbourInfo {
            .with {
                $0.peerID = id
                $0.publicKey = key
                $0.passiveClient = client
                $0.endpoints = endpoints
                $0.routes = routes
                $0.transport = .with {
                    $0.latestHandshakeUnix = (now - handshake) * 1_000_000_000 // nanoseconds, like nylon
                    $0.txBytes = tx
                    $0.rxBytes = rx
                    if let best = endpoints.first(where: \.active) { $0.endpoint = best.hasResolved ? best.resolved : best.address }
                }
            }
        }
        func selected(_ prefix: String, via: String, _ router: String, seqno: UInt32, metric: UInt32, expires: Int64 = 240,
                      retractedBy: [String] = []) -> Proto_SelRoute {
            .with {
                $0.pubRoute = .with { $0.source = .with { $0.nodeID = router; $0.prefix = prefix }; $0.fd = .with { $0.seqno = seqno; $0.metric = metric } }
                $0.nh = via
                $0.expireAtUnix = now + expires
                $0.retractedBy = retractedBy
            }
        }
        let advertised: [Proto_Advertisement] = [
            .with { $0.nodeID = "charlie"; $0.prefix = "10.0.0.5/32"; $0.metric = 0 },
            .with { $0.nodeID = "charlie"; $0.prefix = "192.168.50.0/24"; $0.metric = 0; $0.expiryUnix = now + 240 },
        ]
        return .with {
            $0.node = .with {
                $0.nodeID = "charlie"
                $0.interface = "utun4"
                $0.publicKey = "WcCkKijU0brYnRzxk867HTDyYFf/cqiKTTOLSxtWoFc="
                $0.listenPort = 57175
                $0.configTimestamp = 1740832962209309000
                $0.advertised = advertised
                $0.seqnos = [.with { $0.prefix = "10.0.0.5/32"; $0.seqno = 88 }, .with { $0.prefix = "192.168.50.0/24"; $0.seqno = 88 }]
                $0.stats = .with {
                    $0.neighbourCount = 4
                    $0.activeEndpointCount = 5
                    $0.selectedRouteCount = 9
                    $0.advertisedPrefixCount = 2
                    $0.txBytes = 1_288_490_188
                    $0.rxBytes = 3_650_722_201
                }
            }
            $0.neighbours = [
                peer("alice", "xmfAovAKN4AY5ocK5s+/VsG9I27KrQ13Vzb0HOsLKAs=", [endpoint("192.168.1.20:57175", rtt: 2_104_000)],
                     routes: [route("10.0.0.1/32", "alice", seqno: 1203, metric: 0), route("192.168.0.0/24", "alice", seqno: 1203, metric: 0),
                              route("10.0.0.3/32", "eve", seqno: 96, metric: 17_276)],
                     handshake: 12, tx: 859_832_320, rx: 3_113_851_289),
                peer("bob", "4GfHHSyVpXc+wkbjyIIONERa6Xf5EafB0nVGZLf2r2o=",
                     [endpoint("nylon.example.org", resolved: "203.0.113.7:57175", rtt: 31_012_000), endpoint("192.168.1.1:57175", rtt: nil),
                      endpoint("198.51.100.40:41822", rtt: 44_610_000, remote: true)],
                     routes: [route("10.0.0.2/32", "bob", seqno: 418, metric: 0), route("10.1.0.2/32", "bob", seqno: 418, metric: 0),
                              route("10.0.0.4/32", "public", seqno: 77, metric: 17_240)],
                     handshake: 48, tx: 224_395_264, rx: 408_944_640),
                peer("public", "dJcUE1qnXCQ5x8pMhFb/MZab7YrBaaHcrgfbmQI0MW4=", [endpoint("123.123.123.123:57175", rtt: 48_230_000)],
                     routes: [route("10.0.0.4/32", "public", seqno: 77, metric: 0)], handshake: 61, tx: 100_663_296, rx: 74_448_896),
                peer("client1", "SBI+yvF30Ba4xo0GKTtKHSSfbXAnRNFTBwydJyJp6Rk=", [endpoint("172.20.10.4:51820", rtt: 5_120_000, remote: true)],
                     routes: [], handshake: 190, tx: 12_582_912, rx: 41_943_040, client: true),
            ]
            $0.routes = .with {
                $0.selected = [
                    selected("10.0.0.1/32", via: "alice", "alice", seqno: 1203, metric: 2_104),
                    selected("192.168.0.0/24", via: "alice", "alice", seqno: 1203, metric: 2_104),
                    selected("10.0.0.2/32", via: "bob", "bob", seqno: 418, metric: 31_012, expires: 180),
                    selected("10.1.0.2/32", via: "bob", "bob", seqno: 418, metric: 31_012, expires: 180),
                    selected("10.0.0.3/32", via: "alice", "eve", seqno: 96, metric: 19_380, expires: 120),
                    selected("10.0.0.4/32", via: "public", "public", seqno: 77, metric: 48_230, expires: 120),
                    selected("10.0.0.7/32", via: "client1", "client1", seqno: 12, metric: 5_120, expires: 300),
                    selected("10.2.0.0/24", via: "", "alice", seqno: 1201, metric: .max, expires: 40, retractedBy: ["bob", "public"]),
                ]
                $0.forward = [
                    .with { $0.prefix = "10.0.0.1/32"; $0.nh = "alice" }, .with { $0.prefix = "10.0.0.2/32"; $0.nh = "bob" },
                    .with { $0.prefix = "10.0.0.3/32"; $0.nh = "alice" }, .with { $0.prefix = "10.0.0.4/32"; $0.nh = "public" },
                ]
                $0.exit = [.with { $0.prefix = "192.168.0.0/24"; $0.nh = "alice" }, .with { $0.prefix = "10.2.0.0/24"; $0.blackhole = true }]
            }
            $0.feasibilityDistances = [
                .with { $0.source = .with { $0.nodeID = "alice"; $0.prefix = "10.0.0.1/32" }; $0.fd = .with { $0.seqno = 1203; $0.metric = 2_104 } },
                .with { $0.source = .with { $0.nodeID = "bob"; $0.prefix = "10.0.0.2/32" }; $0.fd = .with { $0.seqno = 418; $0.metric = 31_012 } },
                .with { $0.source = .with { $0.nodeID = "alice"; $0.prefix = "10.2.0.0/24" }; $0.fd = .with { $0.seqno = 1201; $0.metric = 16_020 } },
            ]
        }
    }
}

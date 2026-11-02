import AppKit
import Foundation
import Testing
@testable import NylonApp

// Metrics read like the CLI: microseconds of round trip time, and INF at or above INFM.
@Test func formatsMetricsLikeNylon() {
    #expect(Format.latency(31_012) == "31.0 ms")
    #expect(Format.latency(250_400) == "250 ms")
    #expect(Format.metric(31_012) == 31_012.formatted())
    #expect(Format.metric(.max) == "INF")
    #expect(Format.metric(.max - 1) == "INF")
    #expect(Format.latency(.max) == "Unreachable")
}

// The best endpoint is the active one with the lowest metric, like nylon status.
@Test func picksTheBestEndpoint() {
    let peer = Proto_NeighbourInfo.with {
        $0.endpoints = [
            .with { $0.address = "a"; $0.active = false; $0.metric = 10 },
            .with { $0.address = "b"; $0.active = true; $0.metric = 50 },
            .with { $0.address = "c"; $0.active = true; $0.metric = 20 },
        ]
    }
    #expect(peer.bestEndpoint?.address == "c")
    #expect(Proto_NeighbourInfo().bestMetric == .max)
}

private func selected(_ prefix: String, from router: String, metric: UInt32) -> Proto_SelRoute {
    .with { $0.pubRoute = .with { $0.source = .with { $0.nodeID = router; $0.prefix = prefix }; $0.fd = .with { $0.metric = metric } } }
}

// A node is reachable when any prefix it owns has a usable route. Routes match by prefix: a gateway advertises its
// clients' prefixes under its own ID. Nodes with no prefix aren't counted, and this node isn't either.
@Test func countsReachableNodes() throws {
    let central = try CentralSummary(yaml: """
        routers:
          - id: me
            addresses: [10.0.0.1]
          - id: a
            addresses: [10.0.0.2]
          - id: b
            addresses: [10.0.0.3, "fd00::3"]
          - id: relay
        clients:
          - id: c
            addresses: [10.0.0.7]
          - id: sleeping
            prefixes:
              - type: static
                prefix: 192.168.9.0/24
        dist:
          repos: [file:central.nybundle]
        timestamp: 5
        """)
    #expect(central.nodes.map(\.id) == ["me", "a", "b", "relay", "c", "sleeping"])
    #expect(central.nodes[2].prefixes == ["10.0.0.3/32", "fd00::3/128"])
    #expect(central.repos == ["file:central.nybundle"])
    let status = Proto_StatusResponse.with {
        $0.node = .with { $0.nodeID = "me" }
        $0.routes = .with {
            $0.selected = [
                selected("10.0.0.2/32", from: "a", metric: 100),
                selected("10.0.0.3/32", from: "b", metric: .max), // retracted
                selected("10.0.0.7/32", from: "a", metric: 5), // a is c's gateway
                selected("192.168.9.0/24", from: "a", metric: Format.infiniteMetric / 2), // held for a sleeping client
            ]
        }
    }
    let health = NetworkHealth(status: status, central: central)
    #expect(health.total == 4)
    #expect(health.reached == ["a", "c"])
    #expect(health.unreachable == ["b", "sleeping"])
    #expect(health.unchecked == ["relay"])
    #expect(health.summary == "2 of 4 nodes reachable")
}

// nylon sends the last handshake in nanoseconds
@Test func readsHandshakeNanoseconds() {
    let stats = Proto_TransportPeerStats.with { $0.latestHandshakeUnix = 1_700_000_000_123_456_789 }
    #expect(stats.handshakeUnix == 1_700_000_000)
}

@Test func hidesAndRestoresThePrivateKey() {
    let key = "0NcrMcaS1tORCTA88L5ZPE+H6yUMV4e5vRp6iypnPW8="
    let yaml = "key: \(key) # mine\nid: a\npost_up:\n  - echo key: (hidden)\n"
    let (text, hidden) = PrivateKeyMask.hide(yaml)
    #expect(hidden == key)
    #expect(text == "key: (hidden) # mine\nid: a\npost_up:\n  - echo key: (hidden)\n")
    // only the key line gets it back; the same text in a hook stays as typed
    #expect(PrivateKeyMask.restore(text, key: hidden) == yaml)
    // a key typed in its place is kept
    #expect(PrivateKeyMask.restore("key: other\n", key: key) == "key: other\n")
    // an empty key line doesn't swallow the next one
    #expect(PrivateKeyMask.hide("key:\nid: a\n").key == nil)
}

@Test func makesNodeIDsNylonAccepts() {
    #expect(nodeIDFor("Adam’s MacBook Pro") == "adam-s-macbook-pro")
    #expect(nodeIDFor("lab.box_2") == "lab.box_2")
}

@Test func rejectsAddressesNylonRejects() {
    let base = "key: 0NcrMcaS1tORCTA88L5ZPE+H6yUMV4e5vRp6iypnPW8=\nid: a\nport: 1\nexclude_ips:\n"
    for bad in ["10.1/16", "010.0.0.0/8", "1.2.3.4/33", "fe80::1%en0/64"] {
        #expect(!ConfigValidator.validate(base + "  - \(bad)\n", kind: .node).isEmpty, "\(bad)")
    }
    for good in ["10.0.0.0/8", "fd00::/8", "0.0.0.0/0"] {
        #expect(ConfigValidator.validate(base + "  - \(good)\n", kind: .node).isEmpty, "\(good)")
    }
}

@Test func acceptsAValidNodeConfig() {
    let yaml = """
        key: 0NcrMcaS1tORCTA88L5ZPE+H6yUMV4e5vRp6iypnPW8=
        id: charlie
        port: 57175
        dns_resolvers: []
        exclude_ips:
          - 10.20.0.0/16
        post_up:
          - echo up
        """
    #expect(ConfigValidator.validate(yaml, kind: .node) == [])
}

@Test func reportsConfigProblemsByLine() {
    let yaml = """
        key: 0NcrMcaS1tORCTA88L5ZPE+H6yUMV4e5vRp6iypnPW8=
        id: charlie
        port: 70000
        exclude_ips:
          - 10.20.0/16
        obsrvability_addr: x
        """
    let problems = ConfigValidator.validate(yaml, kind: .node)
    #expect(problems.map(\.line) == [3, 5, 6])
    #expect(problems[1].message == "exclude_ips[0]: should be an IP prefix like 10.20.0.0/16")
    #expect(problems[2].message == "Unknown key obsrvability_addr")
}

@Test func checksPrefixHealthByType() {
    let yaml = """
        routers:
          - id: a
            pubkey: xmfAovAKN4AY5ocK5s+/VsG9I27KrQ13Vzb0HOsLKAs=
            prefixes:
              - type: ping
                prefix: 10.1.0.0/24
                addr: 10.1.0.8
                delay: 10s
              - type: http
                prefix: 10.2.0.0/24
        graph: []
        timestamp: 1
        """
    let problems = ConfigValidator.validate(yaml, kind: .central)
    #expect(problems.map(\.message) == ["Missing routers[0].prefixes[1].url"])
}

@Test func reportsBrokenYAML() {
    let problems = ConfigValidator.validate("id: [\nport: 1\n", kind: .node)
    #expect(problems.count == 1)
    #expect((1...3).contains(problems.first?.line ?? 0)) // libyaml marks where it gave up, which may be past the bracket
}

// nylon's log lines, as in its log file: colored level, dim node name, plain message
@Test func readsANSIColoredLogLines() {
    let line = ANSILine("\u{1B}[92mINF\u{1B}[0m \u{1B}[2mbabylon \u{1B}[0minit modules \u{1B}[2mname=\u{1B}[0mutun0")
    #expect(line.plain == "INF babylon init modules name=utun0")
    #expect(line.styled.string == line.plain)
    func color(at text: String) -> NSColor? {
        let at = (line.styled.string as NSString).range(of: text).location
        return line.styled.attribute(.foregroundColor, at: at, effectiveRange: nil) as? NSColor
    }
    #expect(color(at: "INF") == .systemGreen)
    #expect(color(at: "babylon") == .secondaryLabelColor)
    #expect(color(at: "init") == .textColor)
    #expect(ANSILine("no codes here").plain == "no codes here")
    let warning = ANSILine("\u{1B}[93mWRN\u{1B}[0m slow").styled
    #expect(warning.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == .systemOrange)
}

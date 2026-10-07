import AppKit

// What the menu shows. Views read it; where the data comes from stays in here.
// ObservableObject, since @State is a macro the Command Line Tools can't expand (no SwiftUI macro plugin).
@MainActor
final class NodeStore: ObservableObject {
    @Published private(set) var path = ""
    @Published private(set) var nodes: [Node]? // nil when central.yaml can't be read
    @Published private(set) var peers: [String: Peer]? // by node id; nil while nylon's /metrics doesn't answer
    // where nylon serves /metrics: node.yaml's observability_addr
    @Published var metricsURL: String {
        // save an edit, but not the text field handing back the same value: that would make a one-off `-metrics` stick
        didSet { if metricsURL != oldValue { UserDefaults.standard.set(metricsURL, forKey: "metrics") } }
    }

    // Each setting is the one saved in Settings or passed as `-central <path>` / `-metrics <url>` (both land in
    // UserDefaults), else nylon's default: ./central.yaml like `nylon run`, and port 9090.
    init() {
        metricsURL = UserDefaults.standard.string(forKey: "metrics") ?? "http://127.0.0.1:9090/metrics"
        load(UserDefaults.standard.string(forKey: "central") ?? "central.yaml")
        Task { await poll() }
    }

    // Picked in Settings, so remember it for the next launch.
    func choose(_ path: String) {
        UserDefaults.standard.set(path, forKey: "central")
        load(path)
    }

    private func load(_ path: String) {
        // absolute and with ~ expanded, so "Can't read" says where it looked
        self.path = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath).path
        nodes = try? readNodes(String(contentsOfFile: self.path, encoding: .utf8))
    }

    private func poll() async {
        while true {
            let latest = try? await fetch()
            // Updating rows under an open menu makes its highlight jump, so wait until it closes.
            if RunLoop.main.currentMode != .eventTracking { peers = latest }
            try? await Task.sleep(for: .seconds(5))
        }
    }

    private func fetch() async throws -> [String: Peer]? {
        guard let url = URL(string: metricsURL) else { return nil }
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 2) // always live numbers
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return readPeers(String(decoding: data, as: UTF8.self))
    }
}

// A peer's latency once nylon has measured one, else whether its WireGuard tunnel is up.
// nylon never measures passive clients, so for them the tunnel is the only sign they're online.
func statusText(_ peer: Peer, now: Date = Date()) -> String {
    if peer.metric < INFM { return String(format: "%.1fms", Double(peer.metric) / 1000) } // metric is in µs
    return now.timeIntervalSince1970 - peer.handshake < 180 ? "connected" : "offline" // WireGuard drops a session after 180s
}

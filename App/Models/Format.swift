import Foundation

// How nylon's numbers read in the app. Metric rules follow nylon's own (nylon/state/endpoint.go, cmd/render.go).
enum Format {
    // nylon's INFM: any metric at or above it is a retraction, which the CLI prints as INF
    static let infiniteMetric: UInt32 = .max - 1

    static func isReachable(_ metric: UInt32) -> Bool { metric < infiniteMetric }

    // The CLI's text for a metric
    static func metric(_ metric: UInt32) -> String {
        isReachable(metric) ? metric.formatted() : "INF"
    }

    // A link's metric is its stabilized round trip time in microseconds (MetricToDuration)
    static func latency(_ metric: UInt32) -> String {
        guard isReachable(metric) else { return "Unreachable" }
        return duration(nanoseconds: Int64(metric) * 1000)
    }

    static func duration(nanoseconds ns: Int64) -> String {
        guard ns > 0 else { return "—" }
        let ms = Double(ns) / 1_000_000
        return ms < 100 ? String(format: "%.1f ms", ms) : String(format: "%.0f ms", ms)
    }

    static func bytes(_ count: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: count), countStyle: .binary)
    }

    static func ago(unix: Int64, now: Date = Date()) -> String {
        guard unix > 0 else { return "Never" }
        let seconds = max(0, Int(now.timeIntervalSince1970) - Int(unix))
        if seconds < 60 { return "\(seconds) s ago" }
        if seconds < 3600 { return "\(seconds / 60) min ago" }
        if seconds < 86400 { return "\(seconds / 3600) h ago" }
        return "\(seconds / 86400) d ago"
    }

    // Like the CLI: far off or unset is "never"
    static func expiry(unix: Int64, now: Date = Date()) -> String {
        guard unix > 0 else { return "Never" }
        let seconds = Int(unix) - Int(now.timeIntervalSince1970)
        if seconds > 86400 { return "Never" }
        if seconds <= 0 { return "Expired" }
        if seconds < 60 { return "in \(seconds) s" }
        return "in \(seconds / 60) min"
    }

    // nylon's config timestamp is in nanoseconds
    static func configVersion(_ timestamp: Int64) -> String {
        guard timestamp > 0 else { return "—" }
        return Date(timeIntervalSince1970: TimeInterval(timestamp) / 1e9).formatted(date: .abbreviated, time: .shortened)
    }
}

extension Proto_NeighbourInfo {
    // The CLI's best endpoint: the active one with the lowest metric, then the lowest address
    var bestEndpoint: Proto_EndpointInfo? {
        endpoints.filter(\.active).min { ($0.metric, $0.address) < ($1.metric, $1.address) }
    }

    var bestMetric: UInt32 { bestEndpoint?.metric ?? .max }
}

extension Proto_TransportPeerStats {
    // nylon sends the handshake time in nanoseconds (core/ipc_handler.go), unlike its other timestamps
    var handshakeUnix: Int64 { latestHandshakeUnix / 1_000_000_000 }
}

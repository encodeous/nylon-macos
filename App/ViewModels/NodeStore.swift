import AppKit
import SwiftProtobuf
import UserNotifications

// The helper's state and each running network's status, for the views, and the things the user asks of it. Health
// and everything else the user sees is worked out here, not in the helper.
@MainActor
final class NodeStore: ObservableObject {
    // What a running network looks like right now, from its nylon
    struct Live: Equatable {
        var status: Proto_StatusResponse?
        var central: CentralSummary? // nil for a nylon started outside the app, whose config the helper can't read
        var error: String?

        var health: NetworkHealth? {
            guard let status, let central else { return nil }
            return NetworkHealth(status: status, central: central)
        }
    }

    // Just what the menu bar icon shows, published apart from everything else so the icon only redraws when it changes
    final class Icon: ObservableObject {
        @Published fileprivate(set) var running = false
    }

    let helper = HelperClient()
    let icon = Icon()
    @Published private(set) var state: HelperState?
    @Published private(set) var live: [String: Live] = [:]
    @Published private(set) var error: String? // the last thing the user asked for that failed
    @Published var selection: String? // the network the main window shows
    @Published var addingNetwork = false // the main window's Add Network sheet, which the menu can open too
    private let notifier = Notifier()

    init() {
        Task {
            while true {
                await update()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    var networks: [HelperState.Network] { state?.networks ?? [] }
    var running: Bool { networks.contains { $0.isUp } }

    func network(_ name: String) -> HelperState.Network? { networks.first { $0.name == name } }

    // One pass at a time: a pass reads, waits on the helper, then writes, so two at once could leave an older answer on
    // top of a newer one (a network just stopped showing as running again). Asked for during a pass, it waits for the
    // next one, which starts after the ask and so sees what the caller just did.
    private var updating: Task<Void, Never>?
    private var again = false

    func update() async {
        if let updating {
            again = true
            await updating.value
            return
        }
        let pass = Task {
            repeat {
                again = false
                await updateOnce()
            } while again
        }
        updating = pass
        await pass.value
        updating = nil
    }

    private func updateOnce() async {
        await helper.refresh()
        guard helper.setup == .ready else {
            if state != nil { state = nil }
            if icon.running { icon.running = false }
            if !live.isEmpty { live = [:] }
            return
        }
        // A failed read, e.g. while the screen is locked, keeps what was there rather than showing nothing. Only a
        // change is published, so a quiet network doesn't redraw the window every few seconds.
        if let fresh = try? await decodeJSON(HelperState.self, helper.perform(.state)), fresh != state { state = fresh }
        var next: [String: Live] = [:]
        for network in networks where network.isUp {
            next[network.name] = await refresh(network, previous: live[network.name])
        }
        notifier.check(networks: networks, live: next, before: live)
        if next != live { live = next }
        if icon.running != running { icon.running = running }
    }

    private func refresh(_ network: HelperState.Network, previous: Live?) async -> Live {
        var result = previous ?? Live()
        do {
            let status = try await Proto_StatusResponse(serializedBytes: helper.perform(.status(network: network.name)))
            result.status = status
            result.error = nil
            // central.yaml only changes with the config, so it's read again only when nylon's config does
            if network.status != .external, result.central?.timestamp != status.node.configTimestamp {
                let yaml = try await helper.perform(.central(network: network.name))
                result.central = try CentralSummary(yaml: String(decoding: yaml, as: UTF8.self))
            }
        } catch {
            result.error = "\(error)"
        }
        return result
    }

    // Does what the user asked, shows its error if it fails, then the new state.
    func attempt(_ work: () async throws -> Void) async {
        do {
            try await work()
            error = nil
        } catch {
            self.error = "\(error)"
        }
        await update()
    }

    func dismissError() { error = nil }

    func run(_ action: HelperAction, reason: String) async {
        await attempt { _ = try await helper.perform(action, reason: reason) }
    }

    func setRunning(_ network: String, _ on: Bool) async {
        await run(on ? .start(network: network) : .stop(network: network), reason: "\(on ? "start" : "stop") \(network)")
    }

    func reload(_ network: String) async throws -> Proto_ReloadResponse {
        let data = try await helper.perform(.reload(network: network), reason: "reload \(network)")
        await update()
        return try Proto_ReloadResponse(serializedBytes: data)
    }

    func probe(_ network: String, peer: String) async throws -> Proto_ProbeResponse {
        try await Proto_ProbeResponse(serializedBytes: helper.perform(.probe(network: network, peer: peer)))
    }

    func addNetwork(central: Data, node: Data) async throws {
        _ = try await helper.perform(.importConfig(central: central, node: node), reason: "add a network")
        await update()
    }

    // Both files of a network, for the editor. node.yaml holds the private key, so reading it asks for Touch ID.
    func config(_ network: String) async throws -> (central: String, node: String) {
        let node = try await helper.perform(.node(network: network), reason: "edit \(network)'s config")
        let central = try await helper.perform(.central(network: network))
        return (String(decoding: central, as: UTF8.self), String(decoding: node, as: UTF8.self))
    }

    func saveConfig(_ network: String, central: String, node: String) async throws {
        _ = try await helper.perform(.importConfig(central: Data(central.utf8), node: Data(node.utf8)), reason: "change \(network)'s config")
        await update()
    }
}

extension HelperState.Network {
    var isUp: Bool { status == .running || status == .external }
    var isExternal: Bool { status == .external }
}

// Tells the user when a network stops on its own or loses nodes. Each user's app watches for them, so it only does
// while the app runs, which it does from login.
@MainActor
private final class Notifier {
    private var asked = false

    func check(networks: [HelperState.Network], live: [String: NodeStore.Live], before: [String: NodeStore.Live]) {
        let defaults = UserDefaults.standard
        for network in networks {
            if defaults.bool(forKey: Preferences.notifyStopped), case .failed(let why) = network.status, before[network.name] != nil {
                post("\(network.name) stopped", why)
            }
            if defaults.bool(forKey: Preferences.notifyUnreachable),
               let now = live[network.name]?.health, let then = before[network.name]?.health {
                // only nodes that went from reachable to not: one just added to central.yaml isn't news
                let lost = now.unreachable.filter(then.reached.contains)
                if !lost.isEmpty { post("\(network.name): \(now.summary)", "Can't reach \(lost.joined(separator: ", ")).") }
            }
        }
    }

    private func post(_ title: String, _ body: String) {
        let center = UNUserNotificationCenter.current()
        Task {
            if !asked {
                asked = true
                _ = try? await center.requestAuthorization(options: [.alert, .sound])
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}

enum Preferences {
    static let notifyUnreachable = "notifyUnreachable"
    static let notifyStopped = "notifyStopped"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [notifyUnreachable: true, notifyStopped: true])
    }
}

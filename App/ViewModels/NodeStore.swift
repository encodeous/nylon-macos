import AppKit
import UniformTypeIdentifiers

// The helper's state, for the views, and the things the user asks of it.
@MainActor
final class NodeStore: ObservableObject {
    let helper = HelperClient()
    @Published private(set) var state: HelperState?
    @Published private(set) var error: String? // the last thing the user asked for that failed

    init() {
        Task {
            while true {
                await update()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    var networks: [HelperState.Network] { state?.networks ?? [] }
    var running: Bool { networks.contains { $0.status == .running || $0.status == .external } }

    func update() async {
        await helper.refresh()
        guard helper.setup == .ready else { return state = nil }
        // A failed read, e.g. while the screen is locked, keeps what was there rather than showing nothing.
        if let fresh = try? await decodeJSON(HelperState.self, helper.perform(.state)) { state = fresh }
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

    func run(_ action: HelperAction, reason: String) async {
        await attempt { _ = try await helper.perform(action, reason: reason) }
    }

    // Asks for central.yaml and node.yaml and hands them to the helper, which adds the network node.yaml names, or
    // updates it.
    func importConfig() async {
        guard let central = pick("Choose the network's central.yaml"), let node = pick("Choose this Mac's node.yaml") else { return }
        await attempt {
            _ = try await helper.perform(.importConfig(central: Data(contentsOf: central), node: Data(contentsOf: node)),
                                         reason: "change nylon's networks")
        }
    }

    private func pick(_ message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.message = message
        panel.allowedContentTypes = [.yaml]
        return panel.runModal() == .OK ? panel.url : nil
    }
}

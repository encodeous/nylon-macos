import AppKit
import SwiftUI

// The status item's menu: each network's status, and the way to Settings. A placeholder until the real UI.
struct MenuContent: View {
    @ObservedObject var store: NodeStore
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if store.networks.isEmpty {
            Text(store.helper.setup == .ready ? "Add a network in Settings" : "Set up nylon in Settings")
        }
        ForEach(store.networks, id: \.name) { Text("\($0.name): \(statusText($0.status))") }
        Divider()
        Button("Settings…") { showWindow(openSettings.callAsFunction) }
        Button("Quit") { NSApplication.shared.terminate(nil) }
    }
}

func statusText(_ status: HelperState.Network.Status) -> String {
    switch status {
    case .stopped: "Stopped"
    case .starting: "Starting…"
    case .running: "Running"
    case .external: "Running separately. Start and stop it the way you installed it."
    case .failed(let why): why
    }
}

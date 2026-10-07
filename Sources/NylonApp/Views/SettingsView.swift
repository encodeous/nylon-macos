import AppKit
import SwiftUI

// The Settings window: where the app finds central.yaml and nylon's metrics.
struct SettingsView: View {
    @ObservedObject var store: NodeStore

    var body: some View {
        Form {
            Section {
                LabeledContent("central.yaml") {
                    Text(store.nodes == nil ? "Can't read \(store.path)" : store.path)
                        .lineLimit(1)
                        .truncationMode(.middle) // a long path keeps its start and its file name
                    Button("Choose…") { chooseCentral() }
                }
            }
            Section {
                TextField("Metrics URL", text: $store.metricsURL)
            } footer: {
                Text(store.peers == nil ? "nylon isn't answering there. Set observability_addr in node.yaml." : "nylon is answering.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true) // as tall as its rows, no taller
    }

    private func chooseCentral() {
        let panel = NSOpenPanel()
        if panel.runModal() == .OK, let url = panel.url { store.choose(url.path) }
    }
}

// The menu bar icon. On a launch with no readable central.yaml it opens Settings, so a new user isn't left guessing.
struct MenuBarIcon: View {
    let image: NSImage
    let needsSetup: Bool
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Image(nsImage: image)
            .accessibilityLabel("Nylon")
            .task { if needsSetup { showSettings(openSettings) } }
    }
}

// A menu bar app has no Dock icon and isn't in Cmd-Tab, so its window gets lost behind others.
// While a window is open the app is a regular one; MenuApp turns it back when the last window closes.
@MainActor func showSettings(_ openSettings: OpenSettingsAction) {
    NSApp.setActivationPolicy(.regular)
    NSApp.activate()
    openSettings()
}

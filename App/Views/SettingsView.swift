import AppKit
import ServiceManagement
import SwiftUI

// The Settings window: installing the helper, and running networks through it. A placeholder until the real UI.
struct SettingsView: View {
    @ObservedObject var store: NodeStore
    @ObservedObject var helper: HelperClient

    var body: some View {
        Form {
            Section("Helper") {
                LabeledContent("Status") { Text(setupText) }
                switch helper.setup {
                case .notInstalled: Button("Install Helper…") { Task { await helper.install() } }
                case .waitingForLoginItem: Button("Open Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                case .notPaired: Button("Pair…") { attempt(helper.pair) }
                case .outdated: Button("Update Helper") { attempt(helper.update) }
                case .ready: Button("Unpair") { attempt(helper.unpair) }
                case .failed: Button("Install Helper…") { Task { await helper.install() } }
                case .unsigned: EmptyView()
                }
                if helper.setup != .unsigned && helper.setup != .notInstalled {
                    Button("Uninstall Helper…", role: .destructive) { attempt(helper.uninstall) }
                }
            }
            if helper.setup == .ready {
                ForEach(store.networks, id: \.name) { NetworkSection(store: store, network: $0) }
                Section {
                    Button("Add Network…") { Task { await store.importConfig() } }
                } footer: {
                    Text("Pick a network's central.yaml and this Mac's node.yaml. Each network needs its own interface_name and port.")
                }
                if let tool = store.state?.commandLineTool {
                    Section {
                        Toggle("Install the nylon command", isOn: Binding(
                            get: { tool == .installed },
                            set: { on in Task { await store.run(.setCommandLineTool(installed: on), reason: "change the nylon command") } }
                        ))
                        .disabled(tool != .installed && tool != .notInstalled)
                    } header: {
                        Text("Command line")
                    } footer: {
                        if case .other(let path) = tool {
                            Text("\(path) is another nylon, so the app leaves it alone.")
                        } else {
                            Text("Links /usr/local/bin/nylon to the nylon inside this app. Use it with sudo, e.g. sudo nylon status -i <network>.")
                        }
                    }
                }
            }
            if let error = store.error {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true) // as tall as its rows, no taller
    }

    private func attempt(_ work: @escaping () async throws -> Void) {
        Task { await store.attempt(work) }
    }

    private var setupText: String {
        switch helper.setup {
        case .unsigned: "This build isn't signed with a team, so it can't use the helper."
        case .notInstalled: "Not installed"
        case .waitingForLoginItem: "Allow nylon in System Settings > General > Login Items, then pair this app."
        case .notPaired: "Installed. Pair this app to control nylon; it asks for an administrator."
        case .outdated(let version): "The helper is from version \(version) of the app. Update it to this one."
        case .ready: "Paired" + (helper.version.map { ", version \($0)" } ?? "")
        case .failed(let why): why
        }
    }
}

// One network: its status, and starting, stopping and changing it. A nylon running outside the app is read-only.
struct NetworkSection: View {
    let store: NodeStore
    let network: HelperState.Network
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Section(network.name) {
            LabeledContent("Status") { Text(statusText(network.status)).lineLimit(3) }
            if network.status != .external {
                HStack {
                    switch network.status {
                    case .running:
                        Button("Stop") { run(.stop(network: network.name), "stop \(network.name)") }
                        Button("Reload Config") { run(.reload(network: network.name), "reload \(network.name)'s config") }
                    case .stopped, .failed:
                        Button("Start") { run(.start(network: network.name), "start \(network.name)") }
                    case .starting, .external:
                        EmptyView()
                    }
                    Button("Show Log") { showWindow { openWindow(id: "log", value: network.name) } }
                    Button("Update Config…") { Task { await store.importConfig() } }
                    Button("Remove…", role: .destructive) { run(.remove(network: network.name), "remove \(network.name)") }
                }
                Toggle("Start when this Mac starts", isOn: Binding(
                    get: { network.startAtBoot },
                    set: { on in run(.setStartAtBoot(network: network.name, on), "change when \(network.name) starts") }
                ))
            }
        }
    }

    private func run(_ action: HelperAction, _ reason: String) {
        Task { await store.run(action, reason: reason) }
    }
}

// The status item's icon. On launch, if the helper isn't set up, it opens Settings, so a new user isn't left guessing.
struct MenuBarIcon: View {
    let image: NSImage
    let store: NodeStore
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Image(nsImage: image)
            .accessibilityLabel("nylon")
            .task {
                await store.update()
                if store.helper.setup != .ready { showWindow(openSettings.callAsFunction) }
            }
    }
}

// Without a Dock icon the app isn't in Cmd-Tab, so its windows get lost behind others.
// While a window is open the app is a regular one; MenuApp turns it back when the last window closes.
@MainActor func showWindow(_ open: () -> Void) {
    NSApp.setActivationPolicy(.regular)
    NSApp.activate()
    open()
}

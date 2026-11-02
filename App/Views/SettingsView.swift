import AppKit
import ServiceManagement
import SwiftUI

// The app's own settings, in the standard toolbar tabs: General, Helper, About. Each network's settings are in the
// main window.
struct SettingsView: View {
    @ObservedObject var store: NodeStore
    @ObservedObject var helper: HelperClient

    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            HelperSettings(store: store, helper: helper)
                .tabItem { Label("Helper", systemImage: "lock.shield") }
            AboutView(helper: helper)
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 480)
    }
}

private struct GeneralSettings: View {
    @AppStorage(Preferences.notifyUnreachable) private var notifyUnreachable = true
    @AppStorage(Preferences.notifyStopped) private var notifyStopped = true
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section {
                Toggle("Open nylon app at login", isOn: $openAtLogin)
                    .onChange(of: openAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            openAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                    .help("Networks run whether or not the app is open")
            }
            Section("Notifications") {
                Toggle("When nodes become unreachable", isOn: $notifyUnreachable)
                Toggle("When a network stops unexpectedly", isOn: $notifyStopped)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true) // as tall as its rows, no taller
    }
}

private struct HelperSettings: View {
    @ObservedObject var store: NodeStore
    @ObservedObject var helper: HelperClient
    @Environment(\.openWindow) private var openWindow
    @State private var uninstalling = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Status") { Text(setupText) }
                HStack {
                    Spacer()
                    if helper.setup != .ready && helper.setup != .unsigned {
                        Button("Set Up…") { showWindow { openWindow(id: "setup") } }
                    }
                    if helper.setup == .ready { Button("Disconnect") { Task { await store.attempt(helper.unpair) } } }
                    if helper.setup != .unsigned && helper.setup != .notInstalled {
                        Button("Uninstall…", role: .destructive) { uninstalling = true }
                            .help("Stops all networks for every user")
                    }
                }
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
                        Text("Use with sudo, e.g. sudo nylon status -i <network>")
                    }
                }
            }

            if let error = store.error {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .confirmationDialog("Uninstall the helper?", isPresented: $uninstalling) {
            Button("Uninstall", role: .destructive) { Task { await store.attempt(helper.uninstall) } }
        } message: {
            Text("Every network on this Mac stops, for every user. Their config stays.")
        }
    }

    private var setupText: String {
        switch helper.setup {
        case .unsigned: "This build isn't signed with a team"
        case .notInstalled: "Not installed"
        case .waitingForLoginItem: "Waiting for Login Items"
        case .notPaired: "Not connected"
        case .outdated(let version): "Outdated (\(version))"
        case .ready: "Connected"
        case .failed(let why): why
        }
    }
}

private struct AboutView: View {
    @ObservedObject var helper: HelperClient

    var body: some View {
        VStack(spacing: 6) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
            Text("Nylon").font(.title.weight(.semibold))
            Text("Version \(info("CFBundleShortVersionString")) (\(info("CFBundleVersion")))")
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if let version = helper.version {
                Text("Helper \(version)").foregroundStyle(.secondary).textSelection(.enabled)
            }
            HStack(spacing: 16) {
                Link("Documentation", destination: URL(string: "https://nylon.jq.ax")!)
                Link("Nylon on GitHub", destination: URL(string: "https://github.com/encodeous/nylon")!)
                Link("This App on GitHub", destination: URL(string: "https://github.com/encodeous/nylon-macos")!)
            }
            .padding(.top, 14)
        }
        .padding(28)
        .frame(maxWidth: .infinity)
    }

    private func info(_ key: String) -> String {
        Bundle.main.infoDictionary?[key] as? String ?? "?"
    }
}

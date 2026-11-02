import AppKit
import SwiftUI

// The status item's panel: each network, whether it's on, and how much of it this Mac reaches. Details are in the
// main window.
struct MenuContent: View {
    @ObservedObject var store: NodeStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if store.helper.setup != .ready {
                Text("Set up nylon to get started.")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            } else if store.networks.isEmpty {
                Text("No networks yet.")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            }
            ForEach(store.networks, id: \.name) { network in
                MenuNetworkRow(store: store, network: network) { open(network: network.name) }
            }
            Divider().padding(.vertical, 4)
            MenuItem("Open Nylon…") { open(network: nil) }
            if store.helper.setup == .ready {
                MenuItem("Add Network…") {
                    store.addingNetwork = true
                    open(network: nil)
                }
            }
            MenuItem("Settings…") {
                dismiss()
                showWindow(openSettings.callAsFunction)
            }
            Divider().padding(.vertical, 4)
            // only the app: the helper keeps the networks running
            MenuItem("Quit Nylon App") { NSApplication.shared.terminate(nil) }
                .help("Networks keep running")
        }
        .padding(6)
        .frame(width: 320)
    }

    private func open(network: String?) {
        if let network { store.selection = network }
        dismiss()
        showWindow { openWindow(id: "main") }
    }
}

private struct MenuNetworkRow: View {
    @ObservedObject var store: NodeStore
    let network: HelperState.Network
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        let health = store.live[network.name]?.health
        HStack(alignment: .top, spacing: 10) {
            StatusDot(network: network, health: health).padding(.top, 5)
            VStack(alignment: .leading, spacing: 4) {
                Text(network.name).fontWeight(.semibold)
                Text(subtitle(health)).font(.caption).foregroundStyle(.secondary)
                    .help(ifAny: health?.detail)
            }
            Spacer(minLength: 8)
            if network.isExternal {
                Text("Unmanaged").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    .help("Started outside this app, so it can only be viewed here")
            } else {
                Toggle(network.name, isOn: Binding(
                    get: { network.status == .running || network.status == .starting },
                    set: { on in Task { await store.setRunning(network.name, on) } }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(hovering ? Color.primary.opacity(0.06) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: open)
    }

    private func subtitle(_ health: NetworkHealth?) -> String {
        switch network.status {
        case .stopped: return "Stopped"
        case .starting: return "Starting…"
        case .failed(let why): return why
        case .external: return health?.summary ?? "Running"
        case .running:
            if let error = store.live[network.name]?.error { return error }
            return health?.summary ?? "Running"
        }
    }
}

// A plain menu-like row
private struct MenuItem: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .foregroundStyle(hovering ? Color.white : Color.primary)
                .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? Color.accentColor : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// Green when everything is reachable, orange when some isn't, grey when off, red when it failed
struct StatusDot: View {
    let network: HelperState.Network
    let health: NetworkHealth?

    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8)
    }

    private var color: Color {
        switch network.status {
        case .stopped: .secondary.opacity(0.5)
        case .starting: .yellow
        case .failed: .red
        case .running, .external: health.map { $0.healthy ? .green : .orange } ?? .green
        }
    }
}

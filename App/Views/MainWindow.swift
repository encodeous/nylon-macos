import SwiftUI

// The main window: networks down the side, the chosen one's tabs on the right. Until the helper is set up, it shows
// setup instead.
struct MainWindow: View {
    @ObservedObject var store: NodeStore
    @ObservedObject private var helper: HelperClient
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    init(store: NodeStore) {
        self.store = store
        helper = store.helper
    }

    var body: some View {
        Group {
            if !helper.checked {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if helper.setup == .ready {
                NavigationSplitView {
                    Sidebar(store: store)
                        .navigationSplitViewColumnWidth(min: 180, ideal: 210)
                } detail: {
                    if let name = store.selection, let network = store.network(name) {
                        // its own view per network, so the toolbar builds the tab bar afresh rather than resizing the last
                        // network's, which it does late
                        NetworkView(store: store, network: network).id(name)
                    } else {
                        ContentUnavailableView {
                            Label(store.networks.isEmpty ? "No Networks" : "No Network Selected", systemImage: "point.3.connected.trianglepath.dotted")
                        } actions: {
                            if store.networks.isEmpty { Button("Add Network…") { store.addingNetwork = true } }
                        }
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .primaryAction) { SettingsButton() }
                }
            } else {
                // setup has its own small window; this one steps aside for it
                Color.clear.onAppear {
                    openWindow(id: "setup")
                    dismissWindow(id: "main")
                }
            }
        }
        .frame(minWidth: 820, minHeight: 520)
        .sheet(isPresented: $store.addingNetwork) { AddNetworkSheet(store: store) }
        .onAppear { if store.selection == nil { store.selection = store.networks.first?.name } }
        .onChange(of: store.networks.map(\.name)) { _, names in
            if store.selection.map({ !names.contains($0) }) ?? true { store.selection = names.first }
        }
    }
}

private struct Sidebar: View {
    @ObservedObject var store: NodeStore

    var body: some View {
        List(selection: $store.selection) {
            Section("Networks") {
                ForEach(store.networks, id: \.name) { network in
                    HStack(spacing: 8) {
                        StatusDot(network: network, health: store.live[network.name]?.health)
                        Text(network.name)
                        Spacer()
                        Text(trailing(network)).font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(network.name)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button { store.addingNetwork = true } label: { Label("Add Network…", systemImage: "plus") }
                .buttonStyle(.borderless)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
    }

    private func trailing(_ network: HelperState.Network) -> String {
        switch network.status {
        case .stopped: "Stopped"
        case .starting: "Starting"
        case .failed: "Failed"
        case .external: "Unmanaged"
        case .running: store.live[network.name]?.status?.node.interface ?? ""
        }
    }
}

enum NetworkTab: String, CaseIterable, Identifiable {
    case overview = "Overview", peers = "Peers", routes = "Routes", activity = "Activity", config = "Config"
    var id: Self { self }
}

// One network: a toolbar to start, stop and reload it, and its tabs.
struct NetworkView: View {
    @ObservedObject var store: NodeStore
    let network: HelperState.Network
    @State private var tab = NetworkTab.overview
    @State private var built: Set<NetworkTab> = [.overview]
    @State private var snapshots: [NetworkTab: NodeStore.Live] = [:]
    @State private var notice: String?

    var body: some View {
        VStack(spacing: 0) {
            if let notice = notice ?? store.error {
                Banner(text: notice, isError: store.error == notice) {
                    self.notice = nil
                    store.dismissError()
                }
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        // a light material, so the bar is slightly see-through like the sidebar
        .toolbarBackground(.thinMaterial, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .navigationTitle(network.name)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Section", selection: $tab) {
                    ForEach(tabs) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            if !network.isExternal {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button("Reload Config", systemImage: "arrow.clockwise") { reload() }
                        .disabled(network.status != .running)
                        .help("Apply config changes without restarting")
                    if network.status == .running || network.status == .starting {
                        Button("Stop", systemImage: "stop.fill") { Task { await store.setRunning(network.name, false) } }
                    } else {
                        Button("Start", systemImage: "play.fill") { Task { await store.setRunning(network.name, true) } }
                    }
                }
            }
        }
    }

    // a nylon started elsewhere has no config or log the app can read
    private var tabs: [NetworkTab] {
        network.isExternal ? [.overview, .peers, .routes] : NetworkTab.allCases
    }

    // Every tab is built once, shortly after the network opens, and kept: switching only shows one and hides the rest,
    // so the tab bar's animation isn't held up building a tab. Hidden tabs keep the status they last showed, so they
    // don't redraw on every update.
    private var content: some View {
        ZStack {
            ForEach(tabs) { t in
                if built.contains(t) {
                    tabView(t, live: t == tab ? store.live[network.name] : snapshots[t] ?? store.live[network.name])
                        .frame(maxWidth: .infinity, maxHeight: .infinity) // every tab spans the window, so its glass does
                        .opacity(t == tab ? 1 : 0)
                        // Moved out of the window, not just made clear: a clear tab's AppKit views are still there, and
                        // their tables' column-resize cursors would show over the visible tab. Moving doesn't redo layout.
                        .offset(x: t == tab ? 0 : 100_000)
                        .allowsHitTesting(t == tab)
                        .accessibilityHidden(t != tab)
                }
            }
        }
        // Tabs draw below the toolbar, not behind it: behind it, each scroll view draws its own glass, which splits
        // where a tab has two side by side (Peers)
        .clipped()
        .belowToolbar()
        .onChange(of: tab) { old, new in
            snapshots[old] = store.live[network.name]
            built.insert(new)
        }
        .task {
            try? await Task.sleep(for: .milliseconds(300)) // after the first tab is on screen
            for t in tabs where t != tab { snapshots[t] = store.live[network.name] }
            built.formUnion(tabs)
        }
    }

    @ViewBuilder private func tabView(_ tab: NetworkTab, live: NodeStore.Live?) -> some View {
        switch tab {
        case .activity: ActivityTab(store: store, network: network.name, active: self.tab == .activity)
        case .config: ConfigTab(store: store, network: network)
        default:
            if let status = live?.status, network.isUp {
                switch tab {
                case .peers: PeersTab(store: store, network: network.name, status: status)
                case .routes: RoutesTab(status: status)
                default: OverviewTab(status: status, live: live!)
                }
            } else {
                ContentUnavailableView {
                    Label(unavailableTitle, systemImage: "network.slash")
                } description: {
                    if let error = live?.error { Text(error) }
                } actions: {
                    if network.status == .stopped || isFailed {
                        Button("Start") { Task { await store.setRunning(network.name, true) } }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var isFailed: Bool {
        if case .failed = network.status { true } else { false }
    }

    private var unavailableTitle: String {
        switch network.status {
        case .stopped: "Stopped"
        case .starting: "Starting…"
        case .failed(let why): why
        case .running, .external: "Waiting for nylon…"
        }
    }

    private func reload() {
        Task {
            do {
                let result = try await store.reload(network.name)
                switch result.result {
                case .applied: notice = "Config applied."
                case .noop: notice = "Config is already current."
                case .restartRequired: notice = "These changes need a restart."
                case .rejected: notice = result.message.isEmpty ? "Nylon rejected the config." : result.message
                case .UNRECOGNIZED: notice = result.message
                }
            } catch {
                notice = "\(error)"
            }
        }
    }
}

struct Banner: View {
    let text: String
    let isError: Bool
    let close: () -> Void

    var body: some View {
        HStack {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isError ? .orange : .green)
            Text(text).textSelection(.enabled)
            Spacer()
            Button("Dismiss", systemImage: "xmark", action: close).labelStyle(.iconOnly).buttonStyle(.borderless)
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

import ServiceManagement
import SwiftUI

// First run: install the helper, allow it in Login Items, pair. A window of its own, sized to fit; once the helper is
// ready it closes and the main window opens.
struct SetupView: View {
    @ObservedObject var helper: HelperClient
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
                Text("Set Up Nylon").font(.title.weight(.semibold))
                Text("The nylon app needs a helper to communicate with the nylon daemon, which keeps your networks running even when the app is closed. Connecting to the helper requires administrator rights.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 10) {
                Text(helper.setup.title).font(.headline)
                if helper.setup.busy || helper.setup == .starting { ProgressView().controlSize(.small) }
                actions.primaryAction().controlSize(.large)
                if let message = helper.coordinator.status.message {
                    Text(message).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 36)
        .padding(.top, 12) // the toolbar above holds only the Settings button
        .padding(.bottom, 32)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .toolbar {
            // a real toolbar item, so macOS lines it up with the window buttons and draws it as glass
            ToolbarItem(placement: .primaryAction) { SettingsButton() }
        }
        .toolbarBackground(.hidden, for: .windowToolbar)
        .windowGlass()
        .background(FixedWindow())
        .onChange(of: helper.setup, initial: true) { _, setup in
            if setup == .ready {
                openWindow(id: "main")
                dismissWindow(id: "setup")
            }
        }
    }

    @ViewBuilder private var actions: some View {
        switch helper.setup {
        case .notInstalled:
            Button("Install") { Task { await helper.coordinator.install() } }
        case .waitingForLoginItem:
            Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
        case .notPaired:
            Button("Connect…") { Task { await helper.coordinator.connect() } }
            if helper.coordinator.status.message != nil { RepairPairingButton(helper: helper) }
        case .outdated:
            Button("Update Helper") { Task { await helper.coordinator.update() } }
        case .unreachable:
            HStack {
                Button("Try Again") { Task { await helper.coordinator.retry() } }
                Button("Re-register Helper") { Task { await helper.coordinator.update() } }
            }
        case .verificationFailed:
            Button("Try Again") { Task { await helper.coordinator.retry() } }
            RepairPairingButton(helper: helper)
        case .blocked:
            Button("Try Again") { Task { await helper.coordinator.retry() } }
        default: EmptyView()
        }
    }
}

struct RepairPairingButton: View {
    @ObservedObject var helper: HelperClient
    @State private var confirming = false

    var body: some View {
        Button("Re-pair This Account…") { confirming = true }
            .confirmationDialog("Replace the pairing keys for this macOS account?", isPresented: $confirming) {
                Button("Re-pair This Account") { Task { await helper.coordinator.connect(replacing: true) } }
            } message: {
                Text("An administrator must approve new keys. This replaces this account’s existing helper pairings. Other users and running networks keep their current settings.")
            }
    }
}

extension SetupPhase {
    var title: String {
        switch self {
        case .checking: "Checking setup…"
        case .stopped(let reason): reason.rawValue
        case .notInstalled: "Install the helper"
        case .registering: "Registering the helper…"
        case .waitingForLoginItem: "Allow the helper in Login Items"
        case .starting: "Waiting for the helper to respond…"
        case .unreachable: "The registered helper is still not responding."
        case .outdated(let version): "Update the helper from version \(version)"
        case .updating: "Updating the helper registration…"
        case .notPaired: "Connect to the helper"
        case .pairing: "Connecting to the helper…"
        case .verifying: "Verifying the pairing…"
        case .verificationFailed: "Could not verify the pairing"
        case .ready: "Connected"
        case .removing: "Disconnecting the helper…"
        case .blocked: "Setup needs attention"
        }
    }
}

// A window that stays the size of its content (no resizing, zooming or full screen), with its title bar hidden so the
// glass background runs to the top
private struct FixedWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { // in a window by now
            guard let window = view.window else { return }
            window.styleMask.remove(.resizable)
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.collectionBehavior.insert(.fullScreenNone)
            window.standardWindowButton(.zoomButton)?.isEnabled = false
        }
    }
}

private extension View {
    @ViewBuilder func primaryAction() -> some View {
        if #available(macOS 26, *) { buttonStyle(.glassProminent) } else { buttonStyle(.borderedProminent) }
    }

    // the window's own background, see-through to the desktop like other setup windows
    @ViewBuilder func windowGlass() -> some View {
        if #available(macOS 15, *) { containerBackground(.thinMaterial, for: .window) } else { self }
    }
}

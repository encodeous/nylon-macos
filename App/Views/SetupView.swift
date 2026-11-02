import ServiceManagement
import SwiftUI

// First run: install the helper, allow it in Login Items, pair. A window of its own, sized to fit; once the helper is
// ready it closes and the main window opens.
struct SetupView: View {
    @ObservedObject var store: NodeStore
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

            VStack(spacing: 4) {
                step(1, "Install the helper", done: installed, current: helper.setup == .notInstalled || isFailed) {
                    Button("Install") { Task { await helper.install() } }
                }
                step(2, "Allow it in Login Items", done: installed && helper.setup != .waitingForLoginItem,
                     current: helper.setup == .waitingForLoginItem) {
                    Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                }
                step(3, "Connect to the helper", done: false, current: helper.setup == .notPaired) {
                    Button("Connect…") { Task { await store.attempt(helper.pair) } }
                        .help("Requires administrator rights")
                }
            }

            if case .outdated(let version) = helper.setup {
                VStack(spacing: 10) {
                    Text("The helper is from version \(version).").foregroundStyle(.secondary)
                    Button("Update Helper") { Task { await store.attempt(helper.update) } }
                        .primaryAction()
                }
            }
            if case .failed(let why) = helper.setup { Text(why).foregroundStyle(.red).textSelection(.enabled) }
            if helper.setup == .unsigned {
                Text("This build isn't signed with a team, so it can't use the helper.").foregroundStyle(.secondary)
            }
            if let error = store.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
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
        .onChange(of: helper.setup) { _, setup in
            if setup == .ready {
                openWindow(id: "main")
                dismissWindow(id: "setup")
            }
        }
    }

    private var installed: Bool {
        switch helper.setup {
        case .notInstalled, .unsigned, .failed: false
        default: true
        }
    }

    private var isFailed: Bool {
        if case .failed = helper.setup { true } else { false }
    }

    // A step: a numbered row, the current one raised on glass with its action
    private func step(_ number: Int, _ title: String, done: Bool, current: Bool, @ViewBuilder action: () -> some View) -> some View {
        HStack(spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : current ? "\(number).circle.fill" : "\(number).circle")
                .font(.title2)
                .foregroundStyle(done ? Color.green : current ? Color.accentColor : Color.secondary)
            Text(title)
                .fontWeight(current ? .semibold : .regular)
                .foregroundStyle(current || done ? .primary : .secondary)
            Spacer()
            if current { action().primaryAction().controlSize(.large) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, current ? 14 : 10)
        .stepCard(current)
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
    // the current step's card: Liquid Glass on macOS 26, a tint before
    @ViewBuilder func stepCard(_ raised: Bool) -> some View {
        if !raised {
            self
        } else if #available(macOS 26, *) {
            glassEffect(.regular, in: .rect(cornerRadius: 16))
        } else {
            background(RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.08)))
        }
    }

    @ViewBuilder func primaryAction() -> some View {
        if #available(macOS 26, *) { buttonStyle(.glassProminent) } else { buttonStyle(.borderedProminent) }
    }

    // the window's own background, see-through to the desktop like other setup windows
    @ViewBuilder func windowGlass() -> some View {
        if #available(macOS 15, *) { containerBackground(.thinMaterial, for: .window) } else { self }
    }
}

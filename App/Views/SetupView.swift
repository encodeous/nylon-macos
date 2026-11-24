import ServiceManagement
import SwiftUI

// First run: install the helper, allow it in Login Items, pair. A window of its own, sized to fit; once the helper is
// ready it closes and the main window opens.
struct SetupView: View {
    @ObservedObject var helper: HelperClient
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        let message = helper.setup == .starting ? nil : helper.coordinator.status.message
        let presentation = helper.setup.presentation(
            continuing: helper.coordinator.willContinueAutomatically,
            hasMessage: message != nil
        )
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 96, height: 96)
                    .accessibilityHidden(true)
                Text("Set Up Nylon")
                    .font(.title.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("The helper keeps your networks running in the background. macOS will ask you to allow it and approve the connection.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .multilineTextAlignment(.center)

            VStack(spacing: 4) {
                ForEach(SetupStep.all) { step in
                    stepRow(step, presentation: presentation)
                }
            }

            setupNotice(presentation, message: message)
        }
        .padding(.horizontal, 36)
        .padding(.top, 12)
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
        .onDisappear { helper.coordinator.cancelAutomaticSetup() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await helper.coordinator.refresh() }
        }
        .onChange(of: helper.setup, initial: true) { _, setup in
            if setup == .ready {
                openWindow(id: "main")
                dismissWindow(id: "setup")
            }
        }
    }

    private func stepRow(_ step: SetupStep, presentation: SetupPresentation) -> some View {
        let activeStep = presentation.step
        let current = step == activeStep
        let completed = helper.setup == .ready || (activeStep.map { step.id < $0.id } ?? false)
        let symbol = completed ? "checkmark.circle.fill" : "\(step.id).circle" + (current ? ".fill" : "")
        let stepStatus = completed ? "Completed" : current ? "Current step" : "Pending"
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(completed ? Color.green : current ? Color.accentColor : Color.secondary)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                Text(step.title)
                    .fontWeight(current ? .semibold : .regular)
                    .foregroundStyle(current || completed ? .primary : .secondary)
                    .accessibilityRepresentation {
                        Text("Step \(step.id): \(step.title). \(stepStatus).")
                    }
                Spacer(minLength: 8)
                if current {
                    if let action = presentation.action { primary(action) }
                    else if showsProgress { progressIndicator }
                }
            }
            if current, let hint = presentation.hint {
                detail(hint).padding(.leading, 34)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 42)
        .activeStepCard(current)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private func setupNotice(_ presentation: SetupPresentation, message: String?) -> some View {
        let showStatus = presentation.step == nil && helper.setup != .ready
        if showStatus || message != nil || presentation.recovery != nil {
            VStack(alignment: .leading, spacing: 8) {
                if showStatus {
                    HStack(spacing: 8) {
                        if showsProgress { progressIndicator }
                        Text(presentation.title).fontWeight(.medium)
                        Spacer(minLength: 8)
                        if let action = presentation.action { primary(action) }
                    }
                    .foregroundStyle(.secondary)
                }
                if let message { detail(message).textSelection(.enabled) }
                switch presentation.recovery {
                case .approval:
                    Button("I’ve Allowed Nylon") { Task { await helper.coordinator.repairRegistration() } }
                        .buttonStyle(.borderless)
                        .help("If macOS is still waiting for approval, Nylon can refresh the helper registration once.")
                case .pairing:
                    RepairPairingButton(helper: helper).buttonStyle(.borderless)
                case nil: EmptyView()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func detail(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private var showsProgress: Bool {
        let phase = helper.setup
        return phase.busy || phase == .starting || (phase == .notPaired && helper.coordinator.willContinueAutomatically)
    }

    private var progressIndicator: some View {
        ProgressView().controlSize(.small).accessibilityHidden(true)
    }

    private func primary(_ action: SetupPresentation.Action) -> some View {
        Button(action.title) { Task { await action.run(helper.coordinator) } }
            .primaryAction()
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
    }
}

private struct SetupStep: Identifiable, Equatable {
    let id: Int
    let title: String

    static let install = Self(id: 1, title: "Register the helper")
    static let allow = Self(id: 2, title: "Allow it in Login Items")
    static let connect = Self(id: 3, title: "Connect to the helper")
    static let all = [install, allow, connect]
}

private struct SetupPresentation {
    typealias Action = (title: LocalizedStringKey, run: @MainActor (SetupCoordinator) async -> Void)
    enum Recovery { case approval, pairing }

    let title: String
    var step: SetupStep?
    var action: Action?
    var hint: String?
    var recovery: Recovery?

    static func withHint(_ title: String, _ step: SetupStep) -> Self {
        Self(title: title, step: step, hint: title)
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
    var title: String { presentation().title }

    fileprivate func presentation(continuing: Bool = false, hasMessage: Bool = false) -> SetupPresentation {
        switch self {
        case .checking: return .init(title: "Checking setup…")
        case .stopped(let reason): return .init(title: reason.rawValue)
        case .notInstalled:
            return .init(title: SetupStep.install.title, step: .install, action: ("Start Setup", { await $0.install() }))
        case .registering: return .withHint("Registering the helper…", .install)
        case .registrationPending: return .withHint("Waiting for macOS to finish the helper request…", .install)
        case .waitingForLoginItem:
            let hint = continuing
                ? "Turn on Nylon under Background App Activity. Setup continues after macOS approves the helper."
                : "Turn on Nylon under Background App Activity, then return here. macOS is still waiting for approval."
            return .init(title: "Allow Nylon in the Background", step: .allow,
                         action: ("Open Login Items", { _ in SMAppService.openSystemSettingsLoginItems() }),
                         hint: hint, recovery: .approval)
        case .repairingRegistration: return .withHint("Checking the helper’s approval…", .allow)
        case .starting: return .withHint("Waiting for the helper to respond…", .connect)
        case .unreachable:
            return .init(title: "The registered helper is still not responding.", step: .connect,
                         action: ("Try Again", { await $0.repairRegistration() }),
                         hint: "macOS approved the helper, but it hasn’t answered. Trying again may restart the helper.")
        case .restartingHelper: return .withHint("Trying to start the helper again…", .connect)
        case .outdated(let version):
            let title = "Update the helper from version \(version)"
            return .init(title: title, step: .install, action: ("Update Helper", { await $0.update() }), hint: title)
        case .updating: return .withHint("Updating the helper registration…", .install)
        case .notPaired:
            let connect: SetupPresentation.Action = ("Connect…", { await $0.connect() })
            return .init(title: SetupStep.connect.title, step: .connect, action: continuing ? nil : connect,
                         hint: continuing ? "Preparing to connect…" : nil,
                         recovery: hasMessage ? .pairing : nil)
        case .pairing:
            return .init(title: "Approve the Connection", step: .connect, hint: "Approve the connection with a Mac administrator account.")
        case .verifying: return .withHint("Verifying the pairing…", .connect)
        case .verificationFailed:
            let title = "Could not verify the pairing"
            return .init(title: title, step: .connect, action: ("Try Again", { await $0.retry() }), hint: title, recovery: .pairing)
        case .ready: return .init(title: "Connected")
        case .removing: return .init(title: "Disconnecting the helper…")
        case .blocked: return .init(title: "Setup needs attention", action: ("Try Again", { await $0.retry() }))
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
            window.isRestorable = false
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
    @ViewBuilder func activeStepCard(_ active: Bool) -> some View {
        if !active {
            self
        } else if #available(macOS 26, *) {
            glassEffect(.regular, in: .rect(cornerRadius: 16))
        } else {
            background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
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

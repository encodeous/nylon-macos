import AppKit
import SwiftUI

@main
struct MenuApp: App {
    // Not observed here: the app's body includes the menu bar icon, and redrawing that is slow (macOS redraws a copy
    // for every display), so it mustn't redraw on every status update. The icon watches store.icon instead.
    @NSApplicationDelegateAdaptor(LaunchSetup.self) private var launchSetup
    @Environment(\.openWindow) private var openWindow
    private var store: NodeStore { launchSetup.store }
    private static let runningIcon = menuBarIcon("MenuBarRunning")
    private static let stoppedIcon = menuBarIcon("MenuBarStopped")

    init() {
        Preferences.registerDefaults()
        MenuBarPanel.followIcon()
        // LSUIElement starts it without a Dock icon. It has one while a window is open, however the window opened (macOS
        // restores them at launch too), and goes back once the last one closes. The menu bar panel doesn't count: it
        // closes just as "Open nylon…" opens the main window, and would otherwise take the Dock icon away again.
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeMainNotification, object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                guard let window = note.object as? NSWindow, isAppWindow(window) else { return }
                if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
            }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                guard let window = note.object as? NSWindow, isAppWindow(window) else { return }
                DispatchQueue.main.async { // by now the window is gone
                    if openWindows().isEmpty { NSApp.setActivationPolicy(.accessory) }
                }
            }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(store: store)
        } label: {
            MenuBarIcon(icon: store.icon, running: Self.runningIcon, stopped: Self.stoppedIcon)
        }
        .menuBarExtraStyle(.window)
        .onChange(of: ObjectIdentifier(store), initial: true) {
            launchSetup.bind(openWindow)
        }
        Window("Nylon", id: "main") {
            MainWindow(store: store)
        }
        .defaultSize(width: 1080, height: 720)
        Window("Set Up Nylon", id: "setup") {
            SetupView(helper: store.helper)
        }
        .windowResizability(.contentSize)
        WindowGroup("Edit Config", id: "editor", for: ConfigFile.self) { $file in
            if let file { ConfigEditor(store: store, file: file) }
        }
        .defaultSize(width: 760, height: 620)
        Settings {
            SettingsView(store: store, helper: store.helper)
        }
        .commands {
            // Cmd-Q with a window open closes the window; the app keeps running (its status menu has Quit)
            CommandGroup(replacing: .appTermination) {
                Button("Close Window") { openWindows().forEach { $0.performClose(nil) } }.keyboardShortcut("q")
            }
        }
    }
}

@MainActor private final class LaunchSetup: NSObject, NSApplicationDelegate {
    let store = NodeStore()
    private var openWindow: OpenWindowAction?
    private var didFinishLaunching = false
    private var didCheckSetup = false

    func bind(_ action: OpenWindowAction) {
        guard !didCheckSetup else { return }
        openWindow = action
        checkSetup()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        didFinishLaunching = true
        checkSetup()
    }

    private func checkSetup() {
        // AppKit launch and SwiftUI scene installation can finish in either order.
        guard didFinishLaunching, !didCheckSetup, let openWindow else { return }
        didCheckSetup = true
        self.openWindow = nil
        Task {
            guard await store.setupAtLaunch() != .ready, store.helper.setup != .ready else { return }
            showWindow { openWindow(id: "setup") }
        }
    }
}

// The app's real windows (main, editors, Settings), not its status item or menu bar panel
@MainActor func openWindows() -> [NSWindow] {
    NSApp.windows.filter { $0.isVisible && isAppWindow($0) }
}

@MainActor func isAppWindow(_ window: NSWindow) -> Bool {
    window.canBecomeMain && !MenuBarPanel.isPanel(window)
}

// An SVG from Assets.xcassets, sized for the menu bar. The catalog marks it a template image, so macOS tints it to
// match a light or dark menu bar.
func menuBarIcon(_ name: String) -> NSImage {
    let image = NSImage(named: name)!.copy() as! NSImage // built into the app, so it can't be missing; a copy to resize
    image.size = NSSize(width: 18, height: 18)
    return image
}

struct MenuBarIcon: View {
    @ObservedObject var icon: NodeStore.Icon
    let running: NSImage
    let stopped: NSImage

    var body: some View {
        Image(nsImage: icon.running ? running : stopped)
            .accessibilityLabel("Nylon")
    }
}

// Without a Dock icon the app isn't in Cmd-Tab, so its windows get lost behind others.
// While a window is open the app is a regular one; MenuApp turns it back when the last window closes.
@MainActor func showWindow(_ open: () -> Void) {
    NSApp.setActivationPolicy(.regular)
    NSApp.activate()
    open()
}

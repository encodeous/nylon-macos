import AppKit
import SwiftUI

@main
struct MenuApp: App {
    @StateObject private var store = NodeStore()
    private static let runningIcon = menuBarIcon("MenuBarRunning")
    private static let stoppedIcon = menuBarIcon("MenuBarStopped")

    init() {
        // LSUIElement starts it without a Dock icon. showWindow gives it one while a window is open; go back once the last one closes
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { _ in
            DispatchQueue.main.async { // by now the window is gone
                if openWindows().isEmpty { NSApp.setActivationPolicy(.accessory) }
            }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(store: store)
        } label: {
            MenuBarIcon(image: store.running ? Self.runningIcon : Self.stoppedIcon, store: store)
        }
        Settings {
            SettingsView(store: store, helper: store.helper)
        }
        WindowGroup("Log", id: "log", for: String.self) { $network in
            if let network { LogView(store: store, network: network) }
        }
        .commands {
            // Cmd-Q with a window open closes the window; the app keeps running (its status menu has Quit)
            CommandGroup(replacing: .appTermination) {
                Button("Close Window") { openWindows().forEach { $0.performClose(nil) } }.keyboardShortcut("q")
            }
        }
    }
}

// The app's real windows (Settings, logs), not its status item
@MainActor func openWindows() -> [NSWindow] {
    NSApp.windows.filter { $0.isVisible && $0.canBecomeMain }
}

// An SVG from Assets.xcassets, sized for the menu bar. The catalog marks it a template image, so macOS tints it to
// match a light or dark menu bar.
func menuBarIcon(_ name: String) -> NSImage {
    let image = NSImage(named: name)!.copy() as! NSImage // built into the app, so it can't be missing; a copy to resize
    image.size = NSSize(width: 18, height: 18)
    return image
}

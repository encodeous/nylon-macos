import AppKit
import SwiftUI

@main
struct MenuApp: App {
    @StateObject private var store = NodeStore()
    private static let runningIcon = menuBarIcon("MenuBarRunning")
    private static let stoppedIcon = menuBarIcon("MenuBarStopped")

    init() {
        // menu bar only; without an app bundle it would otherwise start background-only
        NSApplication.shared.setActivationPolicy(.accessory)
        // showSettings makes it a regular app while a window is open; go back once the last one closes
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
            MenuBarIcon(image: store.peers == nil ? Self.stoppedIcon : Self.runningIcon, needsSetup: store.nodes == nil)
        }
        Settings {
            SettingsView(store: store)
        }
        .commands {
            // Cmd-Q with a window open closes the window; the menu bar app keeps running (its menu has Quit)
            CommandGroup(replacing: .appTermination) {
                Button("Close Window") { openWindows().forEach { $0.performClose(nil) } }.keyboardShortcut("q")
            }
        }
    }
}

// The app's real windows (Settings), not its menu bar item
@MainActor func openWindows() -> [NSWindow] {
    NSApp.windows.filter { $0.isVisible && $0.canBecomeMain }
}

// An SVG from Resources/, sized for the menu bar
func menuBarIcon(_ name: String) -> NSImage {
    let image = Bundle.module.image(forResource: name)! // built into the app, so it can't be missing
    image.size = NSSize(width: 18, height: 18)
    image.isTemplate = true // macOS tints it to match a light or dark menu bar
    return image
}

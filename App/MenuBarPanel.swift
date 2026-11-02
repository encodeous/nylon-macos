import AppKit

// MenuBarExtra places its panel under the icon once, as it opens. In a crowded menu bar the icon can move just after,
// as other items make room when nylon becomes the active app, and the panel is left behind. This moves the panel back
// under the icon whenever the icon moves while it's open.
enum MenuBarPanel {
    @MainActor static func followIcon() {
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                // the app's own status bar windows are its icon, one per display
                guard let icon = note.object as? NSWindow, isStatusBar(icon), let screen = icon.screen, icon.frame.width > 0 else { return }
                for panel in NSApp.windows where isPanel(panel) && panel.isVisible && panel.screen == screen {
                    var frame = panel.frame
                    frame.origin.x = min(max(icon.frame.minX, screen.visibleFrame.minX), screen.visibleFrame.maxX - frame.width)
                    if frame != panel.frame { panel.setFrame(frame, display: true) }
                }
            }
        }
    }

    // SwiftUI and AppKit don't make these classes public, so they're known by name
    private static func isStatusBar(_ window: NSWindow) -> Bool {
        String(describing: type(of: window)).contains("StatusBarWindow")
    }

    static func isPanel(_ window: NSWindow) -> Bool {
        String(describing: type(of: window)).hasPrefix("MenuBarExtraWindow")
    }
}

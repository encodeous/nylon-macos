import Foundation
import Testing
@testable import NylonApp

@Test func loadsMenuBarIcons() {
    for name in ["MenuBarRunning", "MenuBarStopped"] {
        let icon = menuBarIcon(name)
        #expect(icon.isValid && icon.isTemplate)
        #expect(icon.size.height == 18)
    }
}

// The Dock and Finder show AppIcon.icns only if Info.plist names it
@Test func bundleNamesItsAppIcon() {
    #expect(Bundle.main.infoDictionary?["CFBundleIconFile"] as? String == "AppIcon")
    #expect(Bundle.main.url(forResource: "AppIcon", withExtension: "icns") != nil)
}

import Testing
@testable import NylonApp

@Test func loadsMenuBarIcons() {
    for name in ["MenuBarRunning", "MenuBarStopped"] {
        let icon = menuBarIcon(name)
        #expect(icon.isValid && icon.isTemplate)
        #expect(icon.size.height == 18)
    }
}

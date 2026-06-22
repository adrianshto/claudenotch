import SwiftUI

@main
struct ClaudeNotchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Menubar-only app (no window). LSUIElement=YES hides the dock icon.
        MenuBarExtra("Claude Notch", systemImage: "bell.badge.fill") {
            Button("Test notch ping") { appDelegate.testPing() }
            Divider()
            Button("Quit Claude Notch") { NSApplication.shared.terminate(nil) }
        }
    }
}

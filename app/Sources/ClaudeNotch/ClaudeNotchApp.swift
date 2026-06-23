import SwiftUI

@main
struct ClaudeNotchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Menubar-only app (no window). LSUIElement=YES hides the dock icon.
        MenuBarExtra("Claude Notch", systemImage: "bell.badge.fill") {
            Text("Claude Notch — hover the notch for your agents")
                .font(.caption)
            Divider()
            Button("Test Notch Ping") { appDelegate.testPing() }
            Divider()
            Button("Quit Claude Notch") { NSApplication.shared.terminate(nil) }
        }
    }
}

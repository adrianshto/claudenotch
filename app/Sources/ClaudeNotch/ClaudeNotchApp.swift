import SwiftUI

@main
struct ClaudeNotchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    // When on, pings for the Cursor window you're currently focused on are suppressed
    // (you're working in it). Other windows still ping. Read live by AppDelegate.
    @AppStorage("focusMute") private var focusMute = true

    var body: some Scene {
        // Menubar-only app (no window). LSUIElement=YES hides the dock icon.
        MenuBarExtra("Claude Notch", systemImage: "bell.badge.fill") {
            Text("Claude Notch — hover the notch for your agents")
                .font(.caption)
            Divider()
            Toggle("Quiet the window I'm working in", isOn: $focusMute)
            Button("Test Notch Ping") { appDelegate.testPing() }
            Divider()
            Button("Quit Claude Notch") { NSApplication.shared.terminate(nil) }
        }
    }
}

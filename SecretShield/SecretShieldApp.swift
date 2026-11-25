import SwiftUI

/// Menu-bar-only app: `LSUIElement = YES` (set in build settings) hides the Dock icon.
@main
struct SecretShieldApp: App {
    @State private var mirror = MirrorController()

    var body: some Scene {
        MenuBarExtra("SecretShield", systemImage: mirror.isRunning ? "eye.slash.fill" : "eye.slash") {
            Button("Start mirror") { Task { await mirror.start() } }
                .disabled(mirror.isRunning)
            Button("Stop mirror") { Task { await mirror.stop() } }
                .disabled(!mirror.isRunning)
            #if DEBUG
            Divider()
            Toggle("Save viewer frames (debug)", isOn: Bindable(mirror).saveViewerFrames)
            Toggle("Record raw vs shield next session (debug)", isOn: Bindable(mirror).recordComparison)
                .disabled(mirror.isRunning)
            Button("AX Probe (debug)") { Task { await mirror.runAXProbe() } }
            #endif
            Divider()
            Button("Quit SecretShield") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}

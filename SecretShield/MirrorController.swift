import AppKit
import ScreenCaptureKit

/// Owns the mirror: permission check → CaptureService → FrameRenderer in the shareable window.
@MainActor @Observable
final class MirrorController: NSObject, NSWindowDelegate {
    private(set) var isRunning = false
    @ObservationIgnored private var capture: CaptureService?
    @ObservationIgnored private var window: NSWindow?
    @ObservationIgnored private let renderer = FrameRenderer()

    func start() async {
        guard !isRunning else { return }
        guard hasScreenRecordingPermission() else { return showPermissionAlert() }
        isRunning = true

        let renderer = self.renderer
        let service = CaptureService(
            processor: PassthroughProcessor(),
            onFrame: { frame in
                DispatchQueue.main.async { MainActor.assumeIsolated { renderer.show(frame) } }
            },
            onStop: { [weak self] error in
                Task { await self?.stop() }
                self?.showError(error)
            })
        do {
            try await service.start()
            capture = service
            showWindow()
        } catch {
            isRunning = false
            if (error as? SCStreamError)?.code == .userDeclined { showPermissionAlert() } else { showError(error) }
        }
    }

    func stop() async {
        guard isRunning else { return }
        isRunning = false
        window?.orderOut(nil)
        renderer.clear()
        let service = capture
        capture = nil
        await service?.stop()
    }

    func windowWillClose(_ notification: Notification) {
        Task { await stop() }
    }

    // MARK: Window

    private func showWindow() {
        let window = self.window ?? makeWindow()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate() // menu bar apps aren't frontmost by default
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 600),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "SecretShield – Share this window"
        window.contentView = renderer
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        return window
    }

    // MARK: Permission

    /// Preflight checks silently; Request shows the system prompt the first time only.
    /// Either way, a newly granted permission usually only takes effect after relaunching the app.
    private func hasScreenRecordingPermission() -> Bool {
        CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess()
    }

    private func showPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "SecretShield needs Screen Recording permission"
        alert.informativeText = """
            Turn on SecretShield in System Settings → Privacy & Security → Screen & System Audio Recording, \
            then quit and reopen SecretShield. Everything stays on this Mac.
            """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    private func showError(_ error: any Error) {
        let alert = NSAlert(error: error)
        alert.messageText = "Mirror stopped"
        alert.informativeText = error.localizedDescription
        NSApp.activate()
        alert.runModal()
    }
}

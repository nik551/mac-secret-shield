import AppKit
import ScreenCaptureKit

/// Owns the mirror: permission check → CaptureService → FrameRenderer in the shareable window.
@MainActor @Observable
final class MirrorController: NSObject, NSWindowDelegate {
    private(set) var isRunning = false
    @ObservationIgnored private var capture: CaptureService?
    @ObservationIgnored private var window: NSWindow?
    @ObservationIgnored private let renderer = FrameRenderer()
    #if DEBUG
    @ObservationIgnored private let saver = ViewerFrameSaver()
    /// Debug-only, off by default: write every frame the mirror shows to ~/Library/Caches/SecretShield/ViewerFrames.
    var saveViewerFrames = false { didSet { saver.setEnabled(saveViewerFrames) } }
    #endif

    #if DEBUG
    override init() {
        super.init()
        // Debug-only: `open SecretShield.app --args -SecretShieldAutostart YES [-SecretShieldSaveFrames YES]`
        // starts mirroring (and saving viewer frames for leak-check.swift) without a click.
        if UserDefaults.standard.bool(forKey: "SecretShieldSaveFrames") { saveViewerFrames = true; saver.setEnabled(true) } // didSet may not run in init
        if UserDefaults.standard.bool(forKey: "SecretShieldAutostart") { Task { await start() } }
    }
    #endif

    func start() async {
        guard !isRunning else { return }
        guard hasScreenRecordingPermission() else { return showPermissionAlert() }
        let detector: SecretDetector
        do { detector = try SecretDetector.bundled() } catch { return showError(error) } // no patterns: don't mirror
        isRunning = true

        let displayID = CGMainDisplayID() // capture the display with the menu bar at start
        let renderer = self.renderer
        #if DEBUG
        let saver = self.saver
        #endif
        let buffer = DelayBuffer(recognizer: VisionTextRecognizer(), detector: detector,
                                 windowSource: LiveWindowSource(displayID: displayID)) { frame, stats in
            #if DEBUG
            saver.save(frame)
            #endif
            DispatchQueue.main.async { MainActor.assumeIsolated { renderer.show(frame, stats: stats) } }
        }
        let service = CaptureService(
            onFrame: { buffer.submit($0) },
            onStop: { [weak self] error in
                Task { await self?.stop() }
                self?.showError(error)
            })
        do {
            try await service.start(displayID: displayID)
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

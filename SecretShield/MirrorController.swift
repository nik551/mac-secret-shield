import AppKit
import os
import ScreenCaptureKit

/// Owns the mirror: permission check → CaptureService → FrameRenderer in the shareable window.
@MainActor @Observable
final class MirrorController: NSObject, NSWindowDelegate {
    private(set) var isRunning = false
    @ObservationIgnored private var capture: CaptureService?
    @ObservationIgnored private var axSource: AXTerminalSource?
    @ObservationIgnored private var window: NSWindow?
    @ObservationIgnored private let renderer = FrameRenderer()
    #if DEBUG
    @ObservationIgnored private let saver = ViewerFrameSaver()
    /// Debug-only, off by default: write every frame the mirror shows to ~/Library/Caches/SecretShield/ViewerFrames.
    var saveViewerFrames = false {
        didSet {
            guard saveViewerFrames != oldValue else { return }
            if saveViewerFrames, !confirmFrameSaving() { saveViewerFrames = false; return }
            saver.setEnabled(saveViewerFrames)
        }
    }
    /// Debug-only, off by default: record raw.mov + shield.mov for the next mirroring session.
    var recordComparison = false {
        didSet {
            guard recordComparison != oldValue, recordComparison, !confirmRecording() else { return }
            recordComparison = false
        }
    }
    @ObservationIgnored private var recorder: ComparisonRecorder?
    #endif

    #if DEBUG
    override init() {
        super.init()
        // Debug-only: `open SecretShield.app --args -SecretShieldAutostart YES` starts mirroring without a click.
        // (Frame saving has no launch flag on purpose: it is only turned on from the menu, with a confirmation.)
        // `-SecretShieldAXProbe YES` runs the Gate 1 AX probe once at launch (same as the menu item).
        // `-SecretShieldRecordComparison YES` records raw vs shield video (typed by the developer = explicit opt-in);
        // `-SecretShieldStopAfter <seconds>` then stops the mirror by itself so the videos are closed properly.
        if UserDefaults.standard.bool(forKey: "SecretShieldRecordComparison") { recordComparison = true }
        let stopAfter = UserDefaults.standard.double(forKey: "SecretShieldStopAfter")
        if stopAfter > 0 { Task { try? await Task.sleep(for: .seconds(stopAfter)); await stop() } }
        // `-SecretShieldStress YES` runs one Gate 2 stress run (needs the mirror running, see -SecretShieldAutostart).
        if UserDefaults.standard.bool(forKey: "SecretShieldDumpITerm") { axProbe.dumpITermWindows() }
        if UserDefaults.standard.bool(forKey: "SecretShieldClosePages") { Task { await axProbe.closePages() } }
        if UserDefaults.standard.bool(forKey: "SecretShieldStress") {
            let delay = UserDefaults.standard.double(forKey: "SecretShieldStressDelay")
            Task { try? await Task.sleep(for: .seconds(delay)); _ = await axProbe.stress(); await stop() }
        }
        if UserDefaults.standard.bool(forKey: "SecretShieldAXProbe") {
            let delay = UserDefaults.standard.double(forKey: "SecretShieldAXProbeDelay") // optional: seconds to wait first
            Task { try? await Task.sleep(for: .seconds(delay)); await runAXProbe() }
        }
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
        recorder = recordComparison ? ComparisonRecorder() : nil
        let recorder = self.recorder
        #endif
        // Terminal.app / iTerm2 text comes from Accessibility when allowed; without it they stay on OCR.
        let prompt = ["AXTrustedCheckOptionPrompt": true] as CFDictionary // asks once if not yet allowed
        let axSource = AXIsProcessTrustedWithOptions(prompt) ? AXTerminalSource(detector: detector, displayID: displayID) : nil
        axSource?.start()
        self.axSource = axSource
        let buffer = DelayBuffer(recognizer: VisionTextRecognizer(), detector: detector,
                                 windowSource: LiveWindowSource(displayID: displayID), axSource: axSource) { frame, stats in
            #if DEBUG
            saver.save(frame)
            recorder?.append(frame, to: "shield", at: Frame.now()) // when viewers saw it
            #endif
            DispatchQueue.main.async { MainActor.assumeIsolated { renderer.show(frame, stats: stats) } }
        }
        let service = CaptureService(
            onFrame: { frame in
                #if DEBUG
                recorder?.append(frame, to: "raw", at: frame.captureTime) // what the display really showed
                #endif
                buffer.submit(frame)
            },
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
        #if DEBUG
        saveViewerFrames = false
        #endif
        window?.orderOut(nil)
        renderer.clear()
        let service = capture
        capture = nil
        await service?.stop()
        axSource?.stop() // clears this session's text hashes and masks
        axSource = nil
        #if DEBUG
        if let recorder {
            self.recorder = nil
            recordComparison = false
            let dropped = await recorder.finish()
            Self.log.notice("comparison recording closed; skipped frames: \(dropped.description, privacy: .public)")
            NSWorkspace.shared.activateFileViewerSelecting([recorder.folder])
        }
        #endif
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

    #if DEBUG
    @ObservationIgnored private let axProbe = AXProbe()

    func runAXProbe() async {
        guard let report = await axProbe.run() else {
            let alert = NSAlert()
            alert.messageText = "AX probe couldn't run"
            alert.informativeText = """
                Give SecretShield Accessibility permission (System Settings → Privacy & Security → Accessibility), \
                and make sure TestFixtures/fake.env exists, then try again.
                """
            NSApp.activate()
            alert.runModal()
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([report])
    }

    private static let log = Logger(subsystem: "SecretShield", category: "recorder")

    private func confirmRecording() -> Bool {
        if UserDefaults.standard.bool(forKey: "SecretShieldRecordComparison") { return true } // opted in on the command line
        let alert = NSAlert()
        alert.messageText = "Record raw and shielded video?"
        alert.informativeText = """
            The next mirroring session will be recorded twice: raw.mov (the real screen, unredacted) and shield.mov \
            (what viewers see), in ~/Library/Caches/SecretShield/Recordings. Only do this while the screen shows \
            synthetic test secrets (TestFixtures/fake.env), never real ones. Recording stops with the mirror.
            """
        alert.addButton(withTitle: "Record")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func confirmFrameSaving() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Save viewer frames to disk?"
        alert.informativeText = """
            Every frame the mirror shows will be written to ~/Library/Caches/SecretShield/ViewerFrames for \
            leak-check.swift. Only do this while the screen shows synthetic test secrets \
            (TestFixtures/fake.env), never real ones. Saving stops when the mirror stops.
            """
        alert.addButton(withTitle: "Save Frames")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }
    #endif

    private func showError(_ error: any Error) {
        let alert = NSAlert(error: error)
        alert.messageText = "Mirror stopped"
        alert.informativeText = error.localizedDescription
        NSApp.activate()
        alert.runModal()
    }
}

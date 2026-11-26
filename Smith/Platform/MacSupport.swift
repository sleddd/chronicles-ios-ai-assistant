#if os(macOS)
import AppKit
import SwiftUI
import Carbon.HIToolbox
import ServiceManagement
import Speech
import AVFoundation

/// The floating, borderless glass panel (about 420 × 640) opened by the hotkey or the menu bar orb.
@MainActor
final class PanelController {
    static let shared = PanelController()
    private var panel: NSPanel?

    func toggle<Content: View>(@ViewBuilder content: () -> Content) {
        if let panel, panel.isVisible { panel.orderOut(nil); return }
        show(content: content)
    }

    func show<Content: View>(@ViewBuilder content: () -> Content) {
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 640),
                            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .resizable],
                            backing: .buffered, defer: false)
            p.titleVisibility = .hidden
            p.titlebarAppearsTransparent = true
            p.isMovableByWindowBackground = true
            p.isFloatingPanel = true
            p.level = .floating
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = true
            p.standardWindowButton(.miniaturizeButton)?.isHidden = true
            p.standardWindowButton(.zoomButton)?.isHidden = true
            panel = p
        }
        guard let panel else { return }
        let host = NSHostingView(rootView: content().clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous)))
        panel.contentView = host
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: f.maxX - 440, y: f.maxY - 660))
        }
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func hide() { panel?.orderOut(nil) }
}

/// ⌥Space opens Smith's panel from anywhere. Carbon hotkeys work inside the sandbox
/// and need no Accessibility permission.
@MainActor
final class HotKey {
    static let shared = HotKey()
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    var action: (@MainActor () -> Void)?

    func register(keyCode: UInt32 = UInt32(kVK_Space), modifiers: UInt32 = UInt32(optionKey)) {
        unregister()
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            Task { @MainActor in HotKey.shared.action?() }
            return noErr
        }, 1, &spec, nil, &handler)
        let id = EventHotKeyID(signature: OSType(0x534D5448), id: 1) // "SMTH"
        RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref)
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
        ref = nil; handler = nil
    }
}

/// Start at login, as a menu bar companion.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    static func set(_ on: Bool) {
        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } } catch {}
    }
}

/// Notices the first screen wake or unlock of the day.
@MainActor
final class WakeWatcher {
    static let shared = WakeWatcher()
    var onFirstWakeOfDay: (() -> Void)?
    private var observers: [Any] = []

    private var lastGreetingDay: (() -> String?)?

    func start(lastGreetingDay: @escaping () -> String?) {
        self.lastGreetingDay = lastGreetingDay
        // Only after the Mac is unlocked. The screen waking comes before anyone has
        // signed in, and the briefing (doses, bills) must never be read out at the login screen.
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { WakeWatcher.shared.check() }
        })
    }

    /// The day already acted on here: the saved greeting day is only written once
    /// the briefing has finished, and a second unlock notice can arrive before that.
    private var handledDay: String?

    private func check() {
        let today = Self.todayKey()
        guard handledDay != today, lastGreetingDay?() != today, Calendar.current.component(.hour, from: Date()) >= 4 else { return }
        handledDay = today
        onFirstWakeOfDay?()
    }

    static func todayKey() -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }
}

/// Optional: Smith's own "Hey Smith" listener while he's in the menu bar.
/// Audio is handled on the Mac; nothing is sent until the phrase is heard.
@MainActor
final class WakeWordListener {
    static let shared = WakeWordListener()
    private let engine = AVAudioEngine()
    private var task: SFSpeechRecognitionTask?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var restartTimer: Timer?
    private(set) var isRunning = false
    private var pausedUntil: Date?
    private var fired = false
    private var waitAfterWake: Timer?
    /// Called with whatever was said after "Hey Smith" (may be empty).
    var onWake: ((String) -> Void)?

    func start() {
        guard !isRunning, let recognizer, recognizer.supportsOnDeviceRecognition else { return }
        if let pausedUntil, pausedUntil > Date() { return }
        isRunning = true
        begin()
    }

    func stop() {
        isRunning = false
        round += 1
        restartTimer?.invalidate()
        // Stopped just after the phrase was heard: nothing is handed over a moment later
        waitAfterWake?.invalidate(); waitAfterWake = nil
        task?.cancel(); task = nil
        request?.endAudio(); request = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
    }

    func pause(hours: Double = 1) {
        pausedUntil = Date().addingTimeInterval(hours * 3600)
        stop()
        pauseTimer?.invalidate()
        pauseTimer = Timer.scheduledTimer(withTimeInterval: hours * 3600, repeats: false) { _ in
            Task { @MainActor in
                // Switched off in Settings meanwhile: it stays off
                guard AppModel.shared.store.settings.macWakeWord else { return }
                WakeWordListener.shared.start()
            }
        }
    }

    private var pauseTimer: Timer?

    /// Which recognition request is the current one. A cancelled request still reports
    /// (as a failure); acting on that would cancel its replacement, whose failure would
    /// cancel the next, restarting the microphone over and over.
    private var round = 0

    private func begin() {
        guard isRunning, let recognizer else { return }
        round += 1
        let mine = round
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.requiresOnDeviceRecognition = true
        req.shouldReportPartialResults = true
        req.contextualStrings = ["Hey Smith", "Smith"]
        request = req
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        // No microphone: a tap with an empty format would stop the app
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { isRunning = false; return }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: input.outputFormat(forBus: 0), block: VoiceIO.tap(req) { @Sendable _ in })
        engine.prepare()
        try? engine.start()
        fired = false
        task = recognizer.recognitionTask(with: req, resultHandler: VoiceIO.results { @Sendable [weak self] transcript, _, failed in
            Task { @MainActor in
                guard let self, self.round == mine, self.isRunning else { return }
                if let text = transcript?.lowercased(),
                   let r = text.range(of: "hey smith", options: .backwards) ?? text.range(of: "hi smith", options: .backwards) {
                    let after = String(text[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
                    self.fired = true
                    // Give them a moment to finish the sentence, then hand it over.
                    self.waitAfterWake?.invalidate()
                    self.waitAfterWake = Timer.scheduledTimer(withTimeInterval: 1.4, repeats: false) { _ in
                        Task { @MainActor in
                            self.stop()
                            self.onWake?(after)
                        }
                    }
                }
                if failed && !self.fired {
                    // A real failure: start again after a breath, not in a tight loop
                    self.round += 1
                    try? await Task.sleep(for: .seconds(1))
                    if self.round == mine + 1, self.isRunning { self.recycle() }
                }
            }
        })
        // Recycle the recognizer regularly so it doesn't build up a long transcript.
        restartTimer?.invalidate()
        restartTimer = Timer.scheduledTimer(withTimeInterval: 45, repeats: false) { _ in
            Task { @MainActor in
                let me = WakeWordListener.shared
                if me.round == mine, !me.fired { me.recycle() }
            }
        }
    }

    private func recycle() {
        round += 1   // whatever the old request still reports is ignored
        task?.cancel(); task = nil
        request?.endAudio(); request = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        if isRunning { begin() }
    }
}
#endif

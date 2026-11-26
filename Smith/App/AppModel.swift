import Foundation
import Observation
import SwiftUI
import SmithCore

/// Ties the pieces together: store, brain, voice, weather and sync.
@MainActor @Observable
final class AppModel {
    static let shared = AppModel()

    let store: SmithStore
    let voice: VoiceIO
    let weather: WeatherService
    let brain: SmithBrain
    let chronicles: ChroniclesConnection
    let safety: SafetyCenter

    var importMessage: String?
    /// The typing box (shared, so a stopped or edited message can come back to it).
    var draft = ""
    var pendingOlderImport: URL?
    var showChat = false
    /// What fills the main window under the tabs.
    enum Page: Equatable { case home, today, goals, me, letters, settings }
    var page: Page = .home { didSet { if page != .letters { lettersBoxOpen = false } } }
    /// The Letters page is showing the Letters box.
    var lettersBoxOpen = false
    /// Kept for callers that "open" a screen: it now shows as a page in the window.
    var sheet: Sheet? {
        get { nil }
        set {
            switch newValue {
            case .none: page = .home
            case .today: page = .today
            case .goals: page = .goals
            case .me: page = .me
            case .letters: page = .letters
            case .settings: page = .settings
            }
        }
    }
    var deleteSourceOffer: URL?

    enum Sheet: String, Identifiable { case today, goals, me, letters, settings; var id: String { rawValue } }

    private init() {
        store = SmithStore()
        voice = VoiceIO()
        weather = WeatherService()
        chronicles = ChroniclesConnection(store: store)
        safety = SafetyCenter(chronicles: chronicles)
        brain = SmithBrain(store: store, voice: voice, weather: weather, chronicles: chronicles, safety: safety)
        // The old built-in "Henry" becomes the assistant's own name (a name you chose stays)
        if !store.settings.lettersRenamed {
            store.updateSettings { s in
                if s.henry.name == "Henry" { s.henry.name = "" }
                s.lettersRenamed = true
            }
        }
        // Privacy is controlled from Chronicles now; Smith's old duplicates are cleared once
        if !store.settings.privacyFromChronicles {
            store.updateSettings { s in
                s.neverMentionTopics = []; s.privateBills = []; s.journalMode = .general
                s.privacyFromChronicles = true
            }
        }
        applyVoiceSettings()
        store.onLoaded = { [unowned self] in
            self.chronicles.storeLoaded()
            self.applyVoiceSettings()
        }
        weather.placeProvider = { [unowned self] in self.weatherPlace }
    }

    /// Where the weather is for. Chronicles' home city falls back to this
    /// device's location when Chronicles has none; a chosen city always wins.
    var weatherPlace: HomePlace? {
        let s = store.settings
        switch s.weatherSource {
        case .city: return s.weatherCity ?? s.chroniclesHome
        case .chronicles: return s.chroniclesHome
        case .device: return nil
        }
    }

    /// Smith's voice: ElevenLabs when it's on with a key and a voice chosen, else Apple's.
    var smithSpeaker: VoiceIO.Speaker {
        let s = store.settings
        if s.useElevenLabs, let v = s.elevenSmithVoice, ElevenLabs.apiKey != nil { return .eleven(voice: v, model: s.elevenModel) }
        return .apple(s.smithVoiceID)
    }

    /// The letters voice: letters aren't in a hurry, so the most expressive model.
    /// With no letters voice chosen, they're read in Smith's own voice.
    var henrySpeaker: VoiceIO.Speaker {
        let s = store.settings
        if s.useElevenLabs, let v = s.elevenHenryVoice ?? s.elevenSmithVoice, ElevenLabs.apiKey != nil { return .eleven(voice: v, model: .v4) }
        return .apple(s.henryVoiceID ?? s.smithVoiceID)
    }

    func applyVoiceSettings() {
        voice.smithVoice = smithSpeaker
        voice.rate = store.settings.speechRate
        voice.pauseWait = store.settings.pauseWait
        APIKeys.setPreferChronicles(store.settings.useChroniclesAIKey)
        UserDefaults.standard.set(store.settings.fahrenheit, forKey: "fahrenheit")
    }

    /// On launch and whenever the app comes forward.
    func becameActive() async {
        // Started while the device was locked (Siri, say): the files can be read now
        store.loadIfNeeded()
        brain.refreshHeadline()
        // (Mac ↔ iPad now share memories and letters through Chronicles; the local-network sync is retired)
        chronicles.checkAutoLock()
        await safety.refresh()
        if chronicles.isUnlocked { await chronicles.refresh() }
        await weather.refresh(fahrenheit: store.settings.fahrenheit)
    }

    // MARK: talking

    /// Tap: one question. Hold (or conversation mode): keeps listening after each reply until "that's all".
    func orbTapped() {
        switch voice.state {
        case .speaking: voice.stopSpeaking(); listenOnce()
        case .listening: voice.finishListening()
        case .idle: listenOnce()
        }
    }

    func orbHeld() {
        brain.conversationMode = true
        listenOnce()
    }

    func listenOnce() {
        guard chronicles.isUnlocked else { return }
        Task {
            guard await voice.requestPermissions() else { dictateIntoBox = false; importMessage = voice.permissionProblem; return }
            voice.listen { [weak self] text in
                Task { @MainActor in await self?.heard(text) }
            }
            // Didn't start (no microphone, no on-device recognition): say why, and don't
            // leave the next thing they say headed for the typing box
            if voice.state != .listening { dictateIntoBox = false; importMessage = voice.permissionProblem }
        }
    }

    /// Dictating into the typing box: what's said lands in the box to edit or add to, not sent.
    var dictateIntoBox = false

    /// The typing box's microphone: talk into the box. While already listening, stop
    /// and put the words in the box instead of sending them.
    func dictateToBox() {
        dictateIntoBox = true
        if voice.state == .listening { voice.finishListening() } else { listenOnce() }
    }

    private func heard(_ text: String) async {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if dictateIntoBox {
            dictateIntoBox = false
            guard !t.isEmpty else { return }
            draft = draft.trimmingCharacters(in: .whitespaces).isEmpty ? t : draft + " " + t
            return
        }
        guard !t.isEmpty else { brain.conversationMode = false; return }
        if Self.isGoodbye(t) {
            brain.conversationMode = false
            await brain.endConversation()
            showChat = false
            return
        }
        showChat = true
        await brain.send(t, spoken: true)
        if brain.conversationMode {
            voice.whenDoneSpeaking { [weak self] in self?.listenOnce() }
        }
    }

    static func isGoodbye(_ t: String) -> Bool {
        let s = t.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        // Only on its own: "I think that's all I ate today" mustn't end the conversation
        return ["that's all", "that is all", "that's all for now", "goodbye", "bye smith", "goodbye smith",
                "thanks, that's all", "thank you, that's all", "thanks smith, that's all", "ok, that's all", "okay, that's all"].contains(s)
    }

    func typed(_ text: String) {
        guard chronicles.isUnlocked else { return }
        showChat = true
        Task { await brain.send(text, spoken: false) }
    }

    /// Esc / Stop: stop listening (nothing is sent), stop speaking, and stop an
    /// answer in progress — your message comes back to the typing box.
    func stopAll() {
        dictateIntoBox = false
        if let taken = brain.stop() { draft = taken }
    }

    /// Edit: your latest message (and Smith's answer) taken back into the typing box.
    func editLast() {
        if let taken = brain.removeLastTurn() { draft = taken }
    }

    /// Delete: your latest message and Smith's answer, gone.
    func deleteLast() {
        brain.removeLastTurn()
        if brain.lines.isEmpty { showChat = false }
    }

    /// Start over: a clean chat, nothing kept from this one.
    func startOver() {
        brain.startOver()
        draft = ""
        showChat = false
    }

    var isBusy: Bool { voice.state != .idle || brain.isThinking }

    func endConversation() {
        voice.stopSpeaking()
        Task { await brain.endConversation() }
        showChat = false
    }

    func morningBriefing() {
        guard chronicles.isUnlocked else { return }
        showChat = true
        Task { await brain.briefing() }
    }

    // MARK: importing

    func importFile(_ url: URL, allowOlder: Bool = false) {
        Task {
            do {
                let r = try await Importer.importFile(url, into: store, allowOlder: allowOlder)
                importMessage = "Imported: " + r.text
                pendingOlderImport = nil
                deleteSourceOffer = url
                brain.refreshHeadline()
            } catch Importer.ImportError.older {
                pendingOlderImport = url
            } catch {
                importMessage = error.localizedDescription
            }
        }
    }

    func openURL(_ url: URL) {
        // A file handed to Smith replaces what the briefing reads: only once it's unlocked
        guard chronicles.isUnlocked else { importMessage = "Unlock Smith first, then open the file again."; return }
        if url.pathExtension == "smithdata" {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do { importMessage = try store.importBackup(Data(contentsOf: url)).text }
            catch { importMessage = error.localizedDescription }
        } else {
            importFile(url)
        }
    }

    func deleteSource(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do { try FileManager.default.removeItem(at: url); importMessage = "Deleted the export file." }
        catch { importMessage = "Couldn't delete it. You can remove it in Files or Finder." }
        deleteSourceOffer = nil
    }
}

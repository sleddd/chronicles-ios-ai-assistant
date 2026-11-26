import Foundation
import AVFoundation
import Speech
import Observation

/// Listening (on-device speech recognition) and speaking (Apple voices).
@MainActor @Observable
final class VoiceIO: NSObject {
    enum State: Equatable { case idle, listening, speaking }
    private(set) var state: State = .idle
    /// 0…1, for the orb's ripple while listening and swirl while speaking.
    private(set) var level: Float = 0
    private(set) var partialTranscript = ""
    private(set) var permissionProblem: String?

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var silenceTimer: Timer?
    private var onFinal: ((String) -> Void)?

    private let synth = AVSpeechSynthesizer()
    private var onSpeechDone: (() -> Void)?

    var rate: Float = 0.5
    /// Seconds of silence before Smith decides you're done. 0 = wait until you tap.
    var pauseWait: Double = 3

    override init() {
        super.init()
        synth.delegate = self
        watchForInterruptions()
    }

    // MARK: permissions

    func requestPermissions() async -> Bool {
        let speech = await Self.authorizeSpeech()
        let mic = await AVAudioApplication.requestRecordPermission()
        permissionProblem = !speech ? "Speech recognition is off for Smith in Settings." : !mic ? "The microphone is off for Smith in Settings." : nil
        return speech && mic
    }

    // MARK: listening

    /// The microphone feeds whichever recognition request is current, so a new
    /// one can take over mid-sentence without stopping the microphone.
    nonisolated final class RequestBox: @unchecked Sendable {
        private let lock = NSLock()
        private var request: SFSpeechAudioBufferRecognitionRequest?
        func set(_ r: SFSpeechAudioBufferRecognitionRequest?) { lock.withLock { request = r } }
        func append(_ b: AVAudioPCMBuffer) { lock.withLock { request?.append(b) } }
    }
    private let box = RequestBox()
    /// What was heard in earlier pieces of this turn (Apple's recognizer ends a
    /// piece after about a minute, or at a long pause; the next piece carries on).
    private var committed = ""
    /// The current piece's text so far.
    private var pieceText = ""
    private var restarts = 0

    /// Listens until you pause (your pause setting) or tap the orb, however long
    /// you talk, then calls `done` with everything that was said.
    func listen(done: @escaping (String) -> Void) {
        stopSpeaking()
        permissionProblem = nil
        guard let recognizer, recognizer.isAvailable else { permissionProblem = "Speech recognition isn't available right now."; return }
        // Smith says speech stays on the device, so it does: where this language has no
        // on-device recognition, nothing is recorded rather than sent to Apple's servers
        guard recognizer.supportsOnDeviceRecognition else {
            permissionProblem = "On-device speech recognition isn't available for this device's language, so Smith can't listen. You can still type."
            return
        }
        cancelListening()
        onFinal = done
        partialTranscript = ""
        committed = ""; pieceText = ""; restarts = 0

        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetoothHFP, .duckOthers])
        try? session.setActive(true, options: .notifyOthersOnDeactivation)
        #endif

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        // No microphone (or it was unplugged): installing a tap with an empty format stops the app
        guard format.sampleRate > 0, format.channelCount > 0 else { permissionProblem = "Smith can't find a microphone."; return }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format,
                         block: Self.tap(box) { @Sendable [weak self] lvl in Task { @MainActor in self?.level = lvl } })
        engine.prepare()
        do { try engine.start() } catch { permissionProblem = "Couldn't start the microphone."; return }
        state = .listening
        listenStarted = Date()
        startPiece()
        restartSilenceTimer(initial: true)
    }

    /// A new recognition request, fed by the same microphone.
    private func startPiece() {
        guard let recognizer, state == .listening else { return }
        task?.cancel()
        request?.endAudio()
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = true
        req.addsPunctuation = true
        request = req
        box.set(req)
        pieceText = ""
        let pieceID = ObjectIdentifier(req)
        task = recognizer.recognitionTask(with: req, resultHandler: Self.results { @Sendable [weak self] text, isFinal, failed in
            Task { @MainActor in self?.heard(text, isFinal: isFinal, failed: failed, piece: pieceID) }
        })
    }

    private func heard(_ text: String?, isFinal: Bool, failed: Bool, piece: ObjectIdentifier) {
        // Only the current piece counts (an older one finishing late is ignored)
        guard state == .listening, let request, ObjectIdentifier(request) == piece else { return }
        if let text {
            // The recognizer sometimes starts its text over after a pause: keep what it had
            if !pieceText.isEmpty, text.count < pieceText.count / 2, !text.hasPrefix(String(pieceText.prefix(12))) {
                committed = Self.join(committed, pieceText)
            }
            pieceText = text
            partialTranscript = Self.join(committed, pieceText)
            restartSilenceTimer()
        }
        // The piece ended (time limit, a long pause, or an error) while you may still be
        // talking: keep its words and carry straight on. Only your pause or a tap ends the turn.
        if isFinal || failed {
            committed = Self.join(committed, pieceText)
            pieceText = ""
            partialTranscript = committed
            restarts += 1
            if restarts < 200 { startPiece() } else { finishListening() }
        }
    }

    static func join(_ a: String, _ b: String) -> String {
        let a = a.trimmingCharacters(in: .whitespaces), b = b.trimmingCharacters(in: .whitespaces)
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        return a + " " + b
    }

    private func restartSilenceTimer(initial: Bool = false) {
        silenceTimer?.invalidate()
        // Before the first word: a generous wait. After that: your pause setting,
        // or, with "until I tap", a long safety limit.
        let wait = initial ? max(8, pauseWait + 4) : (pauseWait > 0 ? pauseWait : 300)
        silenceTimer = Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.finishListening() }
        }
    }

    func finishListening() {
        guard state == .listening else { return }
        let text = Self.join(committed, pieceText).trimmingCharacters(in: .whitespacesAndNewlines)
        cancelListening()
        let callback = onFinal
        onFinal = nil
        callback?(text)
    }

    func cancelListening() {
        silenceTimer?.invalidate()
        box.set(nil)
        task?.cancel(); task = nil
        request?.endAudio(); request = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        if state == .listening { state = .idle }
        level = 0
        releaseSessionWhenIdle()
    }

    // Apple calls these from its own audio and speech threads, so they're built
    // outside the main actor (otherwise Swift stops the app with a queue assertion).

    nonisolated static func authorizeSpeech() async -> Bool {
        await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
    }

    nonisolated static func tap(_ box: RequestBox, level: @escaping @Sendable (Float) -> Void) -> AVAudioNodeTapBlock {
        { buffer, _ in
            box.append(buffer)
            level(rms(buffer))
        }
    }

    nonisolated static func tap(_ req: SFSpeechAudioBufferRecognitionRequest,
                                level: @escaping @Sendable (Float) -> Void) -> AVAudioNodeTapBlock {
        { buffer, _ in
            req.append(buffer)
            level(rms(buffer))
        }
    }

    /// (transcript or nil, is final, failed)
    nonisolated static func results(_ handle: @escaping @Sendable (String?, Bool, Bool) -> Void)
        -> @Sendable (SFSpeechRecognitionResult?, Error?) -> Void {
        { result, error in
            if let result { handle(result.bestTranscription.formattedString, result.isFinal, false) }
            else { handle(nil, false, error != nil) }
        }
    }

    nonisolated static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0] else { return 0 }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<n { sum += data[i] * data[i] }
        return min(1, sqrt(sum / Float(n)) * 12)
    }

    // MARK: speaking

    /// Whose voice: an Apple voice (on the device) or an ElevenLabs voice (your key).
    enum Speaker: Equatable {
        case apple(String?)
        case eleven(voice: String, model: ElevenLabs.Model)

        /// ElevenLabs' v4 models perform audio tags like [laughs] and [sighs].
        var performsEmotes: Bool {
            if case .eleven(_, let m) = self { return m == .v4 || m == .v4Turbo }
            return false
        }
    }

    /// Smith's voice, set from Settings.
    var smithVoice: Speaker = .apple(nil)

    /// Sentences waiting to be spoken. While one piece plays, the next
    /// sentences gather here and are spoken together, so the voice keeps its
    /// natural rise and fall instead of resetting at every full stop.
    /// What's waiting to be said, each with its subtitle ("show this now").
    private struct Piece { let text: String; let show: Subtitle? }
    private var pending: [Piece] = []
    /// Shows for each Apple utterance, keyed by the utterance.
    private var appleShows: [ObjectIdentifier: [Subtitle]] = [:]

    /// Runs once: when its audio starts, when speech is stopped, or after a safety wait.
    final class Subtitle {
        private var action: (() -> Void)?
        init(_ action: @escaping () -> Void) { self.action = action }
        var fired: Bool { action == nil }
        func fire() { let a = action; action = nil; a?() }
    }
    private var pendingVoice: Speaker = .apple(nil)
    /// True from the moment something is queued until its audio actually starts
    /// (ElevenLabs can take a few seconds), so the screen can show it's loading.
    private(set) var preparing = false
    private var inFlight = 0
    private var gatherTask: Task<Void, Never>?

    /// About a paragraph per request: speech starts quickly, and the next piece
    /// is fetched while this one plays. Long letters go out piece by piece.
    static let pieceLimit = 450
    /// The first piece is shorter, so the voice starts quickly.
    static let firstPieceLimit = 200

    /// Splits text into sentences (and lines), keeping each sentence's punctuation.
    static func sentences(_ text: String) -> [String] {
        var out: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: [.bySentences, .localized]) { sub, _, _, _ in
            if let t = sub?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { out.append(t) }
        }
        return out.isEmpty ? [text] : out
    }

    // ElevenLabs: one request at a time (more and it answers 429), audio played in order
    private var elevenFetching = false
    private var fetchTask: Task<Void, Never>?
    private var audioQueue: [(audio: Data, shows: [Subtitle])] = []
    private var player: AVAudioPlayer?
    private var meterTimer: Timer?
    /// What was just said, sent along so the next piece continues in the same tone.
    private var spokenSoFar = ""
    /// After a failure, Apple's voice for a minute (no waiting on a dead network each sentence).
    private var elevenDownUntil = Date.distantPast
    private var generation = 0
    private(set) var lastVoiceError: String?
    #if DEBUG
    /// Debug: shows the listening state with this transcript (for screenshots).
    func fakeListening(_ text: String) { state = .listening; partialTranscript = text }
    #endif
    /// Debug: what the speaking pipeline did, step by step.
    var trace: [String] = []
    private func note(_ s: String) {
        #if DEBUG
        trace.append(s)
        #endif
    }

    /// Queues a sentence (or a paragraph). Emotes in *asterisks*, markdown and emoji are left out of speech.
    func speak(_ sentence: String, as voice: Speaker? = nil, onStart: (() -> Void)? = nil) {
        let show = onStart.map(Subtitle.init)
        // ElevenLabs v4 voices perform emotes (*laughs* → a real laugh); others leave them silent
        let target = voice ?? smithVoice
        let clean = Self.speakable(target.performsEmotes ? Self.withAudioTags(sentence) : sentence)
        guard !clean.isEmpty else { show?.fire(); return }
        // Listening (they tapped the orb while a reply was still arriving): shown, not said.
        // Speaking here would flip the state to .speaking and leave the microphone running unseen.
        if state == .listening { show?.fire(); return }
        if pending.isEmpty && inFlight == 0 {
            pendingVoice = target
            preparing = true
        }
        // Long text (a whole letter) goes in sentence by sentence, so the first
        // request is short and the voice starts in seconds, not after the whole letter is made
        let parts = clean.count > Self.firstPieceLimit ? Self.sentences(clean) : [clean]
        for (i, part) in parts.enumerated() { pending.append(Piece(text: part, show: i == 0 ? show : nil)) }
        if let show { safetyNet(show) }
        state = .speaking
        guard inFlight == 0, gatherTask == nil else { return }
        // A short gather at the start lets the first two sentences flow together.
        gatherTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            // Stopped meanwhile: this gather belongs to speech that was cancelled, and
            // must not clear (or start) the one that replaced it
            guard !Task.isCancelled else { return }
            self?.gatherTask = nil
            self?.speakPending()
        }
    }

    /// Never left waiting: text whose audio hasn't started is shown anyway — but
    /// not while earlier audio is still playing (that would run ahead of the voice).
    private func safetyNet(_ show: Subtitle) {
        let gen = generation
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            while let self, self.generation == gen, !show.fired, self.player?.isPlaying == true || self.synth.isSpeaking {
                try? await Task.sleep(for: .seconds(1))
            }
            show.fire()
        }
    }

    private func prepareSession() {
        #if os(iOS)
        if inFlight == 0 {
            try? AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, .duckOthers])
            try? AVAudioSession.sharedInstance().setActive(true)
        }
        #endif
    }

    /// The next piece: whole sentences up to about `pieceLimit` characters (at least one).
    private func takePiece() -> (text: String, shows: [Subtitle]) {
        var taken: [Piece] = []
        var size = 0
        let limit = spokenSoFar.isEmpty ? Self.firstPieceLimit : Self.pieceLimit
        while let next = pending.first, taken.isEmpty || size + next.text.count <= limit {
            taken.append(pending.removeFirst())
            size += next.text.count + 1
        }
        return (taken.map(\.text).joined(separator: " "), taken.compactMap(\.show))
    }

    private func speakPending() {
        guard !pending.isEmpty else { return }
        if case .eleven(let voice, let model) = pendingVoice, let key = ElevenLabs.apiKey, Date() > elevenDownUntil {
            guard !elevenFetching else { return } // picked up when the current request finishes
            let (text, shows) = takePiece()
            prepareSession()
            elevenFetching = true
            inFlight += 1
            let previous = spokenSoFar
            spokenSoFar += (spokenSoFar.isEmpty ? "" : " ") + text
            let gen = generation
            note("fetch \(text.count) chars")
            fetchTask = Task { [weak self] in
                do {
                    let audio = try await ElevenLabs.speech(text, voice: voice, model: model, previous: previous, key: key)
                    guard let self, self.generation == gen, !Task.isCancelled else { return }
                    self.note("got \(audio.count) bytes")
                    self.elevenFetching = false
                    self.audioQueue.append((audio, shows))
                    self.playNext()
                    // Fetch the next piece while this one plays
                    if !self.pending.isEmpty { self.speakPending() }
                } catch {
                    self?.note("fetch error \(error)")
                    guard let self, self.generation == gen, !Task.isCancelled else { return }
                    self.elevenFetching = false
                    self.lastVoiceError = error.localizedDescription
                    self.elevenDownUntil = Date().addingTimeInterval(60)
                    // Said in Apple's voice instead
                    self.inFlight -= 1
                    self.speakWithApple(text, voiceID: nil, shows: shows)
                }
            }
            return
        }
        let (text, shows) = takePiece()
        if case .apple(let id) = pendingVoice { speakWithApple(text, voiceID: id, shows: shows) } else { speakWithApple(text, voiceID: nil, shows: shows) }
    }

    private func speakWithApple(_ text: String, voiceID: String?, shows: [Subtitle] = []) {
        prepareSession()
        let u = AVSpeechUtterance(string: text)
        if let voiceID, let v = AVSpeechSynthesisVoice(identifier: voiceID) { u.voice = v }
        else if case .apple(let id) = smithVoice, let id, let v = AVSpeechSynthesisVoice(identifier: id) { u.voice = v }
        else { u.voice = Self.bestDefaultVoice() }
        u.rate = AVSpeechUtteranceDefaultSpeechRate * (0.85 + rate * 0.3)
        u.pitchMultiplier = 1.0
        u.preUtteranceDelay = 0
        u.postUtteranceDelay = 0
        inFlight += 1
        liveUtterances.insert(ObjectIdentifier(u))
        if !shows.isEmpty { appleShows[ObjectIdentifier(u)] = shows }
        synth.speak(u)
    }

    /// The utterances handed to the synthesizer and not yet finished or stopped. A
    /// "finished" that arrives late, for speech already stopped, is not counted
    /// against whatever is being said now.
    private var liveUtterances: Set<ObjectIdentifier> = []
    /// The same for ElevenLabs audio: players started and not yet finished or stopped.
    private var livePlayers: Set<ObjectIdentifier> = []
    /// When listening last began (a microphone change in its first moment is the start itself).
    private var listenStarted = Date.distantPast

    private func playNext() {
        guard player?.isPlaying != true, !audioQueue.isEmpty else { return }
        let (data, shows) = audioQueue.removeFirst()
        // The text appears as its audio starts
        defer { shows.forEach { $0.fire() } }
        guard let p = try? AVAudioPlayer(data: data) else { note("player failed"); utteranceEnded(); return }
        p.delegate = self
        p.isMeteringEnabled = true
        p.enableRate = true
        p.rate = 0.85 + rate * 0.3
        player = p
        livePlayers.insert(ObjectIdentifier(p))
        let ok = p.play()
        note("play \(ok) duration \(p.duration)")
        preparing = false
        // Couldn't play (the audio route went away, a call came in): no "finished" will
        // ever arrive, so move on now rather than stay "speaking" for good
        guard ok else { livePlayers.remove(ObjectIdentifier(p)); elevenPieceEnded(); return }
        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let p = self.player, p.isPlaying else { return }
                p.updateMeters()
                self.level = min(1, pow(10, p.averagePower(forChannel: 0) / 20) * 2.5)
            }
        }
    }

    private func elevenPieceEnded() {
        meterTimer?.invalidate(); meterTimer = nil
        player = nil
        playNext()
        utteranceEnded()
    }

    /// Called once everything queued has been spoken.
    func whenDoneSpeaking(_ action: @escaping () -> Void) {
        if inFlight == 0 && pending.isEmpty && gatherTask == nil { action() } else { onSpeechDone = action }
    }

    func stopSpeaking() {
        note("stop")
        generation += 1
        gatherTask?.cancel(); gatherTask = nil
        let waiting = pending.compactMap(\.show)
        pending = []
        preparing = false
        onSpeechDone = nil
        if synth.isSpeaking || inFlight > 0 { synth.stopSpeaking(at: .immediate) }
        player?.stop(); player = nil
        meterTimer?.invalidate(); meterTimer = nil
        // The request in flight is cancelled, so a new one never runs beside it (ElevenLabs' 429)
        fetchTask?.cancel(); fetchTask = nil
        // Whatever was waiting for its audio is shown now, so nothing is lost
        (waiting + audioQueue.flatMap(\.shows) + appleShows.values.flatMap { $0 }).forEach { $0.fire() }
        appleShows = [:]
        liveUtterances = []
        livePlayers = []
        audioQueue = []
        elevenFetching = false
        spokenSoFar = ""
        inFlight = 0
        if state == .speaking { state = .idle }
        level = 0
        releaseSessionWhenIdle()
    }

    /// iPad: once Smith has been quiet for a moment, the audio session is given back,
    /// so other apps' sound (music, a podcast) comes back up instead of staying ducked.
    /// The short wait covers the gap between a reply ending and listening starting again.
    private func releaseSessionWhenIdle() {
        #if os(iOS)
        releaseTask?.cancel()
        releaseTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, let self, self.state == .idle, !self.engine.isRunning, self.inFlight == 0 else { return }
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        #endif
    }
    private var releaseTask: Task<Void, Never>?

    /// A phone call, Siri, an alarm, or the microphone / headphones changing under us:
    /// stop cleanly, so Smith is never left "speaking" or "listening" with nothing happening.
    private func watchForInterruptions() {
        let center = NotificationCenter.default
        #if os(iOS)
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let began = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue
            guard began else { return }
            // What they had said so far is kept and sent, not thrown away
            MainActor.assumeIsolated { self?.stopSpeaking(); self?.finishListening() }
        }
        #endif
        center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                // The input changed mid-sentence: the tap's format is stale, so listening ends here
                // Starting to listen changes the audio route by itself (headphones switching
                // to their microphone): that first moment is not a change to act on.
                guard let self, self.state == .listening, Date().timeIntervalSince(self.listenStarted) > 2 else { return }
                // Later: the tap no longer matches the input, so listening ends, with what was heard kept
                self.finishListening()
            }
        }
    }

    /// Emotes in asterisks → ElevenLabs audio tags, which the v4 models perform:
    /// *laughs* → [laughs], *sighs* → [sighs]. A few become how to say it (*grins* → [playfully]).
    static func withAudioTags(_ s: String) -> String {
        let delivery: [String: String] = [
            "smiles": "warmly", "smiling": "warmly", "grins": "playfully", "grinning": "playfully",
            "beams": "happily", "beaming": "happily", "laughs softly": "chuckles", "laughing": "laughs",
            "giggles": "giggles", "winces": "wincing", "rolls eyes": "playfully exasperated",
        ]
        var out = ""
        // **bold** is emphasis, not an emote: its words are said
        let s = s.replacingOccurrences(of: "**", with: "")
        var rest = Substring(s)
        while let r = rest.range(of: #"\*[^*\n]{1,40}\*"#, options: .regularExpression) {
            out += rest[..<r.lowerBound]
            let cue = rest[r].dropFirst().dropLast().trimmingCharacters(in: .whitespaces).lowercased()
            let tag = delivery[cue] ?? cue
            // Only words make a tag (nothing that could be read out as something else)
            if tag.range(of: #"^[a-z][a-z ,'-]{2,38}$"#, options: .regularExpression) != nil { out += "[\(tag)] " }
            rest = rest[r.upperBound...]
        }
        return (out + rest).replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
    }

    static func speakable(_ s: String) -> String {
        // **bold** keeps its words; an *emote* is on one line (two "* " bullets are not one)
        var t = s.replacingOccurrences(of: "**", with: "")
        t = t.replacingOccurrences(of: #"\*[^*\n]{1,60}\*"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"[#*_`>]"#, with: "", options: .regularExpression)
        t = t.unicodeScalars.filter { !$0.properties.isEmojiPresentation }.map(String.init).joined()
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Premium, then Enhanced, then any voice in the current language.
    static func bestDefaultVoice() -> AVSpeechSynthesisVoice? {
        let lang = AVSpeechSynthesisVoice.currentLanguageCode()
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == lang }
        return voices.first { $0.quality == .premium } ?? voices.first { $0.quality == .enhanced } ?? AVSpeechSynthesisVoice(language: lang)
    }

    /// Listing and sorting every installed voice is slow, and Settings asks on every
    /// redraw: the list is kept for a minute (long enough to type, short enough to
    /// notice a voice downloaded in System Settings).
    static var choosableVoices: [AVSpeechSynthesisVoice] {
        if let c = voiceCache, Date().timeIntervalSince(c.at) < 60 { return c.voices }
        let voices = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(String(AVSpeechSynthesisVoice.currentLanguageCode().prefix(2))) }
            .sorted { ($0.quality.rawValue, $0.name) > ($1.quality.rawValue, $1.name) }
        voiceCache = (Date(), voices)
        return voices
    }
    private static var voiceCache: (at: Date, voices: [AVSpeechSynthesisVoice])?

    /// Hear a voice (Settings), or a letter in Henry's voice.
    func preview(_ voice: Speaker, text: String) {
        stopSpeaking()
        speak(text, as: voice)
    }
}

extension VoiceIO: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let key = ObjectIdentifier(utterance)
        Task { @MainActor in self.preparing = false; self.appleShows.removeValue(forKey: key)?.forEach { $0.fire() } }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let key = ObjectIdentifier(utterance)
        // Only one still counted: a late "finished" for speech that was stopped is ignored
        Task { @MainActor in if self.liveUtterances.remove(key) != nil { self.utteranceEnded() } }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
        Task { @MainActor in self.level = Float.random(in: 0.35...0.8) }
    }

    fileprivate func utteranceEnded() {
        note("utteranceEnded inFlight \(inFlight) pending \(pending.count)")
        inFlight = max(0, inFlight - 1)
        if !pending.isEmpty { speakPending(); return }
        guard inFlight == 0, gatherTask == nil, !elevenFetching, audioQueue.isEmpty else { return }
        spokenSoFar = ""
        preparing = false
        state = .idle
        level = 0
        let done = onSpeechDone
        onSpeechDone = nil
        done?()
        releaseSessionWhenIdle()
    }
}

extension VoiceIO: AVAudioPlayerDelegate {
    // Only for the player that is playing now: one that was stopped and replaced says nothing
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let key = ObjectIdentifier(player)
        Task { @MainActor in
            // Stopped since: says nothing. Finished but already replaced by the next piece: still counted
            guard self.livePlayers.remove(key) != nil else { return }
            self.note("finished \(flag)")
            if self.player.map(ObjectIdentifier.init) == key { self.elevenPieceEnded() } else { self.utteranceEnded() }
        }
    }
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let key = ObjectIdentifier(player)
        Task { @MainActor in
            guard self.livePlayers.remove(key) != nil else { return }
            self.note("decode error \(String(describing: error))")
            if self.player.map(ObjectIdentifier.init) == key { self.elevenPieceEnded() } else { self.utteranceEnded() }
        }
    }
}

extension AVSpeechSynthesisVoiceQuality {
    var label: String { switch self { case .premium: "Premium"; case .enhanced: "Enhanced"; default: "Default" } }
}

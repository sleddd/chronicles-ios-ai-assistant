import Foundation
import Observation
import SmithCore

/// The reply line being filled in, as each sentence's audio starts.
final class ReplyLine { var id: UUID?; var sent: SentInfo? }

/// What went to Claude for one reply, shown under it ("What was sent").
struct SentInfo: Equatable {
    struct Part: Equatable, Identifiable {
        let id = UUID()
        var title: String
        var text: String
    }
    var parts: [Part] = []
}

/// One line in the chat.
struct ChatLine: Identifiable, Equatable {
    enum Who { case you, smith, note, resources }
    let id = UUID()
    var who: Who
    var text: String
    /// For `.resources`: which helplines come first.
    var kind: RiskKind? = nil
    /// For Smith's replies: what was sent to Claude to write it.
    var sent: SentInfo? = nil
}

/// The live conversation. It exists only in memory; when it ends, Smith keeps
/// a short summary (and maybe a fact or two) and the transcript is discarded.
@MainActor @Observable
final class SmithBrain {
    let store: SmithStore
    let voice: VoiceIO
    let weather: WeatherService
    let chronicles: ChroniclesConnection
    let safety: SafetyCenter

    private(set) var lines: [ChatLine] = []
    private(set) var isThinking = false
    private(set) var workingOn: String?
    /// Smith's current line on the home screen.
    private(set) var headline = ""
    private(set) var pill = ""
    /// "Smith noted: …" pills with Edit / Undo.
    private(set) var noted: [Fact] = []
    var conversationMode = false
    var lastError: String?

    private var messages: [JSONValue] = []
    private var idleTimer: Timer?
    private var concernsShown: [Concern] = []
    private var freshnessNudge: Freshness.Nudge?

    init(store: SmithStore, voice: VoiceIO, weather: WeatherService, chronicles: ChroniclesConnection, safety: SafetyCenter) {
        self.store = store; self.voice = voice; self.weather = weather; self.chronicles = chronicles; self.safety = safety
        refreshHeadline()
    }

    // MARK: context

    var today: String { Day.key() }

    func context() -> SmithContext {
        let s = store.settings
        let concerns = Concerns.raisable(
            Concerns.find(in: store.snapshot ?? ChroniclesSnapshot(exportedAt: .distantPast), journal: store.journal,
                          today: today, neverMention: s.neverMentionTopics),
            settings: s.concerns, today: today)
        concernsShown = concerns
        // Signed in to Chronicles: "behind on exports" doesn't apply; a failed sync does
        let freshness = chronicles.state == .notSetUp ? currentNudge()?.line(today: today)
            // (Never the error's own text: it can carry the server's words, and this goes into Smith's instructions)
            : chronicles.lastError.map { _ in "I couldn't reach Chronicles just now, so what I have may be a little behind." }
        var ctx = SmithContext(name: s.name, snapshot: store.snapshot, journalDigest: store.journalDigestText,
                            aboutYou: s.memoryEnabled ? store.aboutYou.contextText() : nil,
                            recentConversations: s.memoryEnabled ? Array(store.conversations.suffix(6)) : [],
                            concerns: concerns, freshnessNote: freshness,
                            privateBillIDs: s.privateBills, includeGoalMention: s.goalMentionInBriefing,
                            weatherLine: weather.report?.line)
        ctx.canAct = chronicles.isUnlocked
        return ctx
    }

    /// The day's overview for the screen. Building the whole context (concerns, the
    /// journal digest, what Smith knows) is slow, and the home screen redraws many
    /// times a second while the microphone level moves: so one result is kept for a
    /// few seconds, and made again when the Chronicles data changes.
    func overviewForDisplay() -> DayOverview? {
        let stamp = store.snapshot?.exportedAt
        if let c = overviewCache, c.snapshot == stamp, Date().timeIntervalSince(c.at) < 15 { return c.value }
        let value = context().overview
        overviewCache = (Date(), stamp, value)
        return value
    }
    @ObservationIgnored private var overviewCache: (at: Date, snapshot: Date?, value: DayOverview?)?

    func currentNudge() -> Freshness.Nudge? {
        #if os(iOS)
        let isPad = true
        #else
        let isPad = false
        #endif
        return Freshness.nudge(settings: store.settings.freshness, today: today, exportedAt: store.snapshot?.exportedAt,
                               lastSync: store.lastSync, macHasNewer: store.peerHasNewer,
                               installExpires: InstallInfo.expiration, isPad: isPad)
    }

    private func tools(actions: Bool = true) -> [LocalTool] {
        let snap = store.snapshot
        let ctx = context()
        let digest = store.journalDigestText
        let weather = self.weather
        let store = self.store
        return [
            TodayOverviewTool { ctx }, FindTasksTool { snap }, GoalsProgressTool { snap }, BillsDueTool { ctx },
            JournalSummaryTool { digest }, CurrentTimeTool(),
            WeatherTool { try await weather.fetchLine() },
            MemoryTool { [weak self] action in await MainActor.run { self?.memory(action) ?? "Not saved." } },
        ] + (actions && chronicles.isUnlocked ? ChroniclesActionTools.all(chronicles.actionContext(estimate: nutrientEstimator())) : [])
    }

    /// Nutrients for a meal, the way Chronicles' own estimator asks (same prompt and limits).
    private func nutrientEstimator() -> @Sendable (String, String?, String?) async -> [String: Double]? {
        let model = store.settings.model
        return { item, mealType, ingredients in
            let r = ChatRunner(transport: URLSessionTransport(apiKey: { APIKeys.current() }), tools: [])
            let req = ClaudeRequest(model: model, maxTokens: 1000, effort: "low",
                                    system: [SystemBlock(ChroniclesShapes.nutritionSystem)],
                                    messages: [["role": "user", "content": .string(ChroniclesShapes.nutritionPrompt(item: item, mealType: mealType, ingredients: ingredients))]])
            guard let text = try? await r.complete(req) else { return nil }
            return ChroniclesShapes.parseNutrients(text)
        }
    }

    private var runner: ChatRunner {
        ChatRunner(transport: URLSessionTransport(apiKey: { APIKeys.current() }), tools: tools(),
                   phraseGuard: PhraseGuard(phrases: store.settings.bannedPhrases))
    }

    /// Fresh every time: never the same opening, phrase or joke twice; nothing
    /// brought up (the weather, the time, their schedule) unless it fits what they said.
    /// Plus any words they've asked Smith never to use.
    private var styleRules: SystemBlock {
        var rules = """
            Keep it fresh. Don't reuse an opening, a phrase, a joke or a sign-off you've already used in this \
            conversation or that shows up in the recent conversation summaries; say things a new way each time. \
            Answer what they actually said. Don't mention the weather, the time or their schedule unless they ask \
            or it truly bears on what they said (the morning briefing is the exception).
            """
        let custom = store.settings.customBannedPhrases.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if !custom.isEmpty {
            rules += "\n\nNever use these words or phrases, in any form: " + custom.map { "\"\($0)\"" }.joined(separator: ", ") + "."
        }
        return SystemBlock(rules)
    }

    // MARK: talking

    /// Sends what they said or typed. `spoken` replies are kept speakable and read aloud.
    func send(_ text: String, spoken: Bool) async {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Locked: nothing is sent and nothing is answered, whoever asks (typing, voice, the wake word)
        guard !t.isEmpty, chronicles.isUnlocked else { return }
        chronicles.noteActivity()
        idleTimer?.invalidate()
        // One reply at a time: a second message sent while Smith is still answering waits
        // its turn. Two at once would each finish by replacing the other's history.
        while let running = current { await running.value; if current == running { current = nil } }
        // Locked while waiting: nothing is sent
        guard chronicles.isUnlocked else { return }
        lastReplyIsBriefing = false
        let line = ChatLine(who: .you, text: t)
        turns.append(Turn(lineID: line.id, messageCount: messages.count, text: t))
        lines.append(line)
        if let reason = safety.unavailableReason {
            lines.append(ChatLine(who: .note, text: reason))
            turns.removeLast()
            return
        }
        // Safety, layer 1 (on this device, instant): a likely minor, or direct statements of risk
        if ChatSafety.minorPattern(t) { lockForMinor(); return }
        let pattern = ChatSafety.patternScreen(t)
        if pattern.isRisk { showResources(pattern) }
        // Layer 2 (the classifier) reads the conversation while the reply is made
        let history = lines.filter { $0.who == .you || $0.who == .smith }.map { (user: $0.who == .you, text: $0.text) }
        let screen = Task { await safety.classify(history) }
        messages.append(["role": "user", "content": .string(t)])
        let turnID = line.id
        Task { [weak self] in
            let r = await screen.value
            guard let self, self.turns.contains(where: { $0.lineID == turnID }) else { return }
            if r.minor { self.lockForMinor(); return }
            if r.rating > pattern.rating { self.showResources(r) }
        }
        let task = Task { await respond(spoken: spoken) }
        current = task
        await task.value
        if current == task { current = nil }
    }

    // MARK: stop, edit, delete, start over

    /// Each thing you said: where it starts in the chat and in the conversation sent to Claude.
    private struct Turn { let lineID: UUID; let messageCount: Int; let text: String }
    private var turns: [Turn] = []
    private var current: Task<Void, Never>?

    /// The id of your latest message (only the latest can be edited or deleted:
    /// removing one from the middle would break the conversation Claude checks).
    var lastTurnLineID: UUID? { turns.last?.lineID }

    /// Takes back your latest message and Smith's answer. Returns what you said.
    @discardableResult
    func removeLastTurn() -> String? {
        guard let turn = turns.popLast() else { return nil }
        current?.cancel(); current = nil
        voice.stopSpeaking()
        messages = Array(messages.prefix(turn.messageCount))
        if let i = lines.firstIndex(where: { $0.id == turn.lineID }) { lines.removeSubrange(i...) }
        headline = lines.last { $0.who == .smith }?.text ?? headline
        isThinking = false; workingOn = nil
        return turn.text
    }

    /// Stop whatever Smith is doing. While he's still answering, your message is
    /// taken back (returned, for the typing box) so you can say it again.
    ///
    /// Stopped while he's reading out a finished answer: the answer stays in the chat,
    /// and what you said is still handed back, so it's in the box to edit and send again.
    func stop() -> String? {
        conversationMode = false
        let wasSpeaking = voice.state == .speaking
        voice.cancelListening()
        voice.stopSpeaking()
        if isThinking { return removeLastTurn() }
        return wasSpeaking ? turns.last?.text : nil
    }

    /// Smith's latest reply, said again a different way.
    var canRegenerate: Bool { !isThinking && turns.last != nil && lines.last?.who == .smith && !lastReplyIsBriefing }
    /// The latest reply is a briefing, not an answer to the latest thing they said.
    private var lastReplyIsBriefing = false

    func regenerate() async {
        guard canRegenerate, let turn = turns.last else { return }
        voice.stopSpeaking()
        current?.cancel(); current = nil
        // Back to just after what they said
        messages = Array(messages.prefix(turn.messageCount + 1))
        if let i = lines.firstIndex(where: { $0.id == turn.lineID }) { lines.removeSubrange((i + 1)...) }
        // A different answer this time (an instruction for this turn only)
        let task = Task { await respond(spoken: !store.settings.muted, turnInstruction: "Answer their last message again, freshly: a different angle and different wording from any earlier attempt.") }
        current = task
        await task.value
        if current == task { current = nil }
    }

    /// Clears this chat. Nothing is kept from it: no summary, no facts.
    func startOver() {
        current?.cancel(); current = nil
        voice.cancelListening(); voice.stopSpeaking()
        conversationMode = false
        idleTimer?.invalidate()
        // Nothing from it is kept: a summary saved at a pause goes too
        if let id = summaryID { store.deleteConversation(id) }
        summaryID = nil
        messages = []; lines = []; turns = []; noted = []
        frozenSystem = nil; lastDaySent = nil
        safety.endConversation()
        isThinking = false; workingOn = nil
        refreshHeadline()
    }

    /// Smith locked: whatever was under way stops. A reply still arriving could
    /// otherwise go on speaking, and its tools go on writing, after the lock.
    func lockedOut() {
        current?.cancel(); current = nil
        idleTimer?.invalidate()
        conversationMode = false
        voice.cancelListening(); voice.stopSpeaking()
        isThinking = false; workingOn = nil
    }

    /// The system prompt of this conversation, fixed at its first reply (see `SmithContext.stableBlocks`).
    @ObservationIgnored private var frozenSystem: [SystemBlock]?
    @ObservationIgnored private var lastDaySent: String?

    private func respond(spoken: Bool, turnInstruction: String? = nil) async {
        let speak = spoken || (store.settings.speakTypedReplies && !store.settings.muted)
        isThinking = true
        lastError = nil
        defer { isThinking = false; workingOn = nil; scheduleCheckpoint() }
        let ctx = context()
        let runner = self.runner
        // The system prompt is fixed for the conversation. What changes turn by turn (the
        // clock, the day's facts, safety rules, a one-off instruction) follows what they
        // said as a system message in the history, and stays there.
        if frozenSystem == nil { frozenSystem = ctx.stableBlocks(spoken: speak && !store.settings.muted) + [styleRules] }
        if messages.last?["role"]?.string == "user" {
            let day = ctx.dayText()
            // The day's facts only when they changed; otherwise just the time (the first line)
            let facts = day.split(separator: "\n", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
            var note = facts == lastDaySent ? String(day.split(separator: "\n", maxSplits: 1).first ?? "") : day
            lastDaySent = facts
            for rule in safety.extraRules { note += "\n\n" + rule.text }
            if let turnInstruction { note += "\n\n" + turnInstruction }
            messages.append(["role": "system", "content": .string(note)])
        }
        // Medium: enough thought to catch sarcasm, irony and a running joke; still quick
        let request = ClaudeRequest(model: store.settings.model, maxTokens: 16000, effort: "medium",
                                    system: frozenSystem ?? [],
                                    messages: messages, tools: runner.toolDefinitions(webSearch: true))
        let voice = self.voice
        let muted = store.settings.muted
        // Events arrive off the main thread; an ordered stream keeps sentences in order.
        let (events, sink) = AsyncStream<ChatEvent>.makeStream()
        let turnID = turns.last?.lineID
        let lastUser = turns.last?.text ?? ""
        // What goes to Claude for this reply, to show under it
        var sent = SentInfo()
        if !lastUser.isEmpty { sent.parts.append(.init(title: "Your message", text: lastUser)) }
        let earlier = max(0, messages.filter { $0["role"]?.string != "system" }.count - 1)
        if earlier > 0 { sent.parts.append(.init(title: "Earlier in this chat", text: "\(earlier) earlier message\(earlier == 1 ? "" : "s") in this conversation: what you said and Smith's replies.")) }
        if let about = ctx.aboutYou { sent.parts.append(.init(title: "What Smith knows about you", text: about)) }
        if !ctx.recentConversations.isEmpty {
            sent.parts.append(.init(title: "Recent conversation summaries", text: ctx.recentConversations.suffix(6).map { "\($0.day): \($0.text)" }.joined(separator: "\n")))
        }
        sent.parts.append(.init(title: "Your day, from Chronicles", text: ctx.dayText()))
        // In safe mode a reply is held until it's been screened whole; otherwise each
        // sentence is checked on this device as it arrives, and the whole reply afterwards.
        let holdForScreening = safety.safeMode
        let reply = ReplyLine()
        let state = ReplyState()
        let present: (String) -> Void = { [weak self] s in
            guard let self else { return }
            // Shown like subtitles: as its audio starts (at once when muted or if speech can't play)
            let show = { [weak self] in
                guard let self, self.turns.last?.lineID == turnID, !state.withheld else { return }
                if let id = reply.id, let i = self.lines.firstIndex(where: { $0.id == id }) { self.lines[i].text += " " + s }
                else { let line = ChatLine(who: .smith, text: s); reply.id = line.id; self.lines.append(line) }
                if let id = reply.id, let i = self.lines.firstIndex(where: { $0.id == id }) {
                    self.headline = self.lines[i].text
                    if let sent = reply.sent { self.lines[i].sent = sent }
                }
            }
            if speak && !muted { voice.speak(s, onStart: show) } else { show() }
        }
        let consumer = Task { @MainActor in
            for await event in events {
                // Stopped or taken back: nothing more from this answer is shown or spoken
                guard self.turns.last?.lineID == turnID, self.isThinking, !state.withheld else { continue }
                switch event {
                case .working(let name): self.workingOn = Self.workingLabel(name)
                case .lookedUp(let tool, let result): state.lookups.append((tool, result))
                case .sentence(let s):
                    self.workingOn = nil
                    state.all.append(s)
                    if let kind = ChatSafety.replyPatternScreen(s) { self.withhold(kind, reply: reply, state: state); continue }
                    if holdForScreening { continue }
                    present(s)
                }
            }
        }
        do {
            let result = try await runner.run(request) { sink.yield($0) }
            sink.finish()
            await consumer.value
            // Stopped meanwhile: what was taken back stays taken back
            guard !Task.isCancelled else { return }
            // The whole reply, screened (the classifier only for replies touching the topics)
            if !state.withheld, let kind = await safety.harmfulKind(reply: state.all.joined(separator: " "), lastUser: lastUser) {
                withhold(kind, reply: reply, state: state)
            } else if holdForScreening, !state.withheld {
                state.all.forEach(present)
            }
            guard !Task.isCancelled else { return }
            // What was sent, now complete with the lookups, under the reply
            sent.parts += state.lookups.map { .init(title: Self.lookupTitle($0.0), text: $0.1) }
            sent.parts.append(.init(title: "Never sent", text: "Journal entry text, money amounts, wellness notes, and anything you keep from AI in Chronicles. Smith's own instructions (its personality and safety rules) go along too; they hold nothing about you."))
            reply.sent = sent
            if let id = reply.id, let i = lines.firstIndex(where: { $0.id == id }) { lines[i].sent = sent }
            messages = result.messages
            // A withheld reply isn't kept in the conversation; what was said instead is
            if state.withheld, let last = messages.indices.last, messages[last]["role"]?.string == "assistant" {
                messages[last] = ["role": "assistant", "content": .string(Self.withheldLine)]
            }
            markRaised()
        } catch {
            sink.finish()
            await consumer.value
            if Task.isCancelled || error is CancellationError { return }
            // Keep the history valid: drop the unanswered question (and the note that followed it).
            if messages.last?["role"]?.string == "system" { messages.removeLast() }
            if case .some(let last) = messages.last, last["role"]?.string == "user" { messages.removeLast() }
            lastError = error.localizedDescription
            lines.append(ChatLine(who: .note, text: error.localizedDescription))
        }
    }

    #if DEBUG
    /// Screenshots only: a headline without the person's name.
    func debugSetHeadline(_ text: String) { headline = text }
    #endif

    // MARK: safety

    /// Said instead of a reply that went somewhere harmful.
    static let withheldLine = "I won’t go into that one. I’d much rather hear how you’re doing."

    final class ReplyState { var all: [String] = []; var withheld = false; var lookups: [(String, String)] = [] }

    static func lookupTitle(_ tool: String) -> String {
        switch tool {
        case "web_search": "Searched the web for"
        case "today_overview": "Looked up: today's overview"
        case "find_tasks": "Looked up: tasks"
        case "goals_progress": "Looked up: goals"
        case "bills_due": "Looked up: bills due (names and dates only)"
        case "journal_summary": "Looked up: journal summary (no entry text)"
        case "current_time": "Looked up: the time"
        case "weather": "Looked up: the weather"
        case "memory": "Memory"
        default: "Did in Chronicles: " + tool.replacingOccurrences(of: "_", with: " ")
        }
    }

    /// A reply went somewhere harmful: it stops, isn't shown, and help appears instead.
    private func withhold(_ kind: RiskKind, reply: ReplyLine, state: ReplyState) {
        state.withheld = true
        voice.stopSpeaking()
        if let id = reply.id { lines.removeAll { $0.id == id } }
        let line = ChatLine(who: .smith, text: Self.withheldLine)
        reply.id = line.id
        lines.append(line)
        headline = line.text
        showResources(RiskResult(rating: .elevated, kind: kind))
    }

    /// Resources in the chat (once per few lines), and safe rules from now on.
    func showResources(_ risk: RiskResult) {
        safety.flag(risk)
        if lines.suffix(4).contains(where: { $0.who == .resources }) { return }
        lines.append(ChatLine(who: .resources, text: "", kind: risk.kind))
    }

    /// The writer seems to be under 18: chat and letters pause until Smith is quit.
    private func lockForMinor() {
        safety.lockForMinor()
        current?.cancel(); current = nil
        voice.stopSpeaking()
        isThinking = false; workingOn = nil
        lines.append(ChatLine(who: .note, text: "Smith is for adults 18 and older, so the chat and letters are paused."))
    }

    static func workingLabel(_ tool: String) -> String {
        switch tool {
        case "web_search": "Looking that up…"
        case "weather": "Checking the weather…"
        case "bills_due": "Checking your bills…"
        case "memory": "Making a note…"
        default: "Checking your plans…"
        }
    }

    /// Concerns and the freshness line are in context once; note them so they aren't repeated this week / today.
    private func markRaised() {
        let reply = lines.last { $0.who == .smith }?.text.lowercased() ?? ""
        store.updateLocalSettings { s in
            for c in concernsShown where c.note.split(separator: " ").prefix(2).allSatisfy({ reply.contains($0.lowercased()) }) {
                s.concerns.lastRaised[c.id] = today
            }
            if freshnessNudge != nil || reply.contains("export all") || reply.contains("behind") {
                s.freshness.lastNudgeDay = today
            }
        }
    }

    /// The morning briefing, spoken.
    func briefing(spoken: Bool = true) async {
        guard chronicles.isUnlocked else { return }
        freshnessNudge = currentNudge()
        await weather.refresh(fahrenheit: store.settings.fahrenheit)
        pill = "MORNING BRIEFING"
        let ask = """
            [Morning briefing] Greet them warmly by name if you know it, then tell them the time, the weather, \
            today's events and planned tasks, deadlines, bills due soon, medication doses, and their top priority\
            \(store.settings.goalMentionInBriefing ? ", plus a plain mention of a goal in progress (information, not a pep talk)" : ""). \
            Keep it brief and natural, the way a friend would catch them up. If there's a stale-data note, end with it.
            """
        // In line with everything else: one reply at a time
        while let running = current { await running.value; if current == running { current = nil } }
        guard chronicles.isUnlocked else { return }
        messages.append(["role": "user", "content": .string(ask)])
        lines.append(ChatLine(who: .note, text: "Morning briefing"))
        lastReplyIsBriefing = true
        let task = Task { await respond(spoken: spoken) }
        current = task
        await task.value
        if current == task { current = nil }
        guard chronicles.isUnlocked else { return }
        store.updateLocalSettings { $0.lastGreetingDay = today }
    }

    /// For Siri: a one-shot answer without touching the live conversation.
    func oneShot(_ question: String) async -> String {
        // Siri can ask while Smith sits in the background, where the lock timer doesn't run
        chronicles.checkAutoLock()
        if chronicles.isLocked {
            return chronicles.state == .notSetUp ? "Connect Smith to Chronicles first: open Smith and sign in."
                : "Unlock Smith first: open Smith and enter your Chronicles password."
        }
        if let reason = safety.unavailableReason { return reason }
        if ChatSafety.minorPattern(question) { safety.lockForMinor(); return "Smith is for adults 18 and older." }
        if ChatSafety.patternScreen(question).isRisk {
            return "I'm worried about you. Please call or text 988 to talk with someone right now, or call 911 if you're in danger. Open Smith and we can keep talking."
        }
        let ctx = context()
        // Asked through Siri, perhaps not by them: it can look things up, not write or remember
        let runner = ChatRunner(transport: URLSessionTransport(apiKey: { APIKeys.current() }),
                                tools: tools(actions: false).filter { !$0.changesData },
                                phraseGuard: PhraseGuard(phrases: store.settings.bannedPhrases))
        let req = ClaudeRequest(model: store.settings.model, effort: "low", system: ctx.systemBlocks(spoken: true),
                                messages: [["role": "user", "content": .string(question)]],
                                tools: runner.toolDefinitions(webSearch: true))
        do {
            let r = try await runner.run(req) { _ in }
            await wrapUp(r.messages, ofLiveChat: false)
            return r.text
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: ending a conversation

    /// A conversation never ends on its own: it stays until Done or Start over,
    /// however long the pause. After 10 quiet minutes its summary is saved (and
    /// kept up to date after later pauses), so nothing is lost if Smith is quit.
    private func scheduleCheckpoint() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isThinking, self.messages.contains(where: { $0["role"]?.string == "assistant" }) else { return }
                await self.wrapUp(self.messages)
            }
        }
    }

    /// This conversation's saved summary, updated rather than added again at each pause.
    @ObservationIgnored private var summaryID: UUID?

    /// "That's all" or Done. Keeps a summary; discards the transcript.
    func endConversation() async {
        idleTimer?.invalidate()
        voice.cancelListening()
        conversationMode = false
        let transcript = messages
        messages = []
        frozenSystem = nil; lastDaySent = nil
        lines = []
        turns = []
        noted = []
        safety.endConversation()
        refreshHeadline()
        let checkpoint = summaryID
        summaryID = nil
        guard transcript.contains(where: { $0["role"]?.string == "assistant" }) else { return }
        await wrapUp(transcript, replacing: checkpoint)
    }

    private func wrapUp(_ transcript: [JSONValue], replacing earlier: UUID? = nil, ofLiveChat: Bool = true) async {
        let earlier = ofLiveChat ? (earlier ?? summaryID) : nil
        // Locked: the conversation stays where it is, in memory; nothing about it is sent anywhere
        guard store.settings.memoryEnabled, chronicles.isUnlocked else { return }
        // (The per-turn notes are Smith's own, not part of what was said)
        let transcript = transcript.filter { $0["role"]?.string != "system" }
        var result = await OnDeviceWrapUp.run(transcript: WrapUp.transcript(transcript, name: store.settings.name))
        if result == nil {
            let r = ChatRunner(transport: URLSessionTransport(apiKey: { APIKeys.current() }), tools: [])
            if let text = try? await r.complete(WrapUp.request(for: transcript, model: store.settings.model)) {
                result = WrapUp.parse(text)
            }
        }
        guard let result else { return }
        if !result.summary.isEmpty {
            // The same conversation keeps one summary, brought up to date
            if let earlier, store.conversations.contains(where: { $0.id == earlier }) {
                store.editConversation(earlier, text: result.summary)
            } else {
                let s = ConversationSummary(day: today, text: result.summary)
                store.addConversation(s)
                if ofLiveChat, !messages.isEmpty { summaryID = s.id }
            }
        }
        let added = store.aboutYou.suggest(result.facts)
        noted.append(contentsOf: added)
    }

    // MARK: home screen

    func refreshHeadline() {
        let hour = Calendar.current.component(.hour, from: Date())
        let name = store.snapshot?.displayName.map { ", \($0)" } ?? ""
        // A few ways to say it, chosen afresh each part of the day (steady while it lasts)
        let part: String, options: [String]
        switch hour {
        case 5..<12:
            part = "morning"; pill = "MORNING BRIEFING"
            options = ["Good morning\(name).", "Morning\(name). What's first today?", "Morning\(name). Ready when you are."]
        case 12..<17:
            part = "afternoon"; pill = "YOUR DAY"
            options = ["Good afternoon\(name).", "Afternoon\(name). How's it going?", "How's the day treating you\(name)?"]
        case 17..<22:
            part = "evening"; pill = "DAILY REFLECTION"
            options = ["Good evening\(name). How was today?", "Evening\(name). How did the day go?", "Evening\(name). Anything worth telling me about today?"]
        default:
            part = "late"; pill = "LATE NIGHT"
            options = ["It's late\(name). Anything on your mind?", "Still up\(name)? What's on your mind?", "Late one tonight\(name). Want to talk?"]
        }
        if headlineChoice?.part != part { headlineChoice = (part, Int.random(in: 0..<options.count)) }
        headline = options[min(headlineChoice!.index, options.count - 1)]
        if store.snapshot == nil { headline = "Import your Chronicles export to get started."; pill = "WELCOME" }
        if APIKeys.current() == nil { headline = "Add your Anthropic API key in Settings, or turn on In-App AI in Chronicles."; pill = "SETUP" }
    }

    @ObservationIgnored private var headlineChoice: (part: String, index: Int)?

    func dismissNoted(_ id: UUID) { noted.removeAll { $0.id == id } }

    #if DEBUG
    /// Debug builds only (--snapshot … --chat-demo): a sample chat to check the look.
    func debugFill() {
        lines = [ChatLine(who: .you, text: "The doctor said everything looks good!"),
                 ChatLine(who: .smith, text: "*beams* Oh, that's such a relief. You've been carrying that one around all week, and now you can finally put it down."),
                 ChatLine(who: .you, text: "Right? I celebrated with a giant cinnamon roll."),
                 ChatLine(who: .smith, text: "*laughs* As you should. Medical good news legally requires a pastry.",
                          sent: SentInfo(parts: [.init(title: "Your message", text: "Right? I celebrated with a giant cinnamon roll."),
                                                 .init(title: "Earlier in this chat", text: "2 earlier messages in this conversation."),
                                                 .init(title: "Your day, from Chronicles", text: "Now: Thursday 26 November 2026, 10:15.\n\nEvents today: none."),
                                                 .init(title: "Never sent", text: "Journal entry text, money amounts, wellness notes, and anything you keep from AI in Chronicles.")]))]
        turns = [Turn(lineID: lines[2].id, messageCount: 2, text: lines[2].text)]
    }
    #endif

    /// The memory tool: saves at once and shows "Smith noted: …" with Edit / Undo.
    func memory(_ action: MemoryTool.Action) -> String {
        guard store.settings.memoryEnabled || { if case .forget = action { return true }; return false }() else {
            return "Memory is off in Settings, so nothing was saved."
        }
        switch action {
        case .note(let text, let category):
            guard let fact = store.aboutYou.note(text, category: category == .sensitive ? .updates : category, day: today) else {
                return store.aboutYou.paused ? "Learning is paused, so nothing was saved." : "Already known."
            }
            noted.append(fact)
            return "Saved to memory."
        case .remember(let text, let category):
            let fact = store.aboutYou.remember(text, category: category)
            noted.append(fact)
            return "Saved."
        case .forget:
            return store.handleMemory(action)
        }
    }

    func dismissConcernsToday() {
        store.updateLocalSettings { s in for c in concernsShown { s.concerns.dismissed[c.id] = today } }
    }
}

extension SmithStore {
    /// From the memory tool: "remember …" saves a confirmed fact; "forget …" deletes the best match.
    func handleMemory(_ action: MemoryTool.Action) -> String {
        switch action {
        case .remember(let text, let category):
            aboutYou.remember(text, category: category)
            return "Saved."
        case .note(let text, let category):
            return aboutYou.note(text, category: category, day: Day.key()) == nil ? "Already known." : "Saved to memory."
        case .forget(let words):
            let needle = Set(words.lowercased().split(separator: " ").map(String.init).filter { $0.count > 2 })
            let best = aboutYou.facts.max { a, b in
                needle.intersection(a.text.lowercased().split(separator: " ").map(String.init)).count
                    < needle.intersection(b.text.lowercased().split(separator: " ").map(String.init)).count
            }
            guard let best, !needle.intersection(best.text.lowercased().split(separator: " ").map(String.init)).isEmpty else {
                return "Nothing saved matches that."
            }
            aboutYou.delete(best.id)
            return "Deleted: \(best.text)"
        }
    }
}

/// Letters, signed with the name chosen in Settings (the assistant's own name by default).
@MainActor
enum HenryWriter {
    struct Written { var text: String; var risk: RiskResult }

    static func write(store: SmithStore, message: String?) async throws -> Written {
        let safety = AppModel.shared.safety
        AppModel.shared.chronicles.checkAutoLock()
        guard AppModel.shared.chronicles.isUnlocked else { throw ClaudeError.unavailable("Open Smith and sign in to Chronicles first.") }
        if let reason = safety.unavailableReason { throw ClaudeError.unavailable(reason) }
        let p = store.settings.henry
        let theirs = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // What they wrote is screened like the chat: a likely minor, and signs of risk
        var risk = RiskResult.none
        if !theirs.isEmpty {
            if ChatSafety.minorPattern(theirs) {
                safety.lockForMinor()
                throw ClaudeError.unavailable("Letters are for adults 18 and older.")
            }
            risk = ChatSafety.patternScreen(theirs).max(await safety.classify([(user: true, text: theirs)]))
            if risk.minor {
                safety.lockForMinor()
                throw ClaudeError.unavailable("Letters are for adults 18 and older.")
            }
        }
        var day: String?
        if p.drawOnMyDay, let snap = store.snapshot {
            // Goals and the general journal digest only; no tasks, bills or health.
            let goals = snap.goals.filter { $0.status == "in_progress" }.map(\.title).prefix(3)
            day = ([goals.isEmpty ? nil : "Working toward: " + goals.joined(separator: ", ") + "."] + [store.journalDigestText])
                .compactMap { $0 }.joined(separator: "\n")
        }
        let about = store.aboutYou.shareWithHenry ? store.aboutYou.contextText() : nil
        var system = [SystemBlock(HenryPrompt.system(p, defaultName: store.settings.name), cache: true)]
        if risk.isRisk { system.append(SystemBlock(ChatSafety.letterSafeRules)) }
        // Never the same letter twice: the recent ones are shown, with a fresh focus to write from
        let recent = store.letters.sorted { $0.date > $1.date }.prefix(5).map { String($0.text.prefix(700)) }
        let focus = ["one small, specific moment from their recent days", "something you admire in them that you haven't said before",
                     "a hope or a plan for the two of you", "a memory you imagine sharing with them", "something playful or teasing",
                     "what they bring to an ordinary evening", "a question you'd love to hear them answer", "a quiet, tender thought"].randomElement()!
        var ask = HenryPrompt.userMessage(theirMessage: message, dayContext: day, aboutThem: about,
                                          theirName: store.snapshot?.displayName)
        ask += "\n\nThis letter's focus: \(focus)."
        if !recent.isEmpty {
            ask += "\n\nLetters you've already written them (newest first). Write something new: a different greeting and opening line, "
                + "different images and phrases, a different sign-off, and don't retell the same events or details:\n\n"
                + recent.enumerated().map { "Letter \($0.offset + 1):\n\($0.element)" }.joined(separator: "\n\n")
        }
        // The whole list, not only their own additions: a banned word the letter uses is cut
        // out afterwards, which leaves a hole in the sentence ("You looked tonight")
        let banned = store.settings.bannedPhrases
        if !banned.isEmpty { system.append(SystemBlock("Never use these words or phrases: " + banned.map { "\"\($0)\"" }.joined(separator: ", ") + ".")) }
        let runner = ChatRunner(transport: URLSessionTransport(apiKey: { APIKeys.current() }), tools: [])
        let req = ClaudeRequest(model: store.settings.model, maxTokens: 4000, effort: "medium", system: system,
                                messages: [["role": "user", "content": .string(ask)]])
        var text = try await runner.complete(req)
        let guardrail = PhraseGuard(phrases: store.settings.bannedPhrases)
        text = guardrail.findBanned(in: text).isEmpty ? text : guardrail.scrub(text)
        // The letter itself is screened before it's shown or read aloud
        if let kind = await safety.harmfulKind(reply: text, lastUser: theirs) {
            risk = risk.max(RiskResult(rating: .elevated, kind: kind))
            let name = store.settings.letterName
            text = """
                My dear,

                Some of what you're carrying tonight is bigger than a letter can hold, and I care about you too much to \
                pretend otherwise. Please reach out to someone who can be with you in it: call or text 988 any time, or \
                call 911 if you're in danger.

                Write to me again whenever you like.

                \(name)
                """
        }
        return Written(text: text, risk: risk)
    }
}

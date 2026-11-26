import Foundation
import Observation
import SmithCore

/// The reply line being filled in, as each sentence's audio starts.
final class ReplyLine { var id: UUID? }

/// One line in the chat.
struct ChatLine: Identifiable, Equatable {
    enum Who { case you, smith, note }
    let id = UUID()
    var who: Who
    var text: String
}

/// The live conversation. It exists only in memory; when it ends, Smith keeps
/// a short summary (and maybe a fact or two) and the transcript is discarded.
@MainActor @Observable
final class SmithBrain {
    let store: SmithStore
    let voice: VoiceIO
    let weather: WeatherService
    let chronicles: ChroniclesConnection

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

    init(store: SmithStore, voice: VoiceIO, weather: WeatherService, chronicles: ChroniclesConnection) {
        self.store = store; self.voice = voice; self.weather = weather; self.chronicles = chronicles
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
            : chronicles.lastError.map { "I couldn't reach Chronicles just now (\($0))." }
        var ctx = SmithContext(name: s.name, snapshot: store.snapshot, journalDigest: store.journalDigestText,
                            aboutYou: s.memoryEnabled ? store.aboutYou.contextText() : nil,
                            recentConversations: s.memoryEnabled ? Array(store.conversations.suffix(6)) : [],
                            concerns: concerns, freshnessNote: freshness,
                            privateBillIDs: s.privateBills, includeGoalMention: s.goalMentionInBriefing,
                            weatherLine: weather.report?.line)
        ctx.canAct = chronicles.isUnlocked
        return ctx
    }

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

    private func tools() -> [LocalTool] {
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
        ] + (chronicles.isUnlocked ? ChroniclesActionTools.all(chronicles.actionContext(estimate: nutrientEstimator())) : [])
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
        ChatRunner(transport: URLSessionTransport(apiKey: { APIKeys.current() }), tools: tools())
    }

    // MARK: talking

    /// Sends what they said or typed. `spoken` replies are kept speakable and read aloud.
    func send(_ text: String, spoken: Bool) async {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        chronicles.noteActivity()
        idleTimer?.invalidate()
        let line = ChatLine(who: .you, text: t)
        turns.append(Turn(lineID: line.id, messageCount: messages.count, text: t))
        lines.append(line)
        messages.append(["role": "user", "content": .string(t)])
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
    func stop() -> String? {
        conversationMode = false
        voice.cancelListening()
        voice.stopSpeaking()
        guard isThinking else { return nil }
        return removeLastTurn()
    }

    /// Clears this chat. Nothing is kept from it: no summary, no facts.
    func startOver() {
        current?.cancel(); current = nil
        voice.cancelListening(); voice.stopSpeaking()
        conversationMode = false
        idleTimer?.invalidate()
        messages = []; lines = []; turns = []; noted = []
        isThinking = false; workingOn = nil
        refreshHeadline()
    }

    private func respond(spoken: Bool) async {
        let speak = spoken || (store.settings.speakTypedReplies && !store.settings.muted)
        isThinking = true
        lastError = nil
        defer { isThinking = false; workingOn = nil; scheduleIdleEnd() }
        let ctx = context()
        let runner = self.runner
        // Medium: enough thought to catch sarcasm, irony and a running joke; still quick
        let request = ClaudeRequest(model: store.settings.model, maxTokens: 16000, effort: "medium",
                                    system: ctx.systemBlocks(spoken: speak && !store.settings.muted),
                                    messages: messages, tools: runner.toolDefinitions(webSearch: true))
        let voice = self.voice
        let muted = store.settings.muted
        // Events arrive off the main thread; an ordered stream keeps sentences in order.
        let (events, sink) = AsyncStream<ChatEvent>.makeStream()
        let turnID = turns.last?.lineID
        let consumer = Task { @MainActor in
            let reply = ReplyLine()
            for await event in events {
                // Stopped or taken back: nothing more from this answer is shown or spoken
                guard self.turns.last?.lineID == turnID, self.isThinking else { continue }
                switch event {
                case .working(let name): self.workingOn = Self.workingLabel(name)
                case .sentence(let s):
                    self.workingOn = nil
                    // Shown like subtitles: as its audio starts (at once when muted or if speech can't play)
                    let show = { [weak self] in
                        guard let self, self.turns.last?.lineID == turnID else { return }
                        if let id = reply.id, let i = self.lines.firstIndex(where: { $0.id == id }) { self.lines[i].text += " " + s }
                        else { let line = ChatLine(who: .smith, text: s); reply.id = line.id; self.lines.append(line) }
                        if let id = reply.id, let line = self.lines.first(where: { $0.id == id }) { self.headline = line.text }
                    }
                    if speak && !muted { voice.speak(s, onStart: show) } else { show() }
                }
            }
        }
        do {
            let result = try await runner.run(request) { sink.yield($0) }
            sink.finish()
            await consumer.value
            // Stopped meanwhile: what was taken back stays taken back
            guard !Task.isCancelled else { return }
            messages = result.messages
            markRaised()
        } catch {
            sink.finish()
            await consumer.value
            if Task.isCancelled || error is CancellationError { return }
            // Keep the history valid: drop the unanswered question.
            if case .some(let last) = messages.last, last["role"]?.string == "user" { messages.removeLast() }
            lastError = error.localizedDescription
            lines.append(ChatLine(who: .note, text: error.localizedDescription))
        }
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
        freshnessNudge = currentNudge()
        await weather.refresh(fahrenheit: store.settings.fahrenheit)
        pill = "MORNING BRIEFING"
        let ask = """
            [Morning briefing] Greet them warmly by name if you know it, then tell them the time, the weather, \
            today's events and planned tasks, deadlines, bills due soon, medication doses, and their top priority\
            \(store.settings.goalMentionInBriefing ? ", plus a plain mention of a goal in progress (information, not a pep talk)" : ""). \
            Keep it brief and natural, the way a friend would catch them up. If there's a stale-data note, end with it.
            """
        messages.append(["role": "user", "content": .string(ask)])
        lines.append(ChatLine(who: .note, text: "Morning briefing"))
        await respond(spoken: spoken)
        store.updateLocalSettings { $0.lastGreetingDay = today }
    }

    /// For Siri: a one-shot answer without touching the live conversation.
    func oneShot(_ question: String) async -> String {
        if chronicles.isLocked { return "Unlock Smith first: open Smith and enter your Chronicles password." }
        let ctx = context()
        let runner = self.runner
        let req = ClaudeRequest(model: store.settings.model, effort: "low", system: ctx.systemBlocks(spoken: true),
                                messages: [["role": "user", "content": .string(question)]],
                                tools: runner.toolDefinitions(webSearch: true))
        do {
            let r = try await runner.run(req) { _ in }
            await wrapUp(r.messages)
            return r.text
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: ending a conversation

    private func scheduleIdleEnd() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: false) { [weak self] _ in
            Task { @MainActor in await self?.endConversation() }
        }
    }

    /// "That's all", closing the panel, or 10 idle minutes. Keeps a summary; discards the transcript.
    func endConversation() async {
        idleTimer?.invalidate()
        voice.cancelListening()
        conversationMode = false
        let transcript = messages
        messages = []
        lines = []
        turns = []
        noted = []
        refreshHeadline()
        guard transcript.contains(where: { $0["role"]?.string == "assistant" }) else { return }
        await wrapUp(transcript)
    }

    private func wrapUp(_ transcript: [JSONValue]) async {
        guard store.settings.memoryEnabled else { return }
        var result = await OnDeviceWrapUp.run(transcript: WrapUp.transcript(transcript, name: store.settings.name))
        if result == nil {
            let r = ChatRunner(transport: URLSessionTransport(apiKey: { APIKeys.current() }), tools: [])
            if let text = try? await r.complete(WrapUp.request(for: transcript, model: store.settings.model)) {
                result = WrapUp.parse(text)
            }
        }
        guard let result else { return }
        if !result.summary.isEmpty { store.addConversation(ConversationSummary(day: today, text: result.summary)) }
        let added = store.aboutYou.suggest(result.facts)
        noted.append(contentsOf: added)
    }

    // MARK: home screen

    func refreshHeadline() {
        let hour = Calendar.current.component(.hour, from: Date())
        let name = store.snapshot?.displayName.map { ", \($0)" } ?? ""
        switch hour {
        case 5..<12: headline = "Good morning\(name)."; pill = "MORNING BRIEFING"
        case 12..<17: headline = "Good afternoon\(name)."; pill = "YOUR DAY"
        case 17..<22: headline = "Good evening\(name). How was today?"; pill = "DAILY REFLECTION"
        default: headline = "It's late\(name). Anything on your mind?"; pill = "LATE NIGHT"
        }
        if store.snapshot == nil { headline = "Import your Chronicles export to get started."; pill = "WELCOME" }
        if APIKeys.current() == nil { headline = "Add your Anthropic API key in Settings, or turn on In-App AI in Chronicles."; pill = "SETUP" }
    }

    func dismissNoted(_ id: UUID) { noted.removeAll { $0.id == id } }

    #if DEBUG
    /// Debug builds only (--snapshot … --chat-demo): a sample chat to check the look.
    func debugFill() {
        lines = [ChatLine(who: .you, text: "The doctor said everything looks good!"),
                 ChatLine(who: .smith, text: "*beams* Oh, that's such a relief. You've been carrying that one around all week, and now you can finally put it down."),
                 ChatLine(who: .you, text: "Right? I celebrated with a giant cinnamon roll."),
                 ChatLine(who: .smith, text: "*laughs* As you should. Medical good news legally requires a pastry.")]
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
    static func write(store: SmithStore, message: String?) async throws -> String {
        let p = store.settings.henry
        var day: String?
        if p.drawOnMyDay, let snap = store.snapshot {
            // Goals and the general journal digest only; no tasks, bills or health.
            let goals = snap.goals.filter { $0.status == "in_progress" }.map(\.title).prefix(3)
            day = ([goals.isEmpty ? nil : "Working toward: " + goals.joined(separator: ", ") + "."] + [store.journalDigestText])
                .compactMap { $0 }.joined(separator: "\n")
        }
        let about = store.aboutYou.shareWithHenry ? store.aboutYou.contextText() : nil
        let runner = ChatRunner(transport: URLSessionTransport(apiKey: { APIKeys.current() }), tools: [])
        let req = ClaudeRequest(model: store.settings.model, maxTokens: 4000, effort: "medium",
                                system: [SystemBlock(HenryPrompt.system(p, defaultName: store.settings.name), cache: true)],
                                messages: [["role": "user", "content": .string(HenryPrompt.userMessage(theirMessage: message, dayContext: day, aboutThem: about))]])
        let text = try await runner.complete(req)
        let guardrail = PhraseGuard()
        return guardrail.findBanned(in: text).isEmpty ? text : guardrail.scrub(text)
    }
}

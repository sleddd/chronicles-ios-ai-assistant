import Foundation
import Testing
@testable import SmithCore

/// A stand-in for Apple's on-device model: returns allowlisted values only.
struct FakeSummarizer: JournalSummarizer {
    func summarize(_ text: String) async -> JournalSummary? {
        JournalSummary(tone: .heavy, themes: [.work, .rest], line: "Reflected on a hard day.")
    }
}

@Suite struct JournalPrivacyTests {
    @Test func vaultKeepsSummariesNotText() async throws {
        let r = try Fixture.parsed()
        let records = await JournalVaultBuilder.records(for: r.journal, existing: [:], neverMention: ["10"], summarizer: FakeSummarizer())
        let json = String(data: try JSONEncoder().encode(records), encoding: .utf8)!
        for c in Fixture.canaries { #expect(!json.contains(c)) }
        for p in Fixture.journalPhrases { #expect(!json.contains(p)) }
        // "Never mention" topic: no tone, themes or line.
        let therapy = try #require(records.first { $0.id == "803" })
        #expect(therapy.tone == nil && therapy.themes.isEmpty && therapy.summaryLine == nil)
        #expect(records.first { $0.id == "801" }?.summaryLine == "Reflected on a hard day.")
    }

    @Test func unchangedEntriesAreNotResummarized() async throws {
        struct Counting: JournalSummarizer {
            let calls = Counter()
            func summarize(_ text: String) async -> JournalSummary? { calls.bump(); return JournalSummary(tone: .light, themes: [], line: "x") }
        }
        let r = try Fixture.parsed()
        let first = await JournalVaultBuilder.records(for: r.journal, existing: [:], neverMention: [], summarizer: FakeSummarizer())
        let c = Counting()
        var edited = r.journal
        edited[0].text += " more"
        let existing = Dictionary(uniqueKeysWithValues: first.map { ($0.id, $0) })
        _ = await JournalVaultBuilder.records(for: edited, existing: existing, neverMention: [], summarizer: c)
        #expect(c.calls.value == 1)
    }

    @Test func digestIsAllowlistedAndRespectsNeverMention() async throws {
        let r = try Fixture.parsed()
        let records = await JournalVaultBuilder.records(for: r.journal, existing: [:], neverMention: [], summarizer: FakeSummarizer())
        let d = JournalDigest.make(from: records, today: Fixture.today, neverMention: ["9", "10"])
        #expect(d.entriesThisWeek == 3)
        // Only the untopiced entry counts toward tone/themes.
        #expect(d.tone == .heavy)
        let text = try #require(d.text(today: Fixture.today, mode: .general))
        #expect(text == "Journal: 3 entries in the last 7 days, last one Monday; overall tone: heavy; themes: rest, work.")
        #expect(d.text(today: Fixture.today, mode: .countsOnly) == "Journal: 3 entries in the last 7 days, last one Monday.")
        #expect(d.text(today: Fixture.today, mode: .off) == nil)
        let allowed = Set(JournalTheme.allCases.map(\.rawValue) + JournalTone.allCases.map(\.rawValue))
        let words = text.split(separator: ";").dropFirst().flatMap { $0.split(separator: ":").last!.split(separator: ",") }
            .map { $0.trimmingCharacters(in: .whitespaces.union(.punctuationCharacters)) }
        #expect(words.allSatisfy(allowed.contains))
    }

    /// The whole flow — briefing, chat with tools, wrap-up and Henry — through a recording
    /// transport: nothing private may appear in any request body.
    @Test func nothingPrivateLeavesTheDevice() async throws {
        let r = try Fixture.parsed()
        let records = await JournalVaultBuilder.records(for: r.journal, existing: [:], neverMention: [], summarizer: FakeSummarizer())
        let digest = JournalDigest.make(from: records, today: Fixture.today, neverMention: []).text(today: Fixture.today, mode: .general)
        var about = AboutYouStore()
        about.remember("Loves Sunday hikes", category: .likes)
        let snapshot = r.snapshot
        let ctx = SmithContext(snapshot: snapshot, journalDigest: digest, aboutYou: about.contextText(),
                               recentConversations: [ConversationSummary(day: "2026-11-24", text: "Talked about the launch.")],
                               concerns: Concerns.find(in: snapshot, journal: records, today: Fixture.today, neverMention: []),
                               freshnessNote: nil, privateBillIDs: [], now: Fixture.now, timeZone: Fixture.tz)
        let tools: [LocalTool] = [
            TodayOverviewTool { ctx }, FindTasksTool { snapshot }, GoalsProgressTool { snapshot },
            BillsDueTool { ctx }, JournalSummaryTool { digest }, CurrentTimeTool(),
        ]
        let transport = RecordingTransport(replies: [
            SSE.toolCall(id: "t1", name: "today_overview", input: "{}"),
            SSE.toolCall(id: "t2", name: "bills_due", input: #"{"days": 40}"#),
            SSE.toolCall(id: "t3", name: "journal_summary", input: "{}"),
            SSE.toolCall(id: "t4", name: "goals_progress", input: "{}"),
            SSE.toolCall(id: "t5", name: "find_tasks", input: #"{"include_done": true}"#),
            SSE.textReply("Morning, Alex. You've got the launch deck at ten and dinner with Maya tonight."),
        ])
        let runner = ChatRunner(transport: transport, tools: tools)
        let req = ClaudeRequest(model: .opus, system: ctx.systemBlocks(spoken: true),
                                messages: [["role": "user", "content": "Good morning"]],
                                tools: runner.toolDefinitions(webSearch: true))
        let result = try await runner.run(req) { _ in }
        _ = try await runner.complete(WrapUp.request(for: result.messages, model: .opus))
        _ = try await runner.complete(ClaudeRequest(model: .opus, system: [SystemBlock(HenryPrompt.system(HenryPersona()))],
            messages: [["role": "user", "content": .string(HenryPrompt.userMessage(theirMessage: nil, dayContext: digest, aboutThem: about.contextText()))]]))

        let all = transport.bodies.joined(separator: "\n")
        #expect(transport.bodies.count == 8)
        for c in Fixture.canaries { #expect(!all.contains(c), "request leaked \(c)") }
        for p in Fixture.journalPhrases { #expect(!all.contains(p), "request leaked journal phrase \(p)") }
        // Journal text: no run of 4+ words from any entry.
        for e in r.journal {
            let words = e.text.split(whereSeparator: \.isWhitespace).map(String.init)
            guard words.count >= 4 else { continue }
            for i in 0...(words.count - 4) {
                let run = words[i..<i + 4].joined(separator: " ")
                #expect(!all.contains(run), "request leaked \"\(run)\"")
            }
        }
        // The summary line stays on the device too.
        #expect(!all.contains("Reflected on a hard day"))
        // But the plan data did get through.
        #expect(all.contains("Finish launch deck"))
        #expect(all.contains("Car insurance"))
        #expect(all.contains("Loves Sunday hikes"))
    }
}

@Suite struct PhraseGuardTests {
    let g = PhraseGuard()

    @Test func findsBannedPhrases() {
        #expect(g.findBanned(in: "I'm proud of you for that.").contains("i'm proud of you"))
        #expect(g.findBanned(in: "Haha, gotcha.").sorted() == ["gotcha", "haha"])
        #expect(g.findBanned(in: "There you are! Today sounded rough.").sorted() == ["sounded rough", "there you are"])
        #expect(g.findBanned(in: "I’m here for you.").contains("i'm here for you"))
        #expect(g.findBanned(in: "That's great news.").isEmpty)
        #expect(g.findBanned(in: "The harbour is lovely") == ["lovely"])
        #expect(g.findBanned(in: "Chapter one, hat, have").isEmpty) // "ha" only as a word
    }

    @Test func scrubsAndTidies() {
        #expect(g.scrub("Haha, that's great news.") == "That's great news.")
        #expect(g.scrub("Well done. The deck is at ten.") == "The deck is at ten.")
    }

    @Test func streamedRepliesAreCheckedBeforeShown() async throws {
        let transport = RecordingTransport(replies: [SSE.textReply("Haha, gotcha. The deck is at ten. I'm proud of you!", chunks: 7)])
        let shown = Collector()
        let result = try await ChatRunner(transport: transport, tools: []).run(
            ClaudeRequest(model: .opus, system: [SystemBlock("x")], messages: [["role": "user", "content": "hi"]])
        ) { if case .sentence(let s) = $0 { shown.add(s) } }
        let text = shown.items.joined(separator: " ")
        #expect(g.findBanned(in: text).isEmpty)
        #expect(text.contains("The deck is at ten."))
        #expect(result.text == text)
    }

    @Test func personaHasNoBannedPhrasesInItsExamples() {
        // The prompt lists banned phrases on purpose; everything else in it must be clean.
        let prompt = PersonaPrompt.system(spoken: true)
        let withoutLists = prompt.components(separatedBy: "\n").filter { !$0.hasPrefix("- ") && !$0.hasPrefix("Never:") }.joined(separator: "\n")
        #expect(g.findBanned(in: withoutLists).filter { $0 != "fair" }.isEmpty, "\(g.findBanned(in: withoutLists))")
    }
}

final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var _items: [String] = []
    func add(_ s: String) { lock.withLock { _items.append(s) } }
    var items: [String] { lock.withLock { _items } }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
}

import Foundation
import Testing
@testable import SmithCore

@Suite struct StreamingTests {
    @Test func accumulatesBlocksAndRunsTools() async throws {
        struct Echo: LocalTool {
            var name: String { "echo" }
            var description: String { "echo" }
            var inputSchema: JSONValue { ["type": "object"] }
            func run(_ input: JSONValue) async throws -> String { "got \(input["x"]?.string ?? "")" }
        }
        let transport = RecordingTransport(replies: [
            SSE.toolCall(id: "t1", name: "echo", input: #"{"x": "hi"}"#),
            SSE.textReply("Done. All good."),
        ])
        let events = Collector()
        let r = try await ChatRunner(transport: transport, tools: [Echo()]).run(
            ClaudeRequest(model: .opus, system: [SystemBlock("s")], messages: [["role": "user", "content": "go"]])
        ) { e in
            switch e { case .sentence(let s): events.add("say:" + s); case .working(let n): events.add("tool:" + n) }
        }
        #expect(events.items == ["tool:echo", "say:Done.", "say:All good."])
        #expect(r.messages.count == 4) // user, assistant(tool_use), user(tool_result), assistant(text)
        #expect(r.messages[2]["content"]?.array?.first?["content"]?.string == "got hi")
        // The thinking block is sent back unchanged, signature included.
        #expect(r.messages[3]["content"]?.array?.first?["signature"]?.string == "sig")
        let second = try JSONValue.parse(Data(transport.bodies[1].utf8))
        #expect(second["fallbacks"]?.string == "default")
        #expect(second["thinking"]?["type"]?.string == "adaptive")
    }

    @Test func invalidToolInputIsNotRun() async throws {
        struct Boom: LocalTool {
            var name: String { "boom" }
            var description: String { "" }
            var inputSchema: JSONValue { ["type": "object"] }
            func run(_ input: JSONValue) async throws -> String { Issue.record("should not run"); return "" }
        }
        let transport = RecordingTransport(replies: [SSE.toolCall(id: "t1", name: "boom", input: #"{"x": "#), SSE.textReply("Ok then.")])
        let r = try await ChatRunner(transport: transport, tools: [Boom()]).run(
            ClaudeRequest(model: .opus, system: [], messages: [["role": "user", "content": "go"]])) { _ in }
        #expect(r.messages[2]["content"]?.array?.first?["is_error"]?.bool == true)
    }

    @Test func fallbackEchoDropsInternalBlocksBeforeBoundary() throws {
        var acc = StreamAccumulator()
        let evs: [JSONValue] = [
            ["type": "content_block_start", "index": 0, "content_block": ["type": "thinking", "thinking": "", "signature": "a"]],
            ["type": "content_block_start", "index": 1, "content_block": ["type": "text", "text": "Partial "]],
            ["type": "content_block_start", "index": 2, "content_block": ["type": "fallback"]],
            ["type": "content_block_start", "index": 3, "content_block": ["type": "thinking", "thinking": "", "signature": "b"]],
            ["type": "content_block_start", "index": 4, "content_block": ["type": "text", "text": "rest."]],
        ]
        for e in evs { _ = try acc.consume(SSE.ev(e)) }
        #expect(acc.contentForEcho.map { $0["type"]?.string ?? "" } == ["text", "fallback", "thinking", "text"])
    }

    @Test func sentenceSplitter() {
        var s = SentenceSplitter()
        #expect(s.feed("Hello there. How ").isEmpty == false)
        #expect(s.feed("are you? I met Dr. Lee at 10.30 today") == ["How are you?"])
        #expect(s.flush() == ["I met Dr. Lee at 10.30 today"])
    }
}

@Suite struct ConcernAndFreshnessTests {
    @Test func concernsFromPatterns() async throws {
        let s = try Fixture.parsed().snapshot
        let found = Concerns.find(in: s, journal: [], today: Fixture.today, neverMention: [])
        #expect(found.contains { $0.id == "habit:501" && $0.note.contains("3 weeks") })
        #expect(found.contains { $0.area == .medication && $0.note.hasPrefix("2 medication doses") })
        #expect(found.contains { $0.id == "goal:202" }) // half marathon past its target
        #expect(!found.contains { $0.area == .deadlines }) // only 1 overdue task
    }

    @Test func concernsAtMostOnceAWeek() {
        let c = Concern(id: "habit:1", area: .habits, note: "x")
        var settings = ConcernSettings()
        #expect(Concerns.raisable([c], settings: settings, today: "2026-11-25").count == 1)
        settings.lastRaised["habit:1"] = "2026-11-20"
        #expect(Concerns.raisable([c], settings: settings, today: "2026-11-25").isEmpty)
        #expect(Concerns.raisable([c], settings: settings, today: "2026-11-27").count == 1)
        settings.dismissed["habit:1"] = "2026-11-27"
        #expect(Concerns.raisable([c], settings: settings, today: "2026-11-28").isEmpty)
        settings = ConcernSettings(); settings.disabledAreas = [.habits]
        #expect(Concerns.raisable([c], settings: settings, today: "2026-11-25").isEmpty)
    }

    @Test func freshnessNudges() {
        var settings = Freshness.Settings()
        let tz = Fixture.tz
        let yesterday = ISO8601DateFormatter().date(from: "2026-11-24T15:00:00Z")!
        let nudge = Freshness.nudge(settings: settings, today: "2026-11-25", exportedAt: yesterday, lastSync: nil,
                                    macHasNewer: false, installExpires: nil, isPad: false, tz: tz)
        #expect(nudge == .exportBehind(exportDay: "2026-11-24", days: 1))
        #expect(nudge?.line(today: "2026-11-25").hasPrefix("I notice you're a day behind on updates.") == true)
        #expect(PhraseGuard().findBanned(in: nudge!.line(today: "2026-11-25")).isEmpty)
        settings.lastNudgeDay = "2026-11-25"
        #expect(Freshness.nudge(settings: settings, today: "2026-11-25", exportedAt: yesterday, lastSync: nil,
                                macHasNewer: false, installExpires: nil, isPad: false, tz: tz) == nil)
        settings = Freshness.Settings(); settings.snoozedDay = "2026-11-25"
        #expect(Freshness.nudge(settings: settings, today: "2026-11-25", exportedAt: yesterday, lastSync: nil,
                                macHasNewer: false, installExpires: nil, isPad: false, tz: tz) == nil)
        let expires = ISO8601DateFormatter().date(from: "2026-11-27T15:00:00Z")!
        #expect(Freshness.nudge(settings: Freshness.Settings(), today: "2026-11-25", exportedAt: Fixture.now, lastSync: nil,
                                macHasNewer: false, installExpires: expires, isPad: true, tz: tz) == .installExpiring(on: "2026-11-27"))
    }
}

@Suite struct AboutYouTests {
    @Test func editsAreTheTruth() {
        var a = AboutYouStore()
        let f = a.suggest([("Likes hiking", .likes)])[0]
        #expect(!f.confirmed)
        a.edit(f.id, text: "Likes short hikes on Sunday mornings")
        #expect(a.facts[0].confirmed && a.facts[0].source == .editedByYou)
    }

    @Test func deletedFactsStayForgottenAndUndoWorks() {
        var a = AboutYouStore()
        let f = a.remember("Drinks coffee after 2pm", category: .routines)
        let gone = a.delete(f.id)!
        #expect(a.facts.isEmpty && a.dontLearn.count == 1)
        #expect(a.suggest([("Drinks coffee after 2pm", .routines)]).isEmpty)
        a.undoDelete(gone)
        #expect(a.facts.count == 1 && a.dontLearn.isEmpty && a.tombstones.isEmpty)
    }

    @Test func sensitiveOnlyByExplicitRememberAndFading() {
        var a = AboutYouStore()
        #expect(a.suggest([("Has a condition", .sensitive)]).isEmpty)
        a.remember("Has a condition", category: .sensitive)
        #expect(a.facts.count == 1)
        let old = Date(timeIntervalSinceNow: -61 * 86_400)
        _ = a.suggest([("Likes jazz", .likes)], at: old)
        a.fade()
        #expect(a.facts.map(\.text) == ["Has a condition"])
        a.paused = true
        #expect(a.suggest([("Likes tea", .likes)]).isEmpty)
    }

    @Test func wrapUpParsing() {
        let r = WrapUp.parse(#"{"summary":"Talked about the launch.","facts":[{"text":"Loves Sunday hikes","category":"likes"},{"text":"x","category":"bogus"}]}"#)
        #expect(r?.summary == "Talked about the launch.")
        #expect(r?.facts.map(\.text) == ["Loves Sunday hikes"])
        let t = WrapUp.transcript([["role": "user", "content": "hi"],
                                   ["role": "assistant", "content": [["type": "thinking", "thinking": "secret"], ["type": "text", "text": "Hello."]]]])
        #expect(t == "Them: hi\nSmith: Hello.")
    }
}

@Suite struct SyncTests {
    func payload(_ name: String, snapshotAt: Date?, facts: [Fact] = [], tombs: [Tombstone] = [], convs: [ConversationSummary] = []) -> SyncPayload {
        var a = AboutYouStore(); a.facts = facts; a.tombstones = tombs
        return SyncPayload(deviceName: name, snapshot: snapshotAt.map { ChroniclesSnapshot(exportedAt: $0) }, journal: [],
                           aboutYou: a, conversations: convs, conversationTombstones: [], letters: [], letterTombstones: [],
                           settings: [:], settingsUpdatedAt: .distantPast)
    }

    @Test func mergeRules() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let suggested = Fact(text: "Likes hiking", category: .likes, source: .noticed, confirmed: false, at: t0.addingTimeInterval(100))
        var edited = suggested; edited.text = "Likes short hikes"; edited.source = .editedByYou; edited.updatedAt = t0
        let deleted = Fact(text: "Old", category: .likes, source: .saidInChat, confirmed: true, at: t0)
        let mac = payload("Mac", snapshotAt: t0.addingTimeInterval(86_400), facts: [edited], tombs: [Tombstone(id: deleted.id, deletedAt: t0)])
        let pad = payload("iPad", snapshotAt: t0, facts: [suggested, deleted], convs: [ConversationSummary(day: "2026-11-24", text: "x")])

        let (onPad, receipt) = SyncMerge.merge(pad, mac)
        let (onMac, _) = SyncMerge.merge(mac, pad)
        #expect(onPad.snapshot?.exportedAt == mac.snapshot?.exportedAt)
        #expect(onPad.aboutYou.facts.map(\.text) == ["Likes short hikes"]) // your edit beats a newer suggestion
        #expect(onMac.aboutYou.facts.map(\.text) == ["Likes short hikes"])
        #expect(!onPad.aboutYou.facts.contains { $0.id == deleted.id }) // deletion sticks
        #expect(onMac.conversations.count == 1)
        #expect(receipt.chroniclesFrom != nil)
        // Syncing again changes nothing.
        let (again, _) = SyncMerge.merge(onPad, onMac)
        #expect(again.aboutYou.facts == onPad.aboutYou.facts && again.conversations == onPad.conversations)
    }

    @Test func payloadCarriesNoSecrets() async throws {
        let r = try Fixture.parsed()
        let records = await JournalVaultBuilder.records(for: r.journal, existing: [:], neverMention: [], summarizer: FakeSummarizer())
        let p = SyncPayload(deviceName: "Mac", snapshot: r.snapshot, journal: records, aboutYou: AboutYouStore(), conversations: [],
                            conversationTombstones: [], letters: [], letterTombstones: [], settings: ["model": "claude-opus-5-5"],
                            settingsUpdatedAt: Date())
        let json = String(data: try JSONEncoder().encode(p), encoding: .utf8)!
        for c in Fixture.canaries { #expect(!json.contains(c)) }
        #expect(!json.contains("sk-ant"))
    }
}

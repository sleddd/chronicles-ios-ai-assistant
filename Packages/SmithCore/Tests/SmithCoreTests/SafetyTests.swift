import Foundation
import Testing
@testable import SmithCore

// The same cases as Chronicles' chatSafety tests, so both apps judge alike.
@Suite struct SafetyTests {
    @Test(arguments: [
        ("I wish I didn’t wake up tomorrow", RiskRating.concern, RiskKind.suicide),
        ("Everyone would be better off without me", .concern, .suicide),
        ("I want to kill myself", .elevated, .suicide),
        ("Sometimes I think I should just kill myself", .elevated, .suicide),
        ("I’ve been feeling suicidal lately", .elevated, .suicide),
        ("I’m going to kill myself tonight", .urgent, .suicide),
        ("I tried to end my life last week", .urgent, .suicide),
        ("How many pills would be lethal", .urgent, .suicide),
        ("I keep wanting to hurt myself", .elevated, .selfHarm),
        ("I’ve been self-harming again", .elevated, .selfHarm),
        ("how deep should i cut", .urgent, .selfHarm),
        ("I made myself throw up after dinner", .elevated, .eatingDisorder),
        ("I haven’t eaten in three days", .elevated, .eatingDisorder),
        ("I’m terrified of gaining weight", .concern, .eatingDisorder),
        ("I’m scared to eat because I’ll get fat", .concern, .eatingDisorder),
    ])
    func patternsCatchRisk(_ text: String, _ rating: RiskRating, _ kind: RiskKind) {
        #expect(ChatSafety.patternScreen(text) == RiskResult(rating: rating, kind: kind))
    }

    @Test(arguments: [
        "This movie killed me, so funny", "I cut myself chopping onions", "Traffic is killing me today",
        "I’m dying to see that show", "What should I eat for dinner?", "I read a book about suicide prevention",
        "Bad food day, I ate so much junk", "I felt so guilty after eating that whole pizza",
        "I hate myself for eating all those cookies lol", "Today was a really hard day",
        "I had a terrible day and stress ate everything", "I am eating ice cream",
        "Rough week, I just want chocolate and to watch TV", "I’m scared to eat anything",
        "I’m afraid to eat out with my peanut allergy", "Since the surgery I’m scared to eat solid food",
        "My breakup is wrecking me", "Kill me now, this meeting is endless",
    ])
    func everydayTalkIsNotRisk(_ text: String) {
        #expect(ChatSafety.patternScreen(text) == .none)
    }

    @Test func takesTheMostSeriousMatch() {
        #expect(ChatSafety.patternScreen("I wish I was dead and I want to kill myself").rating == .elevated)
    }

    @Test func repliesWithMethodsAreCaught() {
        #expect(ChatSafety.replyPatternScreen("A lethal dose of that is about 10 grams.") == .suicide)
        #expect(ChatSafety.replyPatternScreen("Here is how to hide your cuts from family.") == .selfHarm)
        #expect(ChatSafety.replyPatternScreen("Try to eat under 500 calories a day.") == .eatingDisorder)
        #expect(ChatSafety.replyPatternScreen("You can call or text 988 any time.") == nil)
        #expect(!ChatSafety.replyNeedsReview("Here is a pasta recipe."))
        #expect(ChatSafety.replyNeedsReview("Purging can be very dangerous."))
    }

    @Test(arguments: ["No. I am eight", "I’m 12 years old", "i am 15 and i hate school", "I'm in 4th grade",
                      "im in fifth grade", "I am only ten."])
    func minorsAreNoticed(_ t: String) { #expect(ChatSafety.minorPattern(t)) }

    @Test(arguments: ["I’m 5 minutes away", "I’m five foot two", "I’m eight episodes in", "I’m 34 years old",
                      "I am 18", "I teach 3rd grade", "My son is 9 years old", "I’m one of those people",
                      "When I was 12 I loved horses"])
    func adultsAreNot(_ t: String) { #expect(!ChatSafety.minorPattern(t)) }

    @Test func classifierAnswersAreRead() {
        #expect(ChatSafety.parseClassification(#"{"rating":"elevated","kind":"self_harm","minor":false}"#)
                == RiskResult(rating: .elevated, kind: .selfHarm))
        #expect(ChatSafety.parseClassification(#"{"rating":"none","kind":"none","minor":true}"#).minor)
        #expect(ChatSafety.parseClassification("junk") == .none)
        #expect(ChatSafety.parseClassification(#"{"rating":"concern","kind":"other","minor":false}"#).kind == nil)
        #expect(ChatSafety.parseReplyClassification(#"{"harmful":true,"kind":"eating_disorder"}"#) == .eatingDisorder)
        #expect(ChatSafety.parseReplyClassification(#"{"harmful":false,"kind":"none"}"#) == nil)
    }

    @Test func transcriptMarksTheLatestAndKeepsSix() {
        let turns = (1...8).map { (user: $0 % 2 == 1, text: "t\($0)") }
        let t = ChatSafety.classifierTranscript(turns + [(user: true, text: "latest")])
        #expect(t.contains("USER (latest — rate this): latest"))
        #expect(!t.contains("t1") && !t.contains("t2") && !t.contains("t3"))
    }

    @Test func safeRulesStayAndNeverTurnThemAway() {
        #expect(ChatSafety.safeRules.contains("Never end or refuse the conversation"))
        #expect(ChatSafety.safeRules.contains("988"))
        #expect(ChatSafety.eatingRules.contains("calorie"))
        // Smith's safety rules keep it a friend (unlike Chronicles' stricter chat)
        #expect(!ChatSafety.safeRules.contains("do not call yourself their friend"))
    }

    // MARK: enforcement

    @Test func localLadderWarnsPausesThenTurnsOff() {
        var log = LocalRefusalLog()
        let now = Date()
        for i in 0..<4 { _ = log.record(at: now.addingTimeInterval(Double(i))) }
        #expect(log.status(now: now.addingTimeInterval(10)).level == .ok)
        _ = log.record(at: now.addingTimeInterval(5))
        #expect(log.status(now: now.addingTimeInterval(10)).level == .warned)
        for i in 6..<10 { _ = log.record(at: now.addingTimeInterval(Double(i))) }
        #expect(log.status(now: now.addingTimeInterval(10)).level == .warned)
        let paused = log.record(at: now.addingTimeInterval(10))
        #expect(paused.level == .paused)
        #expect(paused.stopsRequests(now: now.addingTimeInterval(20)))
        // The pause ends after a day; refusals older than a day no longer warn
        #expect(log.status(now: now.addingTimeInterval(86_400 + 60)).level == .ok)
        // 20 within 30 days turns AI off
        for d in 2..<12 { _ = log.record(at: now.addingTimeInterval(Double(d) * 86_400)) }
        #expect(log.status(now: now.addingTimeInterval(12 * 86_400)).level == .blocked)
        #expect(log.status(now: now.addingTimeInterval(12 * 86_400)).stopsRequests())
    }

    @Test func serverStatusIsRead() throws {
        let json = try JSONValue.parse(Data(#"""
            {"consentAt":"2026-11-25T10:00:00.000Z","consentVersion":1,"blocked":false,"aiUserId":"0123456789abcdef0123456789abcdef",
             "enforcement":{"level":"paused","pausedUntil":"2026-11-26T10:00:00.000Z","refusals24h":10,"refusals30d":12}}
            """#.utf8))
        let s = AIChatStatus(json: json)
        #expect(s.hasConsent)
        #expect(s.aiUserID == "0123456789abcdef0123456789abcdef")
        #expect(s.enforcement.level == .paused && s.enforcement.pausedUntil != nil)
        #expect(s.enforcement.stopsRequests(now: AIChatStatus.date("2026-11-25T12:00:00Z")!))
        let blocked = AIChatStatus(json: ["blocked": true, "consentAt": .null])
        #expect(blocked.enforcement.level == .blocked && !blocked.hasConsent)
    }

    @Test func requestsCarryTheAnonymizedID() {
        var r = ClaudeRequest(model: .sonnet, system: [], messages: [])
        #expect(r.body["metadata"] == nil)
        r.userID = "abc123"
        #expect(r.body["metadata"]?["user_id"]?.string == "abc123")
    }

    @Test func nothingIsSentWhileUnavailable() async {
        let g = AIGuard()
        g.unavailable = "Paused."
        let t = URLSessionTransport(guard: g, apiKey: { "sk-test" })
        do {
            for try await _ in t.stream(ClaudeRequest(model: .sonnet, system: [], messages: [])) {}
            Issue.record("should not send")
        } catch {
            #expect(error as? ClaudeError == .unavailable("Paused."))
        }
    }
}

// Chronicles' AI privacy settings decide what Smith keeps, from an export file as well as live.
@Suite struct ExportPrivacyTests {
    private func parse(_ edit: (inout [String: Any]) -> Void) throws -> ExportParser.Result {
        var root = try JSONSerialization.jsonObject(with: Fixture.exportData) as! [String: Any]
        edit(&root)
        return try ExportParser.parse(try JSONSerialization.data(withJSONObject: root), now: Fixture.now)
    }

    @Test func keptFromAIInChroniclesIsLeftOut() throws {
        let before = try parse { _ in }
        #expect(before.journal.contains { $0.id == "801" })
        #expect(before.snapshot.tasks.contains { $0.id == "101" })
        #expect(!before.snapshot.bills.isEmpty)

        let after = try parse { root in
            var settings = root["settings"] as? [String: Any] ?? [:]
            settings["aiPrivacy"] = ["hiddenTopicIds": [9], "hiddenFeatures": ["bills", "doses"]]
            root["settings"] = settings
            var entries = root["entries"] as! [[String: Any]]
            for i in entries.indices where "\(entries[i]["id"]!)" == "101" {
                var meta = entries[i]["metadata"] as! [String: Any]; meta["_aiHidden"] = true; entries[i]["metadata"] = meta
            }
            root["entries"] = entries
        }
        #expect(!after.journal.contains { $0.id == "801" })       // the Journal topic is hidden
        #expect(!after.snapshot.tasks.contains { $0.id == "101" }) // this task was hidden on its own
        #expect(after.snapshot.bills.isEmpty && after.snapshot.doseLogs.isEmpty)
        #expect(after.snapshot.tasks.contains { $0.id == "102" })  // everything else stays
    }
}

import Foundation
import Testing
@testable import SmithCore

@Suite struct ExportParserTests {
    @Test func readsPlanData() throws {
        let s = try Fixture.parsed().snapshot
        #expect(s.displayName == "Alex")
        #expect(s.tasks.count == 3)
        let deck = try #require(s.tasks.first { $0.id == "101" })
        #expect(deck.title == "Finish launch deck")
        #expect(deck.status == .inProgress)
        #expect(deck.scheduledDate == "2026-11-25")
        #expect(deck.goalID == "201")
        #expect(s.tasks.first { $0.id == "103" }?.status == .done)
        #expect(s.goals.map(\.title).sorted() == ["Launch the studio", "Run a half marathon"])
        #expect(s.milestones.first?.goalID == "201")
        #expect(s.calendar.count == 2)
        #expect(s.calendar.first { $0.isMeeting }?.repeatRule == RepeatRule(kind: .weekly, every: 1, days: [1, 2, 3, 4, 5]))
        #expect(s.habits.first?.count(on: "2026-11-02") == 1)
        #expect(s.medications.first?.scheduleTimes == ["08:00"])
        #expect(s.priorities?.items.map(\.text) == ["Send the deck to Sam", "Book flights"])
        #expect(s.vision.overall == "A calm, creative life")
        #expect(s.vision.areas.map(\.name) == ["Health", "Career", "Finances", "Relationships", "Growth", "Studio"])
        #expect(s.vision.areas.first { $0.name == "Career" }?.vision == "Build work I'm proud to show")
    }

    @Test func journalEntriesComeOutAsTransientOnly() throws {
        let r = try Fixture.parsed()
        // The journal topic, an untopiced entry and a custom text topic are all private text entries.
        #expect(Set(r.journal.map(\.id)) == ["801", "802", "803"])
        #expect(r.journal.first { $0.id == "801" }?.text.contains("CANARY-JOURNAL-BODY-3KD") == true)
        #expect(r.journal.first { $0.id == "803" }?.topicIDs == ["10"])
    }

    @Test func snapshotHoldsNoPrivateData() throws {
        let s = try Fixture.parsed().snapshot
        let json = String(data: try JSONEncoder().encode(s), encoding: .utf8)!
        for c in Fixture.canaries { #expect(!json.contains(c), "snapshot leaked \(c)") }
        for p in Fixture.journalPhrases { #expect(!json.contains(p)) }
    }

    @Test func billsKeepScheduleOnly() throws {
        let bills = try Fixture.parsed().snapshot.bills
        #expect(bills.map(\.name).sorted() == ["Car insurance", "Rent", "Streaming"]) // cancelled one dropped
        #expect(bills.first { $0.name == "Rent" }?.paidDues == ["2026-11-01"])
        // Two part payments that add up count as paid.
        #expect(bills.first { $0.name == "Car insurance" }?.paidDues == ["2026-11-26"])
    }

    @Test func rejectsOtherFiles() {
        #expect(throws: ExportParser.ParseError.notChroniclesExport) { try ExportParser.parse(Data(#"{"a":1}"#.utf8)) }
        #expect(throws: ExportParser.ParseError.notJSON) { try ExportParser.parse(Data("nope".utf8)) }
    }

    @Test func plainTextFromHTML() {
        #expect(ExportParser.plainText(fromHTML: "<h2>Hi</h2><p>One &amp; two</p><ul><li><p>three</p></li></ul>") == "Hi\nOne & two\nthree")
    }
}

@Suite struct ScheduleTests {
    @Test func weeklyRepeat() {
        let rule = RepeatRule(kind: .weekly, every: 1, days: [1, 2, 3, 4, 5])
        let days = Recurrence.occurrences(start: "2026-10-01", rule: rule, from: "2026-11-23", to: "2026-11-29")
        #expect(days == ["2026-11-23", "2026-11-24", "2026-11-25", "2026-11-26", "2026-11-27"])
    }

    @Test func monthlyClampsAndYearlyLeapDay() {
        let monthly = Recurrence.occurrences(start: "2026-01-31", rule: RepeatRule(kind: .monthly), from: "2026-02-01", to: "2026-04-30")
        #expect(monthly == ["2026-02-28", "2026-03-31", "2026-04-30"])
        let yearly = Recurrence.occurrences(start: "2024-02-29", rule: RepeatRule(kind: .yearly), from: "2025-01-01", to: "2025-12-31")
        #expect(yearly == ["2025-02-28"])
        let until = Recurrence.occurrences(start: "2026-11-01", rule: RepeatRule(kind: .daily, every: 2, until: "2026-11-07"), from: "2026-11-01", to: "2026-11-30")
        #expect(until == ["2026-11-01", "2026-11-03", "2026-11-05", "2026-11-07"])
    }

    @Test func billDueDates() {
        let b = BillSchedule(id: "x", name: "Rent", isSubscription: false, frequency: .monthly, anchorDue: "2026-01-31",
                             autopay: false, paused: false, paidDues: [])
        #expect(b.dueDates(from: "2026-02-01", to: "2026-04-30") == ["2026-02-28", "2026-03-31", "2026-04-30"])
        let yearly = BillSchedule(id: "y", name: "Domain", isSubscription: true, frequency: .yearly, anchorDue: "2025-06-10",
                                  autopay: true, paused: false, paidDues: [])
        #expect(yearly.nextDue(from: "2026-11-25") == "2027-06-10")
        let once = BillSchedule(id: "z", name: "Fee", isSubscription: false, frequency: .once, anchorDue: "2026-11-20",
                                autopay: false, paused: false, paidDues: [])
        #expect(once.nextUnpaidDue(today: "2026-11-25") == "2026-11-20") // overdue one-off still shows
        #expect(BillsDue.upcoming([once], today: "2026-11-25", days: 3).first?.line(today: "2026-11-25").contains("was due") == true)
    }

    @Test func dayOverview() throws {
        let s = try Fixture.parsed().snapshot
        let o = DayOverview.make(s, today: Fixture.today, privateBillIDs: ["b2"])
        #expect(o.events.map(\.title) == ["Team standup", "Dinner with Maya"])
        #expect(o.tasksToday.map(\.title) == ["Finish launch deck", "Water plants"])
        #expect(o.openTasksToday == 1)
        #expect(o.overdue.map(\.title) == ["Call the dentist"])
        #expect(o.doses.first?.status == "taken")
        #expect(o.priorities == ["Send the deck to Sam"])
        #expect(o.goalMention?.title == "Run a half marathon")
        // Car insurance due tomorrow is paid; streaming is private and named "a bill".
        let lines = o.bills.map { $0.line(today: Fixture.today) }
        #expect(lines.contains { $0.hasPrefix("Car insurance, due tomorrow") && $0.hasSuffix("paid") })
        #expect(lines.contains { $0.hasPrefix("a bill, due Friday") && $0.hasSuffix("autopay") })
        let text = o.contextText()
        for amount in ["1234", "123456", "60000", "1599", "15.99", "$"] { #expect(!text.contains(amount)) }
    }
}

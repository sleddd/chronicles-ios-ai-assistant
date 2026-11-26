import Foundation

/// Everything Smith may know for one conversation. This is the single place
/// that decides what is sent to Claude: no journal text, no money amounts.
public struct SmithContext: Sendable {
    public var name: String
    public var snapshot: ChroniclesSnapshot?
    public var journalDigest: String?
    public var aboutYou: String?
    public var recentConversations: [ConversationSummary]
    public var concerns: [Concern]
    public var freshnessNote: String?
    public var privateBillIDs: Set<String>
    public var includeGoalMention: Bool
    public var now: Date
    public var timeZone: TimeZone
    public var weatherLine: String?
    /// Connected to Chronicles: Smith can act there (log meals, doses…).
    public var canAct: Bool = false

    public init(name: String = "Smith", snapshot: ChroniclesSnapshot?, journalDigest: String?, aboutYou: String?,
                recentConversations: [ConversationSummary], concerns: [Concern], freshnessNote: String?,
                privateBillIDs: Set<String>, includeGoalMention: Bool = true, now: Date = Date(),
                timeZone: TimeZone = .current, weatherLine: String? = nil) {
        self.name = name; self.snapshot = snapshot; self.journalDigest = journalDigest; self.aboutYou = aboutYou
        self.recentConversations = recentConversations; self.concerns = concerns; self.freshnessNote = freshnessNote
        self.privateBillIDs = privateBillIDs; self.includeGoalMention = includeGoalMention; self.now = now
        self.timeZone = timeZone; self.weatherLine = weatherLine
    }

    public var today: String { Day.key(for: now, in: timeZone) }

    public var overview: DayOverview? {
        snapshot.map { DayOverview.make($0, today: today, privateBillIDs: privateBillIDs) }
    }

    /// System blocks, most stable first so the cache prefix holds: persona,
    /// then what Smith knows about them, then today's facts.
    public func systemBlocks(spoken: Bool) -> [SystemBlock] {
        stableBlocks(spoken: spoken) + [SystemBlock(dayText(), cache: true)]
    }

    /// The part that stays the same for a whole conversation: persona, and what Smith
    /// knows about them. A live chat sends exactly these every turn (the clock and the
    /// day's facts go in the messages instead), so the prefix stays cached and the
    /// model's earlier reasoning, which is tied to the system prompt, stays valid.
    public func stableBlocks(spoken: Bool) -> [SystemBlock] {
        var persona = PersonaPrompt.system(name: name, spoken: spoken)
        if canAct { persona += "\n\n" + ChroniclesActionTools.persona }
        persona += "\n\n" + ChatSafety.baseline
        var blocks = [SystemBlock(persona)]

        var memory: [String] = []
        if let aboutYou { memory.append(aboutYou) }
        if !recentConversations.isEmpty {
            memory.append("Recent conversations (summaries):\n" + recentConversations.suffix(6).map { "- \($0.day): \($0.text)" }.joined(separator: "\n"))
        }
        if !memory.isEmpty { blocks.append(SystemBlock(memory.joined(separator: "\n\n"))) }
        blocks[blocks.count - 1].cache = true
        return blocks
    }

    public func dayText() -> String {
        let f = DateFormatter()
        f.timeZone = timeZone
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "EEEE d MMMM yyyy, HH:mm"
        var parts = ["Now: \(f.string(from: now)) (\(timeZone.identifier))."]
        if let n = snapshot?.displayName { parts.append("Their name: \(n).") }
        if let weatherLine { parts.append("Weather (bring it up only if they ask, or in the morning briefing): \(weatherLine)") }
        if let snapshot, let o = overview {
            let ef = DateFormatter(); ef.timeZone = timeZone; ef.dateFormat = "EEEE d MMMM 'at' HH:mm"; ef.locale = Locale(identifier: "en_GB")
            parts.append("Chronicles data as of \(ef.string(from: snapshot.exportedAt)).")
            parts.append(o.contextText(includeGoal: includeGoalMention))
        } else {
            parts.append("No Chronicles data has been imported yet.")
        }
        if let journalDigest { parts.append(journalDigest) }
        if let freshnessNote { parts.append("Stale data note (mention once, at a natural moment, then drop it): \(freshnessNote)") }
        if !concerns.isEmpty {
            parts.append("Concerns you may raise (at most one, only at a natural moment; ask before advising):\n"
                         + concerns.map { "- \($0.note)" }.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n")
    }
}

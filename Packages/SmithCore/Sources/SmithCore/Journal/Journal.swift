import Foundation
import CryptoKit

/// Journal privacy (plan, section 8). Entry text is read only in memory during
/// an import, summarized on the device, then dropped. What's kept is a
/// `JournalRecord`; the only thing the AI ever sees is a `JournalDigest`.

public enum JournalTone: String, Codable, CaseIterable, Sendable { case light, steady, mixed, heavy }

public enum JournalTheme: String, Codable, CaseIterable, Sendable {
    case work, health, family, relationships, creativity, rest, money, growth
}

/// What Smith keeps per journal entry. No entry text.
public struct JournalRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var day: String
    public var topicIDs: [String]
    /// SHA-256 of the entry text: tells a later import whether the entry was edited. Can't be turned back into words.
    public var fingerprint: String
    public var tone: JournalTone?
    public var themes: [JournalTheme]
    /// One neutral line, made on the device. Stays on the device; never sent to the AI.
    public var summaryLine: String?

    public init(id: String, day: String, topicIDs: [String], fingerprint: String,
                tone: JournalTone? = nil, themes: [JournalTheme] = [], summaryLine: String? = nil) {
        self.id = id; self.day = day; self.topicIDs = topicIDs; self.fingerprint = fingerprint
        self.tone = tone; self.themes = themes; self.summaryLine = summaryLine
    }

    public static func fingerprint(of text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// The result of summarizing one entry on the device.
public struct JournalSummary: Equatable, Sendable {
    public var tone: JournalTone
    public var themes: [JournalTheme]
    public var line: String
    public init(tone: JournalTone, themes: [JournalTheme], line: String) {
        self.tone = tone; self.themes = themes; self.line = line
    }
}

/// On-device summarizer (Apple's Foundation Models in the app). Returns nil when unavailable.
public protocol JournalSummarizer: Sendable {
    func summarize(_ text: String) async -> JournalSummary?
}

public struct NoSummarizer: JournalSummarizer {
    public init() {}
    public func summarize(_ text: String) async -> JournalSummary? { nil }
}

/// An entry as read from the export, held only in memory during an import.
public struct TransientJournalEntry: Sendable {
    public var id: String
    public var day: String
    public var topicIDs: [String]
    public var text: String
    public init(id: String, day: String, topicIDs: [String], text: String) {
        self.id = id; self.day = day; self.topicIDs = topicIDs; self.text = text
    }
}

public enum JournalVaultBuilder {
    /// Turns this import's entries into records. Unchanged entries keep their
    /// existing record (no re-summarizing); entries with a "never mention" topic
    /// get no tone, themes or summary line.
    public static func records(for entries: [TransientJournalEntry], existing: [String: JournalRecord],
                               neverMention: Set<String>, summarizer: JournalSummarizer) async -> [JournalRecord] {
        var out: [JournalRecord] = []
        for e in entries {
            let fp = JournalRecord.fingerprint(of: e.text)
            let excluded = !neverMention.isDisjoint(with: e.topicIDs)
            if var old = existing[e.id], old.fingerprint == fp {
                old.day = e.day; old.topicIDs = e.topicIDs
                if excluded { old.tone = nil; old.themes = []; old.summaryLine = nil }
                out.append(old)
                continue
            }
            var r = JournalRecord(id: e.id, day: e.day, topicIDs: e.topicIDs, fingerprint: fp)
            if !excluded, !e.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let s = await summarizer.summarize(e.text) {
                r.tone = s.tone
                r.themes = Array(s.themes.prefix(3))
                r.summaryLine = s.line
            }
            out.append(r)
        }
        return out
    }
}

public enum JournalShareMode: String, Codable, CaseIterable, Sendable {
    case off, countsOnly, general

    public var label: String {
        switch self { case .off: "Off"; case .countsOnly: "Counts only"; case .general: "General summary" }
    }
}

/// The only journal information that may be sent to the AI. Fixed fields, no free text from entries.
public struct JournalDigest: Equatable, Sendable {
    public var entriesThisWeek: Int
    public var lastWritten: String?
    public var tone: JournalTone?
    public var themes: [JournalTheme]

    /// "4 entries this week, last one yesterday; overall tone: mixed; themes: work, rest."
    public func text(today: String, mode: JournalShareMode) -> String? {
        switch mode {
        case .off: return nil
        case .countsOnly, .general:
            var s = "Journal: \(entriesThisWeek) \(entriesThisWeek == 1 ? "entry" : "entries") in the last 7 days"
            if let lastWritten { s += ", last one \(Day.relative(lastWritten, today: today))" }
            guard mode == .general else { return s + "." }
            if let tone { s += "; overall tone: \(tone.rawValue)" }
            if !themes.isEmpty { s += "; themes: \(themes.map(\.rawValue).joined(separator: ", "))" }
            return s + "."
        }
    }

    /// Built from the vault. Entries with "never mention" topics don't count toward tone or themes.
    public static func make(from records: [JournalRecord], today: String, neverMention: Set<String>) -> JournalDigest {
        let start = Day.addDays(today, -6)
        let week = records.filter { $0.day >= start && $0.day <= today }
        let usable = week.filter { neverMention.isDisjoint(with: $0.topicIDs) }
        let tones = usable.compactMap(\.tone)
        var counts: [JournalTheme: Int] = [:]
        for t in usable.flatMap(\.themes) { counts[t, default: 0] += 1 }
        let themes = counts.sorted { ($0.value, $1.key.rawValue) > ($1.value, $0.key.rawValue) }.prefix(3).map(\.key)
        return JournalDigest(entriesThisWeek: week.count, lastWritten: records.map(\.day).filter { $0 <= today }.max(),
                             tone: overallTone(tones), themes: themes)
    }

    static func overallTone(_ tones: [JournalTone]) -> JournalTone? {
        guard !tones.isEmpty else { return nil }
        let heavy = tones.filter { $0 == .heavy }.count, light = tones.filter { $0 == .light }.count
        if heavy * 2 > tones.count { return .heavy }
        if light * 2 > tones.count { return .light }
        if heavy > 0 && light > 0 { return .mixed }
        return tones.contains(.mixed) ? .mixed : .steady
    }

    /// Weeks in a row (ending this week) with a heavy tone — for the concern check.
    public static func heavyWeeks(_ records: [JournalRecord], today: String, neverMention: Set<String>) -> Int {
        var n = 0
        var end = today
        while n < 8 {
            let d = make(from: records, today: end, neverMention: neverMention)
            guard d.tone == .heavy else { break }
            n += 1
            end = Day.addDays(end, -7)
        }
        return n
    }
}

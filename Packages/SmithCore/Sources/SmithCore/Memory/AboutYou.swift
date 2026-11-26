import Foundation

/// What Smith learns about the person (plan, section 11). Separate from
/// Chronicles data; never written back; editable and deletable by the person.
public struct Fact: Codable, Equatable, Sendable, Identifiable {
    public enum Category: String, Codable, CaseIterable, Sendable {
        case aboutYou, people, likes, dislikes, routines, style, updates, sensitive
        public var label: String {
            switch self {
            case .aboutYou: "About you"; case .people: "People"; case .likes: "Likes"; case .dislikes: "Dislikes"
            case .routines: "Routines"; case .style: "How you like Smith to be"; case .updates: "Life updates"
            case .sensitive: "Private"
            }
        }
    }
    public enum Source: String, Codable, Sendable { case saidInChat, noticed, addedByYou, editedByYou }

    public var id: UUID
    public var text: String
    public var category: Category
    public var source: Source
    public var confirmed: Bool
    public var createdAt: Date
    public var updatedAt: Date
    /// Unconfirmed facts that never come up again fade after 60 days.
    public var lastSeen: Date

    public init(id: UUID = UUID(), text: String, category: Category, source: Source, confirmed: Bool, at: Date = Date()) {
        self.id = id; self.text = text; self.category = category; self.source = source; self.confirmed = confirmed
        self.createdAt = at; self.updatedAt = at; self.lastSeen = at
    }

    public var sourceLabel: String {
        switch source {
        case .saidInChat: "Said in chat"; case .noticed: "Smith noticed"
        case .addedByYou: "Added by you"; case .editedByYou: "Edited by you"
        }
    }
}

/// A short marker for something deleted, so it isn't learned again. Not the fact itself.
public struct DontLearn: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var marker: String
    public var createdAt: Date
    public init(id: UUID = UUID(), marker: String, at: Date = Date()) { self.id = id; self.marker = marker; self.createdAt = at }
}

/// Deleted records are kept as small markers so a delete syncs and doesn't come back.
public struct Tombstone: Codable, Equatable, Sendable, Hashable {
    public var id: UUID
    public var deletedAt: Date
    public init(id: UUID, deletedAt: Date) { self.id = id; self.deletedAt = deletedAt }
}

public struct AboutYouStore: Codable, Equatable, Sendable {
    public var facts: [Fact] = []
    public var dontLearn: [DontLearn] = []
    public var tombstones: [Tombstone] = []
    public var paused = false
    public var shareWithHenry = false
    public init() {}

    public static let maxInContext = 40
    public static let fadeDays = 60.0

    // MARK: changes the person makes

    @discardableResult
    public mutating func remember(_ text: String, category: Fact.Category, at: Date = Date()) -> Fact {
        let f = Fact(text: text, category: category, source: .saidInChat, confirmed: true, at: at)
        facts.append(f)
        return f
    }

    public mutating func add(_ text: String, category: Fact.Category, at: Date = Date()) {
        facts.append(Fact(text: text, category: category, source: .addedByYou, confirmed: true, at: at))
    }

    /// An edit makes the fact confirmed and the person's wording the truth.
    public mutating func edit(_ id: UUID, text: String, category: Fact.Category? = nil, at: Date = Date()) {
        guard let i = facts.firstIndex(where: { $0.id == id }) else { return }
        facts[i].text = text
        if let category { facts[i].category = category }
        facts[i].source = .editedByYou
        facts[i].confirmed = true
        facts[i].updatedAt = at
    }

    public mutating func confirm(_ id: UUID, at: Date = Date()) {
        guard let i = facts.firstIndex(where: { $0.id == id }) else { return }
        facts[i].confirmed = true; facts[i].updatedAt = at
    }

    /// Deletes a fact and leaves a "don't learn this" marker. Returns the fact for Undo.
    @discardableResult
    public mutating func delete(_ id: UUID, marker: String? = nil, at: Date = Date()) -> Fact? {
        guard let i = facts.firstIndex(where: { $0.id == id }) else { return nil }
        let f = facts.remove(at: i)
        tombstones.append(Tombstone(id: id, deletedAt: at))
        dontLearn.append(DontLearn(marker: marker ?? Self.marker(for: f), at: at))
        return f
    }

    public mutating func undoDelete(_ fact: Fact, at: Date = Date()) {
        tombstones.removeAll { $0.id == fact.id }
        if let i = dontLearn.lastIndex(where: { $0.marker == Self.marker(for: fact) }) { dontLearn.remove(at: i) }
        var f = fact; f.updatedAt = at
        facts.append(f)
    }

    public mutating func clearAll(at: Date = Date()) {
        tombstones += facts.map { Tombstone(id: $0.id, deletedAt: at) }
        facts = []
    }

    /// A general label for a deleted fact: its category and first few words, e.g. "likes: coffee after".
    public static func marker(for f: Fact) -> String {
        let words = f.text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" })
            .filter { $0.count > 3 }.prefix(3)
        return "\(f.category.rawValue): \(words.joined(separator: " "))"
    }

    // MARK: learning

    /// Something Smith noticed in conversation and saved on his own (how an
    /// appointment went, news, a plan, a person, a like). Shown at once with
    /// Edit / Undo; unconfirmed, so a life update fades after 60 days unless kept.
    /// Returns nil when learning is paused, it's on the "don't learn" list, or already known.
    public mutating func note(_ text: String, category: Fact.Category, day: String? = nil, at: Date = Date()) -> Fact? {
        guard !paused else { return nil }
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        // A life update carries its date, so "today" still makes sense next month
        if category == .updates, let day, !t.hasPrefix(Day.short(day)) { t = "\(Day.short(day)): \(t)" }
        let candidate = Fact(text: t, category: category, source: .noticed, confirmed: false, at: at)
        if dontLearn.contains(where: { $0.marker == Self.marker(for: candidate) }) { return nil }
        if let i = facts.firstIndex(where: { $0.text.caseInsensitiveCompare(t) == .orderedSame }) {
            facts[i].lastSeen = at
            return nil
        }
        facts.append(candidate)
        return candidate
    }

    /// Adds facts suggested at the end of a conversation as unconfirmed, unless
    /// learning is paused, the fact is sensitive (only an explicit "remember"
    /// saves those), it matches a "don't learn" marker, or it's already known.
    public mutating func suggest(_ suggestions: [(text: String, category: Fact.Category)], at: Date = Date()) -> [Fact] {
        guard !paused else { return [] }
        var added: [Fact] = []
        for s in suggestions.prefix(3) {
            guard s.category != .sensitive else { continue }
            let candidate = Fact(text: s.text, category: s.category, source: .noticed, confirmed: false, at: at)
            if dontLearn.contains(where: { $0.marker == Self.marker(for: candidate) }) { continue }
            if let i = facts.firstIndex(where: { $0.text.caseInsensitiveCompare(s.text) == .orderedSame }) {
                facts[i].lastSeen = at
                continue
            }
            facts.append(candidate)
            added.append(candidate)
        }
        return added
    }

    /// Removes unconfirmed facts not seen for 60 days.
    public mutating func fade(now: Date = Date()) {
        facts.removeAll { !$0.confirmed && now.timeIntervalSince($0.lastSeen) > Self.fadeDays * 86_400 }
    }

    /// The "About you" block for Smith's context.
    public func contextText() -> String? {
        let use = facts.sorted { ($0.confirmed ? 0 : 1, $0.updatedAt) < ($1.confirmed ? 0 : 1, $1.updatedAt) }
            .prefix(Self.maxInContext)
        guard !use.isEmpty else { return nil }
        var lines = ["What you know about them (use it naturally; don't recite it back):"]
        for c in Fact.Category.allCases {
            let items = use.filter { $0.category == c }
            guard !items.isEmpty else { continue }
            lines.append("\(c.label):")
            lines += items.map { "- \($0.text)\($0.confirmed ? "" : " (tentative; you may check it lightly)")" }
        }
        let skip = dontLearn.map(\.marker)
        if !skip.isEmpty { lines.append("Don't learn or bring up again: " + skip.joined(separator: "; ")) }
        return lines.joined(separator: "\n")
    }
}

/// A conversation, kept as a summary only (plan, section 2).
public struct ConversationSummary: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var day: String
    public var text: String
    public var updatedAt: Date
    public init(id: UUID = UUID(), day: String, text: String, at: Date = Date()) {
        self.id = id; self.day = day; self.text = text; self.updatedAt = at
    }
}

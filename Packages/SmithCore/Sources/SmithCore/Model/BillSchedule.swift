import Foundation

/// A bill as Smith keeps it: the schedule only. No amounts, notes, categories
/// or payment details ever reach this type (plan, section 10).
public struct BillSchedule: Codable, Equatable, Sendable, Identifiable {
    public enum Frequency: String, Codable, Sendable { case weekly, biweekly, monthly, quarterly, yearly, once }

    public var id: String
    public var name: String
    public var isSubscription: Bool
    public var frequency: Frequency
    /// Any one due date; the schedule repeats from it.
    public var anchorDue: String
    public var autopay: Bool
    public var paused: Bool
    /// Due dates marked paid in Chronicles. Worked out at import (part payments
    /// count once they add up), then the amounts are dropped.
    public var paidDues: Set<String>

    public init(id: String, name: String, isSubscription: Bool, frequency: Frequency, anchorDue: String,
                autopay: Bool, paused: Bool, paidDues: Set<String>) {
        self.id = id; self.name = name; self.isSubscription = isSubscription; self.frequency = frequency
        self.anchorDue = anchorDue; self.autopay = autopay; self.paused = paused; self.paidDues = paidDues
    }

    private var monthStep: Int? { [.monthly: 1, .quarterly: 3, .yearly: 12][frequency] }
    private var dayStep: Int? { [.weekly: 7, .biweekly: 14][frequency] }

    func occurrence(_ n: Int) -> String {
        if let m = monthStep { return Day.addMonthsClamped(anchorDue, n * m) }
        if let d = dayStep { return Day.addDays(anchorDue, n * d) }
        return anchorDue
    }

    /// Every due date in [start, end], inclusive. Same rules as Chronicles' `billDueDates`.
    public func dueDates(from start: String, to end: String) -> [String] {
        if frequency == .once { return anchorDue >= start && anchorDue <= end ? [anchorDue] : [] }
        let stepDays = Double(dayStep ?? (monthStep ?? 1)) * (dayStep == nil ? 30.44 : 1)
        var n = Int(floor(Double(Day.daysBetween(anchorDue, start)) / stepDays)) - 1
        while occurrence(n) >= start { n -= 1 }
        var out: [String] = []
        var i = n + 1
        while true {
            let day = occurrence(i)
            if day > end { break }
            if day >= start { out.append(day) }
            if out.count > 400 { break }
            i += 1
        }
        return out
    }

    public func nextDue(from day: String) -> String? {
        if frequency == .once { return anchorDue >= day ? anchorDue : nil }
        return dueDates(from: day, to: Day.addMonthsClamped(day, 13)).first
    }

    /// The next due date not marked paid: after the last paid one, or (before any
    /// payment) the next one from a week ago, so a bill that just came due shows as overdue.
    public func nextUnpaidDue(today: String) -> String? {
        let last = paidDues.max()
        if frequency == .once { return last == nil ? anchorDue : nil }
        if let last { return nextDue(from: Day.addDays(last, 1)) }
        return nextDue(from: Day.addDays(today, -7))
    }
}

/// What the AI sees about one upcoming bill.
public struct BillDue: Equatable, Sendable {
    public var name: String
    public var due: String
    public var paid: Bool
    public var autopay: Bool

    /// "Rent, due Monday 1 Dec, not paid yet" — never an amount.
    public func line(today: String) -> String {
        let rel = Day.relative(due, today: today)
        let when = rel == Day.short(due) ? rel : "\(rel) (\(Day.short(due)))"
        let dueText = due < today ? "was due \(when)" : "due \(when)"
        let status = paid ? "paid" : (autopay ? "autopay" : "not marked paid yet")
        return "\(name), \(dueText), \(status)"
    }
}

public enum BillsDue {
    /// Bills due in the next `days` days, plus any unpaid ones already overdue.
    /// Bills marked private are named "a bill".
    public static func upcoming(_ bills: [BillSchedule], today: String, days: Int, privateIDs: Set<String> = []) -> [BillDue] {
        let end = Day.addDays(today, days)
        var out: [BillDue] = []
        for b in bills where !b.paused {
            let name = privateIDs.contains(b.id) ? "a bill" : b.name
            if let unpaid = b.nextUnpaidDue(today: today), unpaid < today {
                out.append(BillDue(name: name, due: unpaid, paid: false, autopay: b.autopay))
            }
            for d in b.dueDates(from: today, to: end) {
                out.append(BillDue(name: name, due: d, paid: b.paidDues.contains(d), autopay: b.autopay))
            }
        }
        return out.sorted { ($0.due, $0.name) < ($1.due, $1.name) }
    }
}

import Foundation
import Synchronization

/// Every Claude request passes through here (URLSessionTransport):
/// - it carries an anonymized user id (`metadata.user_id`), so a person who
///   misuses the AI can be told apart without suspending the whole API key;
/// - while AI is paused or turned off for this person, nothing is sent;
/// - a safety refusal (`stop_reason: "refusal"`) is reported once, so repeated
///   refusals warn, pause and finally turn AI off (the 5 / 10 / 20 ladder).
public final class AIGuard: Sendable {
    public static let shared = AIGuard()

    private struct State {
        var userID: String?
        var unavailable: String?
        var onRefusal: (@Sendable () -> Void)?
    }
    private let state = Mutex(State())

    public init() {}

    /// The anonymized id sent as `metadata.user_id`: from Chronicles when signed
    /// in (the same id Chronicles uses), else a random id made on this device.
    public var userID: String? {
        get { state.withLock { $0.userID } }
        set { state.withLock { $0.userID = newValue } }
    }

    /// Set while AI is paused or turned off; requests fail with this message instead of being sent.
    public var unavailable: String? {
        get { state.withLock { $0.unavailable } }
        set { state.withLock { $0.unavailable = newValue } }
    }

    public func setOnRefusal(_ f: (@Sendable () -> Void)?) { state.withLock { $0.onRefusal = f } }

    func reportRefusal() {
        let f = state.withLock { $0.onRefusal }
        f?()
    }
}

/// Where a person stands after safety refusals. Mirrors Chronicles' server
/// (GET /api/ai-chat → enforcement), which counts refusals from both apps.
public struct AIEnforcement: Codable, Equatable, Sendable {
    public enum Level: String, Codable, Sendable { case ok, warned, paused, blocked }
    public var level: Level
    public var pausedUntil: Date?
    public var refusals24h: Int
    public var refusals30d: Int

    public init(level: Level = .ok, pausedUntil: Date? = nil, refusals24h: Int = 0, refusals30d: Int = 0) {
        self.level = level; self.pausedUntil = pausedUntil; self.refusals24h = refusals24h; self.refusals30d = refusals30d
    }

    public static let warnAt = 5, pauseAt = 10, blockAt = 20

    /// What the person is told, or nil when everything is fine.
    public func message(now: Date = Date()) -> String? {
        switch level {
        case .ok: return nil
        case .warned:
            return "Some recent requests were declined by the AI. Repeated declined requests pause Smith’s AI for a day."
        case .paused:
            let until = pausedUntil.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "tomorrow"
            return "Smith’s AI is paused until \(until) after repeated declined requests."
        case .blocked:
            return "Smith’s AI is turned off for this account after repeated declined requests."
        }
    }

    /// True while nothing may be sent.
    public func stopsRequests(now: Date = Date()) -> Bool {
        level == .blocked || (level == .paused && (pausedUntil ?? .distantFuture) > now)
    }
}

/// The same ladder, kept on this device when Smith isn't signed in to Chronicles.
/// Only times are stored, never what was asked.
public struct LocalRefusalLog: Codable, Equatable, Sendable {
    public var times: [Date] = []
    public var pausedUntil: Date?
    public var blocked = false
    public init() {}

    public mutating func record(at now: Date = Date()) -> AIEnforcement {
        times.append(now)
        times.removeAll { now.timeIntervalSince($0) > 30 * 86_400 }
        let day = times.filter { now.timeIntervalSince($0) <= 86_400 }.count
        if times.count >= AIEnforcement.blockAt { blocked = true }
        else if day >= AIEnforcement.pauseAt { pausedUntil = now.addingTimeInterval(86_400) }
        return status(now: now)
    }

    public func status(now: Date = Date()) -> AIEnforcement {
        let day = times.filter { now.timeIntervalSince($0) <= 86_400 }.count
        let month = times.filter { now.timeIntervalSince($0) <= 30 * 86_400 }.count
        if blocked { return AIEnforcement(level: .blocked, refusals24h: day, refusals30d: month) }
        if let p = pausedUntil, p > now { return AIEnforcement(level: .paused, pausedUntil: p, refusals24h: day, refusals30d: month) }
        if day >= AIEnforcement.warnAt { return AIEnforcement(level: .warned, refusals24h: day, refusals30d: month) }
        return AIEnforcement(refusals24h: day, refusals30d: month)
    }
}

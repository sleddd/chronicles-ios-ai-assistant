import Foundation

/// The account's AI standing from Chronicles (GET /api/ai-chat): the 18+
/// confirmation, whether AI is turned off, the anonymized user id shared by
/// both apps, and where the refusal ladder stands. Shared across Chronicles
/// and Smith, so a pause or block in one applies in both.
public struct AIChatStatus: Equatable, Sendable {
    public var consentAt: Date?
    public var consentVersion: Int?
    public var blocked: Bool
    public var aiUserID: String?
    public var enforcement: AIEnforcement

    /// The safety notice and 18+ confirmation version both apps ask for.
    public static let consentVersion = 1

    public init(consentAt: Date? = nil, consentVersion: Int? = nil, blocked: Bool = false, aiUserID: String? = nil,
                enforcement: AIEnforcement = AIEnforcement()) {
        self.consentAt = consentAt; self.consentVersion = consentVersion; self.blocked = blocked
        self.aiUserID = aiUserID; self.enforcement = enforcement
    }

    public var hasConsent: Bool { !blocked && consentAt != nil && (consentVersion ?? 0) >= Self.consentVersion }

    static func date(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }

    public init(json v: JSONValue) {
        let e = v["enforcement"]
        var level = AIEnforcement.Level(rawValue: e?["level"]?.string ?? "ok") ?? .ok
        let blocked = v["blocked"]?.bool ?? false
        if blocked { level = .blocked }
        self.init(consentAt: Self.date(v["consentAt"]?.string), consentVersion: v["consentVersion"]?.int, blocked: blocked,
                  aiUserID: v["aiUserId"]?.string,
                  enforcement: AIEnforcement(level: level, pausedUntil: Self.date(e?["pausedUntil"]?.string),
                                             refusals24h: e?["refusals24h"]?.int ?? 0, refusals30d: e?["refusals30d"]?.int ?? 0))
    }
}

extension ChroniclesClient {
    public func aiStatus(_ s: ChroniclesSession) async throws -> AIChatStatus {
        AIChatStatus(json: try await call("GET", "/api/ai-chat", nil, s).body)
    }

    /// Confirms 18+ and that the safety notice was read.
    public func confirmAIConsent(_ s: ChroniclesSession) async throws -> AIChatStatus {
        let body: JSONValue = ["version": .number(Double(AIChatStatus.consentVersion)), "ageConfirmed": true]
        return AIChatStatus(json: try await call("POST", "/api/ai-chat/consent", body, s).body)
    }

    /// One safety refusal (no content is sent), counted against the shared ladder.
    public func reportAIRefusal(_ s: ChroniclesSession) async throws -> AIChatStatus {
        AIChatStatus(json: try await call("POST", "/api/ai-chat/refusal", ["app": "smith"], s).body)
    }
}

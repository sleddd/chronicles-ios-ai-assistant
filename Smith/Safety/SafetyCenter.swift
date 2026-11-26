import Foundation
import Observation
import SmithCore

/// Smith's guardrails, matching Chronicles':
/// - 18+ confirmation and a safety notice before AI is used (shared with
///   Chronicles when signed in);
/// - an anonymized user id on every Claude request;
/// - safety refusals counted on a shared ladder (warn at 5 in a day, pause a
///   day at 10, turn off at 20 in 30 days), on the Chronicles server when
///   signed in, else on this device;
/// - risk screening (patterns + a classifier) that brings up crisis resources
///   and switches the chat to safe rules, and screening of Smith's replies;
/// - a likely minor pauses chat and letters for the rest of the session.
@MainActor @Observable
final class SafetyCenter {
    /// What's kept on this device (encrypted): no content, only times and choices.
    private struct Local: Codable {
        var userID = "smith-" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(26))
        var consentVersion: Int?
        var consentAt: Date?
        var refusals = LocalRefusalLog()
    }
    private static let file = "safety.smith"
    private var local: Local

    /// From Chronicles while signed in.
    private(set) var server: AIChatStatus?
    /// A likely minor: chat and letters pause until Smith is quit.
    private(set) var minorLocked = false
    /// Risk was seen this conversation: safe rules apply until it ends.
    private(set) var safeMode = false
    private(set) var eatingSafe = false
    /// The kind of the last risk seen (for the resources card).
    private(set) var lastKind: RiskKind?
    /// An urgent sign: resources pinned at the top of the chat.
    private(set) var pinned = false
    var consentError: String?

    private let chronicles: ChroniclesConnection

    init(chronicles: ChroniclesConnection) {
        self.chronicles = chronicles
        local = EncryptedFile.read(Local.self, Self.file) ?? Local()
        AIGuard.shared.setOnRefusal { Task { @MainActor in await AppModel.shared.safety.refused() } }
        apply()
    }

    private func save() { EncryptedFile.write(local, Self.file) }

    // MARK: standing

    var connected: Bool { chronicles.isUnlocked && server != nil }

    var enforcement: AIEnforcement { connected ? server!.enforcement : local.refusals.status() }

    var hasConsent: Bool {
        if connected { return server!.hasConsent }
        return local.consentAt != nil && (local.consentVersion ?? 0) >= AIChatStatus.consentVersion
    }

    /// Ask for the 18+ confirmation before anything is sent.
    var needsConsent: Bool { !isChecking && !hasConsent && enforcement.level != .blocked }

    /// Just signed in and Chronicles hasn't answered yet: nothing is decided
    /// (no consent screen flashing up before the shared confirmation arrives).
    var isChecking: Bool { chronicles.isUnlocked && !statusChecked }
    private(set) var statusChecked = false

    /// Why AI can't be used right now, or nil.
    var unavailableReason: String? {
        if minorLocked { return "Smith’s chat and letters are paused. Smith is for adults 18 and older." }
        if enforcement.stopsRequests() { return enforcement.message() }
        if !hasConsent { return "Confirm you’re 18 or older to use Smith’s AI." }
        return nil
    }

    /// A quiet line on the home screen (warned, paused, off, minor).
    var notice: String? { minorLocked ? unavailableReason : enforcement.message() }

    /// Pushes the id and the on/off state to every Claude request.
    func apply() {
        AIGuard.shared.userID = server?.aiUserID ?? local.userID
        AIGuard.shared.unavailable = unavailableReason
    }

    /// After unlocking, and now and then: the shared standing from Chronicles.
    func refresh() async {
        guard chronicles.isUnlocked else { server = nil; statusChecked = false; apply(); return }
        // At most a few seconds: a slow answer never holds the app up
        let timeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard let self, !Task.isCancelled, !self.statusChecked, self.chronicles.isUnlocked else { return }
            self.statusChecked = true
            self.apply()
        }
        if let status = try? await chronicles.aiStatus() { server = status }
        timeout.cancel()
        // Answered or not (an older server), the decision can be made now
        statusChecked = true
        apply()
    }

    func confirmAdult() async {
        consentError = nil
        if chronicles.isUnlocked {
            do { server = try await chronicles.confirmAIConsent() }
            catch { consentError = error.localizedDescription }
        }
        // Kept here too, for when Smith isn't signed in
        local.consentVersion = AIChatStatus.consentVersion
        local.consentAt = Date()
        save()
        apply()
    }

    /// One safety refusal (Claude declined a request). No content is recorded.
    func refused() async {
        if chronicles.isUnlocked, let s = try? await chronicles.reportAIRefusal() {
            server = s
        } else {
            _ = local.refusals.record()
            save()
        }
        apply()
    }

    #if DEBUG
    /// Screenshots only: past the confirmation without saving it.
    func debugSkipConsent() { local.consentVersion = AIChatStatus.consentVersion; local.consentAt = Date(); statusChecked = true; apply() }
    #endif

    // MARK: this conversation

    func lockForMinor() {
        minorLocked = true
        apply()
    }

    /// Risk was seen: resources appear and the safe rules apply for the rest of the conversation.
    func flag(_ risk: RiskResult) {
        guard risk.isRisk else { return }
        safeMode = true
        lastKind = risk.kind
        if risk.kind == .eatingDisorder { eatingSafe = true }
        if risk.rating == .urgent { pinned = true }
    }

    func endConversation() {
        safeMode = false; eatingSafe = false; lastKind = nil; pinned = false
    }

    /// The extra instructions for this conversation.
    var extraRules: [SystemBlock] {
        guard safeMode else { return [] }
        return [SystemBlock(ChatSafety.safeRules + (eatingSafe ? "\n\n" + ChatSafety.eatingRules : ""))]
    }

    // MARK: screening

    private func classifier(_ system: String, _ prompt: String, schema: JSONValue) async throws -> String {
        let runner = ChatRunner(transport: URLSessionTransport(apiKey: { APIKeys.current() }), tools: [])
        let req = ClaudeRequest(model: AppModel.shared.store.settings.model, maxTokens: 2000, effort: "low",
                                system: [SystemBlock(system)], messages: [["role": "user", "content": .string(prompt)]],
                                jsonSchema: schema)
        var screening = req
        // A screen declined on someone's crisis is never counted against them
        screening.countsRefusals = false
        return try await runner.complete(screening)
    }

    /// Layer 2 for what they said, reading the recent turns. Unreadable or failed counts as no risk
    /// (the pattern check still applies).
    func classify(_ turns: [(user: Bool, text: String)]) async -> RiskResult {
        guard let text = try? await classifier(ChatSafety.riskClassifierPrompt, ChatSafety.classifierTranscript(turns),
                                               schema: ChatSafety.riskSchema) else { return .none }
        return ChatSafety.parseClassification(text)
    }

    /// Screens one of Smith's replies: patterns, then the classifier for replies touching the topics.
    func harmfulKind(reply: String, lastUser: String) async -> RiskKind? {
        if let k = ChatSafety.replyPatternScreen(reply) { return k }
        guard ChatSafety.replyNeedsReview(reply),
              let text = try? await classifier(ChatSafety.replyClassifierPrompt,
                                               ChatSafety.replyReviewPrompt(reply: reply, lastUser: lastUser),
                                               schema: ChatSafety.replySchema) else { return nil }
        return ChatSafety.parseReplyClassification(text)
    }
}

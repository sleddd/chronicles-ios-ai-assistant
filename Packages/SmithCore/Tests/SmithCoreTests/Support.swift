import Foundation
@testable import SmithCore

enum Fixture {
    static var exportData: Data {
        let url = Bundle.module.url(forResource: "export", withExtension: "json", subdirectory: "Fixtures")!
        return try! Data(contentsOf: url)
    }

    static let today = "2026-11-25"
    static let now: Date = ISO8601DateFormatter().date(from: "2026-11-25T14:00:00Z")!
    static let tz = TimeZone(identifier: "America/New_York")!

    /// Every marker planted in private parts of the export (journal, notes, finance, wellness, saved chats…).
    static let canaries = [
        "CANARY-JOURNAL-TITLE-Q7", "CANARY-JOURNAL-BODY-3KD", "CANARY-JOURNAL-NOTOPIC-W2", "CANARY-THERAPY-9ZP",
        "CANARY-USERFIELD-4TT", "CANARY-WELLNESS-6RR", "CANARY-SAVEDCHAT-1AA", "CANARY-TASKNOTE-55X",
        "CANARY-MEETINGNOTE-81B", "CANARY-AINOTES-0OP", "CANARY-BUDGETCAT-7HH", "CANARY-BILLNOTE-5MM",
        "CANARY-EXPENSE-8JJ", "CANARY-SAVINGS-3CC", "CANARY-MEAL-2PL", "123456", "1234.56", "98765", "60000", "4321",
    ]

    /// Phrases from the journal entries (any 4 words in a row would be a leak).
    static let journalPhrases = [
        "meeting with the landlord went badly", "the landlord went badly", "untopiced private thought",
        "secret plans for the weekend", "Session today about",
    ]

    static func parsed() throws -> ExportParser.Result {
        try ExportParser.parse(exportData, now: now)
    }
}

/// Records every request that would be sent to Anthropic and replies with scripted events.
final class RecordingTransport: ClaudeTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _bodies: [String] = []
    private var replies: [[SSEEvent]]

    init(replies: [[SSEEvent]]) { self.replies = replies }

    var bodies: [String] { lock.withLock { _bodies } }

    func stream(_ request: ClaudeRequest) -> AsyncThrowingStream<SSEEvent, Error> {
        let body = request.body.jsonText
        let events: [SSEEvent] = lock.withLock {
            _bodies.append(body)
            return replies.isEmpty ? SSE.textReply("Okay.") : replies.removeFirst()
        }
        return AsyncThrowingStream { c in
            for e in events { c.yield(e) }
            c.finish()
        }
    }
}

enum SSE {
    static func ev(_ json: JSONValue) -> SSEEvent { SSEEvent(event: json["type"]?.string ?? "", data: json.jsonText) }

    static func textReply(_ text: String, chunks: Int = 3) -> [SSEEvent] {
        var out = [ev(["type": "message_start", "message": ["model": "claude-opus-5-5"]]),
                   ev(["type": "content_block_start", "index": 0, "content_block": ["type": "thinking", "thinking": ""]]),
                   ev(["type": "content_block_delta", "index": 0, "delta": ["type": "signature_delta", "signature": "sig"]]),
                   ev(["type": "content_block_stop", "index": 0]),
                   ev(["type": "content_block_start", "index": 1, "content_block": ["type": "text", "text": ""]])]
        let size = max(1, text.count / chunks)
        var rest = Substring(text)
        while !rest.isEmpty {
            let piece = rest.prefix(size); rest = rest.dropFirst(piece.count)
            out.append(ev(["type": "content_block_delta", "index": 1, "delta": ["type": "text_delta", "text": .string(String(piece))]]))
        }
        out += [ev(["type": "content_block_stop", "index": 1]),
                ev(["type": "message_delta", "delta": ["stop_reason": "end_turn"]]),
                ev(["type": "message_stop"])]
        return out
    }

    static func toolCall(id: String, name: String, input: String) -> [SSEEvent] {
        [ev(["type": "message_start", "message": ["model": "claude-opus-5-5"]]),
         ev(["type": "content_block_start", "index": 0, "content_block": ["type": "tool_use", "id": .string(id), "name": .string(name), "input": [:]]]),
         ev(["type": "content_block_delta", "index": 0, "delta": ["type": "input_json_delta", "partial_json": .string(input)]]),
         ev(["type": "content_block_stop", "index": 0]),
         ev(["type": "message_delta", "delta": ["stop_reason": "tool_use"]]),
         ev(["type": "message_stop"])]
    }
}

import Foundation

// Claude over raw HTTPS (Swift has no official Anthropic SDK). Request shapes
// follow the Messages API: POST /v1/messages, anthropic-version 2026-10-21,
// streamed as server-sent events.

public enum ClaudeModel: String, CaseIterable, Codable, Sendable {
    case opus = "claude-opus-5-5"
    case sonnet = "claude-sonnet-5-5"

    public var label: String { self == .opus ? "Claude Opus 5.5" : "Claude Sonnet 5.5" }
}

public struct SystemBlock: Sendable, Equatable {
    public var text: String
    /// Put a cache breakpoint after this block.
    public var cache: Bool
    public init(_ text: String, cache: Bool = false) { self.text = text; self.cache = cache }
}

public struct ClaudeRequest: Sendable {
    public var model: ClaudeModel
    public var maxTokens: Int
    public var effort: String
    public var system: [SystemBlock]
    public var messages: [JSONValue]
    public var tools: [JSONValue]
    /// A JSON schema the reply must follow (structured outputs).
    public var jsonSchema: JSONValue?

    public init(model: ClaudeModel, maxTokens: Int = 16000, effort: String = "low",
                system: [SystemBlock], messages: [JSONValue], tools: [JSONValue] = [], jsonSchema: JSONValue? = nil) {
        self.model = model; self.maxTokens = maxTokens; self.effort = effort
        self.system = system; self.messages = messages; self.tools = tools; self.jsonSchema = jsonSchema
    }

    public var body: JSONValue {
        var o: [String: JSONValue] = [
            "model": .string(model.rawValue),
            "max_tokens": .number(Double(maxTokens)),
            "stream": true,
            // Thinking can't be turned off on these models; effort sets its depth.
            "thinking": ["type": "adaptive"],
            "output_config": jsonSchema.map { ["effort": .string(effort), "format": ["type": "json_schema", "schema": $0]] }
                ?? ["effort": .string(effort)],
            "system": .array(system.map { b in
                var block: [String: JSONValue] = ["type": "text", "text": .string(b.text)]
                if b.cache { block["cache_control"] = ["type": "ephemeral"] }
                return .object(block)
            }),
            "messages": .array(messages),
            // If a safety classifier declines, the API retries on a fallback model in the same call.
            "fallbacks": "default",
        ]
        if !tools.isEmpty { o["tools"] = .array(tools) }
        return .object(o)
    }
}

/// One server-sent event.
public struct SSEEvent: Sendable, Equatable {
    public var event: String
    public var data: String
    public init(event: String, data: String) { self.event = event; self.data = data }
}

/// Sends a request and yields its events. The real one talks to Anthropic;
/// tests use a recording mock to check exactly what would leave the device.
public protocol ClaudeTransport: Sendable {
    func stream(_ request: ClaudeRequest) -> AsyncThrowingStream<SSEEvent, Error>
}

public enum ClaudeError: LocalizedError, Equatable {
    case missingKey
    case http(status: Int, message: String)
    case api(String)
    case refused
    case malformed

    public var errorDescription: String? {
        switch self {
        case .missingKey: return "Add your Anthropic API key in Settings."
        case .http(let status, let message): return "Claude returned \(status): \(message)"
        case .api(let m): return m
        case .refused: return "Claude declined that request."
        case .malformed: return "Claude sent a reply I couldn't read."
        }
    }
}

public struct URLSessionTransport: ClaudeTransport {
    let apiKey: @Sendable () -> String?
    let session: URLSession

    public init(session: URLSession = .shared, apiKey: @escaping @Sendable () -> String?) {
        self.session = session; self.apiKey = apiKey
    }

    public func stream(_ request: ClaudeRequest) -> AsyncThrowingStream<SSEEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let key = apiKey(), !key.isEmpty else { throw ClaudeError.missingKey }
                    var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
                    req.httpMethod = "POST"
                    req.timeoutInterval = 600
                    req.setValue("application/json", forHTTPHeaderField: "content-type")
                    req.setValue(key, forHTTPHeaderField: "x-api-key")
                    req.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
                    req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
                    req.httpBody = try request.body.encoded()

                    let (bytes, response) = try await session.bytes(for: req)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    if status != 200 {
                        var text = ""
                        for try await line in bytes.lines { text += line }
                        let message = (try? JSONValue.parse(Data(text.utf8)))?["error"]?["message"]?.string ?? text
                        throw ClaudeError.http(status: status, message: message)
                    }
                    var event = "message", data = ""
                    for try await line in bytes.lines {
                        if line.hasPrefix("event:") {
                            event = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                        } else if line.hasPrefix("data:") {
                            data += line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                            // The API sends one data line per event; yield right away.
                            continuation.yield(SSEEvent(event: event, data: data))
                            event = "message"; data = ""
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Builds the final content blocks from the stream, and reports text as it arrives.
public struct StreamAccumulator {
    public private(set) var blocks: [Int: JSONValue] = [:]
    private var partialJSON: [Int: String] = [:]
    /// Tool calls whose input arrived truncated or invalid; answered with an error, never run.
    public private(set) var invalidToolIDs: Set<String> = []
    public private(set) var stopReason: String?
    public private(set) var model: String?

    public init() {}

    public enum Output: Equatable { case text(String), blockStarted(type: String, name: String?), none }

    public mutating func consume(_ e: SSEEvent) throws -> Output {
        guard let json = try? JSONValue.parse(Data(e.data.utf8)) else { return .none }
        switch json["type"]?.string {
        case "message_start":
            model = json["message"]?["model"]?.string
        case "content_block_start":
            guard let i = json["index"]?.int, let block = json["content_block"] else { return .none }
            blocks[i] = block
            return .blockStarted(type: block["type"]?.string ?? "", name: block["name"]?.string)
        case "content_block_delta":
            guard let i = json["index"]?.int, let d = json["delta"], var block = blocks[i]?.object else { return .none }
            switch d["type"]?.string {
            case "text_delta":
                let t = d["text"]?.string ?? ""
                block["text"] = .string((block["text"]?.string ?? "") + t)
                blocks[i] = .object(block)
                return .text(t)
            case "thinking_delta":
                block["thinking"] = .string((block["thinking"]?.string ?? "") + (d["thinking"]?.string ?? ""))
            case "signature_delta":
                block["signature"] = .string((block["signature"]?.string ?? "") + (d["signature"]?.string ?? ""))
            case "input_json_delta":
                partialJSON[i, default: ""] += d["partial_json"]?.string ?? ""
            case "citations_delta":
                var list = block["citations"]?.array ?? []
                if let c = d["citation"] { list.append(c) }
                block["citations"] = .array(list)
            default: break
            }
            blocks[i] = .object(block)
        case "content_block_stop":
            guard let i = json["index"]?.int, var block = blocks[i]?.object else { return .none }
            if let raw = partialJSON[i] {
                // A truncated or invalid tool input is treated as invalid, never run.
                if raw.isEmpty {
                    block["input"] = .object([:])
                } else if let parsed = try? JSONValue.parse(Data(raw.utf8)), parsed.object != nil {
                    block["input"] = parsed
                } else {
                    block["input"] = .object([:])
                    if let id = block["id"]?.string { invalidToolIDs.insert(id) }
                }
                blocks[i] = .object(block)
                partialJSON[i] = nil
            }
        case "message_delta":
            if let r = json["delta"]?["stop_reason"]?.string { stopReason = r }
        case "error":
            throw ClaudeError.api(json["error"]?["message"]?.string ?? "Claude reported an error.")
        default: break
        }
        return .none
    }

    public var content: [JSONValue] { blocks.keys.sorted().compactMap { blocks[$0] } }

    public var text: String {
        content.filter { $0["type"]?.string == "text" }.compactMap { $0["text"]?.string }.joined()
    }

    /// Content to send back as the assistant turn. After a mid-output fallback,
    /// model-internal blocks before the last `fallback` block are left out
    /// (the `fallback` block itself stays where it was).
    public var contentForEcho: [JSONValue] {
        let all = content
        guard let boundary = all.lastIndex(where: { $0["type"]?.string == "fallback" }) else { return all }
        let resultIDs = Set(all.compactMap { $0["tool_use_id"]?.string })
        return all.enumerated().compactMap { (i, b) in
            guard i < boundary else { return b }
            switch b["type"]?.string {
            case "text", "fallback": return b
            case "server_tool_use": return resultIDs.contains(b["id"]?.string ?? "") ? b : nil
            case let t? where t.hasSuffix("_tool_result"): return b
            default: return nil
            }
        }
    }
}

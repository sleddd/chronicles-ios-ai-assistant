import Foundation
import SmithCore

/// ElevenLabs voices (optional, your own key). What Smith says aloud — and a
/// Henry letter when you press Hear it — is sent to ElevenLabs to become
/// speech. Nothing else is. The key is sealed to this device (Keychain enum).
nonisolated enum ElevenLabs {
    struct Voice: Identifiable, Hashable, Sendable {
        let id: String
        let name: String
        let category: String
        let detail: String
    }

    enum Model: String, CaseIterable, Codable, Sendable {
        case v4Turbo = "eleven_v4_turbo"
        case v4 = "eleven_v4"
        case flash = "eleven_flash_v2_5"
        case multilingual = "eleven_multilingual_v2"

        var label: String {
            switch self {
            case .v4Turbo: "Eleven v4 Turbo (fast, natural)"
            case .v4: "Eleven v4 (most expressive, slower)"
            case .flash: "Flash v2.5 (fastest)"
            case .multilingual: "Multilingual v2 (steady, long-form)"
            }
        }
    }

    static let base = URL(string: "https://api.elevenlabs.io")!

    static var apiKey: String? {
        get { Keychain.data("elevenlabs-api-key").flatMap { String(data: $0, encoding: .utf8) } }
        set { Keychain.set(newValue.flatMap { $0.isEmpty ? nil : Data($0.utf8) }, for: "elevenlabs-api-key") }
    }

    enum Failure: LocalizedError {
        case noKey, http(Int, String)
        var errorDescription: String? {
            switch self {
            case .noKey: "Add your ElevenLabs key in Settings."
            case .http(let s, let m): s == 401 ? "ElevenLabs didn’t accept that key." : "ElevenLabs answered \(s): \(m)"
            }
        }
    }

    /// Every voice on the account (premade, cloned, designed), a page at a time.
    static func voices(key: String) async throws -> [Voice] {
        var out: [Voice] = []
        var token: String?
        repeat {
            var c = URLComponents(url: base.appendingPathComponent("/v2/voices"), resolvingAgainstBaseURL: false)!
            c.queryItems = [.init(name: "page_size", value: "100"), .init(name: "sort", value: "name")]
                + (token.map { [.init(name: "next_page_token", value: $0)] } ?? [])
            var req = URLRequest(url: c.url!)
            req.setValue(key, forHTTPHeaderField: "xi-api-key")
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let json = (try? JSONValue.parse(data)) ?? .null
            guard status == 200 else { throw Failure.http(status, json["detail"]?["message"]?.string ?? json["detail"]?.string ?? "") }
            for v in json["voices"]?.array ?? [] {
                guard let id = v["voice_id"]?.string, let name = v["name"]?.string else { continue }
                let labels = (v["labels"]?.object ?? [:]).values.compactMap(\.string).prefix(3).joined(separator: ", ")
                out.append(Voice(id: id, name: name, category: v["category"]?.string ?? "", detail: labels))
            }
            token = json["has_more"]?.bool == true ? json["next_page_token"]?.string : nil
        } while token != nil
        return out
    }

    /// One piece of speech as MP3. `previous` is what was just said, so the
    /// voice carries on in the same tone instead of starting fresh.
    static func speech(_ text: String, voice: String, model: Model, previous: String?, key: String) async throws -> Data {
        var c = URLComponents(url: base.appendingPathComponent("/v1/text-to-speech/\(voice)"), resolvingAgainstBaseURL: false)!
        c.queryItems = [.init(name: "output_format", value: "mp3_44100_128")]
        var req = URLRequest(url: c.url!)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue(key, forHTTPHeaderField: "xi-api-key")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue("audio/mpeg", forHTTPHeaderField: "accept")
        var body: [String: JSONValue] = ["text": .string(text), "model_id": .string(model.rawValue)]
        if let previous, !previous.isEmpty { body["previous_text"] = .string(String(previous.suffix(600))) }
        req.httpBody = try JSONValue.object(body).encoded(sortedKeys: false)
        var attempt = 0
        while true {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            // 429 = busy (too many at once, or a moment's rate limit): wait and try again, a few times
            if status == 429, attempt < 3 {
                attempt += 1
                let after = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "retry-after").flatMap(Double.init) ?? Double(attempt) * 1.5
                try await Task.sleep(for: .seconds(min(after, 6)))
                continue
            }
            return try check(data, status)
        }
    }

    private static func check(_ data: Data, _ status: Int) throws -> Data {
        guard status == 200, !data.isEmpty else {
            let json = (try? JSONValue.parse(data)) ?? .null
            throw Failure.http(status, json["detail"]?["message"]?.string ?? json["detail"]?.string ?? "")
        }
        return data
    }
}

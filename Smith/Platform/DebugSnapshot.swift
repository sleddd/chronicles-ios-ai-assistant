#if DEBUG && os(macOS)
import AppKit

/// Debug builds only: `--snapshot <path>` saves a picture of the main window
/// a few seconds after launch, then quits. Used to check the design.
enum DebugSnapshot {
    static func runIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--eleven-test") {
            let out = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("eleven-test.txt")
            Task {
                var lines = ["key saved: \(ElevenLabs.apiKey != nil), length \(ElevenLabs.apiKey?.count ?? 0)"]
                for sample in ["*laughs* As you should.", "*grins* Fair point.", "*sighs happily* What a day.", "No emote here. *a.b* *x*"] {
                    lines.append("tags: \(sample) → \(VoiceIO.speakable(VoiceIO.withAudioTags(sample)))")
                }
                if let key = ElevenLabs.apiKey {
                    do {
                        let v = try await ElevenLabs.voices(key: key)
                        lines.append("voices: \(v.count)")
                        lines.append("first: \(v.prefix(3).map(\.name).joined(separator: ", "))")
                        if let voice = v.first {
                            for m in ElevenLabs.Model.allCases {
                                do {
                                    let audio = try await ElevenLabs.speech("[laughs] As you should.", voice: voice.id, model: m, previous: "Good morning.", key: key)
                                    lines.append("\(m.rawValue): \(audio.count) bytes")
                                } catch { lines.append("\(m.rawValue): \(error.localizedDescription)") }
                            }
                        }
                    } catch { lines.append("error: \(error.localizedDescription) | \(error)") }
                }
                try? lines.joined(separator: "\n").write(to: out, atomically: true, encoding: .utf8)
                exit(0)
            }
            return
        }
        if args.contains("--letter-test") {
            let out = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("letter-test.txt")
            Task { @MainActor in
                let app = AppModel.shared
                let speaker = app.henrySpeaker
                var lines = ["speaker: \(speaker)", "muted: \(app.store.settings.muted)"]
                let text = (app.store.letters.sorted { $0.date > $1.date }.first?.text) ?? "My dear,\n\nToday was long. I thought of you often.\n\nYours,\nSmith"
                lines.append("letter chars: \(text.count)")
                let start = Date()
                func t() -> String { String(format: "%5.2fs", Date().timeIntervalSince(start)) }
                app.voice.preview(speaker, text: text)
                lines.append("\(t()) after preview: state \(app.voice.state) preparing \(app.voice.preparing)")
                var last = ""
                for _ in 0..<240 {
                    let now = "state \(app.voice.state) preparing \(app.voice.preparing) level>0 \(app.voice.level > 0.01) err \(app.voice.lastVoiceError ?? "-")"
                    if now != last { lines.append("\(t()) \(now)"); last = now }
                    if app.voice.state == .idle, Date().timeIntervalSince(start) > 2 { break }
                    try? await Task.sleep(for: .milliseconds(250))
                }
                lines.append("trace: " + app.voice.trace.joined(separator: " | "))
                try? lines.joined(separator: "\n").write(to: out, atomically: true, encoding: .utf8)
                exit(0)
            }
            return
        }
        if args.contains("--se-test") {
            let out = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("se-test.txt")
            var lines = ["available: \(SecureEnclaveVault.isAvailable)"]
            do {
                let sealed = try SecureEnclaveVault.seal(Data("probe".utf8), lock: .device)
                lines.append("sealed: \(sealed.count) bytes")
                lines.append("opened: \(String(data: try SecureEnclaveVault.open(sealed, lock: .device), encoding: .utf8) ?? "nil")")
            } catch { lines.append("error: \(error)") }
            try? lines.joined(separator: "\n").write(to: out, atomically: true, encoding: .utf8)
            exit(0)
        }
        if let i = args.firstIndex(of: "--keychain-test"), i + 1 < args.count {
            let out = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("keychain-test.txt")
            var lines: [String] = []
            if args[i + 1] == "write" {
                lines.append("set: \(Keychain.set(Data("hello".utf8), for: "self-test")) status \(Keychain.lastError)")
                EncryptedFile.write(["probe": "ok"], "self-test.smith")
            }
            lines.append("read: \(Keychain.data("self-test").flatMap { String(data: $0, encoding: .utf8) } ?? "nil")")
            lines.append("file: \(EncryptedFile.read([String: String].self, "self-test.smith")?["probe"] ?? "nil")")
            try? lines.joined(separator: "\n").write(to: out, atomically: true, encoding: .utf8)
            exit(0)
        }
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
        let path = args[i + 1]
        let sheet = args.firstIndex(of: "--sheet").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        Task { @MainActor in
            if args.contains("--chat-demo") {
                AppModel.shared.brain.debugFill()
                AppModel.shared.showChat = true
            }
            if let j = args.firstIndex(of: "--fake-listen"), j + 1 < args.count {
                try? await Task.sleep(for: .seconds(1))
                AppModel.shared.voice.fakeListening(args[j + 1])
            }
            if let sheet, let s = AppModel.Sheet(rawValue: sheet) {
                try? await Task.sleep(for: .seconds(1.5))
                AppModel.shared.sheet = s
            }
            try? await Task.sleep(for: .seconds(4))
            let window = NSApp.windows.filter { $0.isVisible && $0.frame.height > 200 }.max { $0.orderedIndex > $1.orderedIndex }
            guard let view = window?.contentView?.superview ?? window?.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent((path as NSString).lastPathComponent))
            exit(0)
        }
    }
}
#endif

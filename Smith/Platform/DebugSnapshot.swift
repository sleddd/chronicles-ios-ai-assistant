#if DEBUG && os(macOS)
import AppKit
import SmithCore

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
        if args.contains("--set-stats-hidden") {
            Task { @MainActor in
                AppModel.shared.store.updateLocalSettings { $0.statsHidden = true }
                try? await Task.sleep(for: .seconds(1))
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
        if args.contains("--data-test") {
            let out = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("data-test.txt")
            Task { @MainActor in
                let app = AppModel.shared
                var lines: [String] = []
                if let s = app.store.snapshot {
                    lines.append("exportedAt \(s.exportedAt)")
                    lines.append("tasks \(s.tasks.count) open \(s.tasks.filter(\.isOpen).count) scheduled \(s.tasks.filter { $0.scheduledDate != nil }.count)")
                    lines.append("goals \(s.goals.count) statuses \(Set(s.goals.map(\.status)))")
                    let o = app.brain.context().overview
                    lines.append("today \(o?.today ?? "-") tasksToday \(o?.tasksToday.count ?? -1) open \(o?.openTasksToday ?? -1) overdue \(o?.overdue.count ?? -1) deadlines \(o?.deadlinesSoon.count ?? -1) events \(o?.events.count ?? -1)")
                    lines.append("sample dates: \(s.tasks.prefix(8).map { "\($0.scheduledDate ?? "nil")/\($0.deadline ?? "nil")/\($0.status.rawValue)" })")
                } else { lines.append("no snapshot") }
                lines.append("chronicles state: \(app.chronicles.state) email saved: \(app.store.settings.chroniclesEmail != nil) quickUnlock: \(app.store.settings.quickUnlock)")
                await app.weather.refresh(fahrenheit: app.store.settings.fahrenheit, force: true)
                lines.append("weather: \(app.weather.report.map { "\($0.chip) \($0.description)" } ?? "nil") problem: \(app.weather.problem ?? "-") place: \(app.weather.placeName ?? "-") source: \(app.store.settings.weatherSource)")
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
            if args.contains("--home-demo") || args.contains("--page") || args.contains("--resources-demo") {
                AppModel.shared.chronicles.debugShowAsUnlocked()
            }
            if args.contains("--home-demo") { AppModel.shared.safety.debugSkipConsent() }
            // Screenshots only: the stats shown or hidden, put back to what you had afterwards
            let statsBefore = AppModel.shared.store.settings.statsHidden
            if args.contains("--stats-hidden") { AppModel.shared.store.updateLocalSettings { $0.statsHidden = true } }
            if args.contains("--stats-shown") { AppModel.shared.store.updateLocalSettings { $0.statsHidden = false } }
            if let j = args.firstIndex(of: "--page"), j + 1 < args.count {
                AppModel.shared.safety.debugSkipConsent()
                switch args[j + 1] {
                case "letters": AppModel.shared.page = .letters
                case "box": AppModel.shared.page = .letters; AppModel.shared.lettersBoxOpen = true
                case "goals": AppModel.shared.page = .goals
                case "me": AppModel.shared.page = .me
                case "today": AppModel.shared.page = .today
                default: AppModel.shared.page = .settings
                }
            }
            if args.contains("--resources-demo") {
                AppModel.shared.safety.debugSkipConsent()
                if !args.contains("--no-fill") { AppModel.shared.brain.debugFill() }
                AppModel.shared.brain.showResources(RiskResult(rating: .elevated, kind: .suicide))
                AppModel.shared.showChat = true
            }
            if args.contains("--chat-demo") {
                AppModel.shared.chronicles.debugShowAsUnlocked()
                AppModel.shared.safety.debugSkipConsent()
                AppModel.shared.brain.debugFill()
                AppModel.shared.showChat = true
            }
            if args.contains("--connect") {
                try? await Task.sleep(for: .seconds(1))
                var log: [String] = []
                func w() -> String { NSApp.windows.filter { $0.className.contains("AppKitWindow") }.map { "visible \($0.isVisible) key \($0.isKeyWindow) mini \($0.isMiniaturized) hidden \(NSApp.isHidden) active \(NSApp.isActive)" }.joined(separator: ", ") }
NSApp.windows.first { $0.className.contains("AppKitWindow") }?.makeKeyAndOrderFront(nil)
                NSApp.activate()
                try? await Task.sleep(for: .milliseconds(500))
                log.append("before: \(w())")
                AppModel.shared.chronicles.beginSetup()
                for i in 0..<24 { try? await Task.sleep(for: .milliseconds(500)); log.append("\(i): state \(AppModel.shared.chronicles.state) \(w())") }
                try? log.joined(separator: "\n").write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("connect-log.txt"), atomically: true, encoding: .utf8)
            }
            if args.contains("--no-name") {
                try? await Task.sleep(for: .seconds(1))
                AppModel.shared.brain.debugSetHeadline("It's late. Anything on your mind?")
            }
            if let j = args.firstIndex(of: "--fake-listen"), j + 1 < args.count {
                try? await Task.sleep(for: .seconds(1))
                AppModel.shared.voice.fakeListening(args[j + 1])
            }
            if let sheet, let s = AppModel.Sheet(rawValue: sheet) {
                try? await Task.sleep(for: .seconds(1.5))
                AppModel.shared.sheet = s
            }
            try? await Task.sleep(for: .seconds(args.contains("--slow") ? 9 : 4))
            let window = NSApp.windows.filter { $0.isVisible && $0.frame.height > 200 }.max { $0.orderedIndex > $1.orderedIndex }
            guard let view = window?.contentView?.superview ?? window?.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                let info = NSApp.windows.map { "\($0.className) visible \($0.isVisible) \($0.frame)" }.joined(separator: "\n")
                try? info.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("snapshot-fail.txt"), atomically: true, encoding: .utf8)
                exit(1)
            }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent((path as NSString).lastPathComponent))
            if AppModel.shared.store.settings.statsHidden != statsBefore {
                AppModel.shared.store.updateLocalSettings { $0.statsHidden = statsBefore }
            }
            exit(0)
        }
    }
}
#endif

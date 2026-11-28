import SwiftUI
import SmithCore

/// Smith is locked: your Chronicles password unlocks it (and your code, with 2FA).
/// Nothing that opens your journal is kept while locked.
struct LockView: View {
    @Environment(AppModel.self) private var app
    @State private var email = ""
    @State private var password = ""
    @State private var code = ""
    @FocusState private var focus: Field?
    enum Field { case email, password, code }
    var compact = false

    var body: some View {
        let c = app.chronicles
        ZStack {
            GlowBackground()
            VStack(spacing: 22) {
                Spacer()
                OrbView(mode: c.state == .unlocking ? .thinking : .idle, level: 0, size: compact ? 64 : 84)
                Text(app.store.settings.chroniclesEmail == nil ? "Connect to Chronicles" : "Unlock \(app.store.settings.name)")
                    .font(Theme.rounded(compact ? 24 : 30)).foregroundStyle(Theme.text)
                Text(c.state == .needsCode ? "Enter the code from your authenticator app."
                     : "Sign in with your Chronicles password. Your key stays only in memory while \(app.store.settings.name) is open.")
                    .font(Theme.rounded(14)).foregroundStyle(Theme.dim).multilineTextAlignment(.center).padding(.horizontal, 30)

                VStack(spacing: 12) {
                    if c.state == .needsCode {
                        field { TextField("", text: $code, prompt: Text("123456").foregroundStyle(Theme.faint))
                            .textContentType(.oneTimeCode).focused($focus, equals: .code).onSubmit(submitCode) }
                        HStack(spacing: 16) {
                            Button("Back") { c.cancelCode() }.buttonStyle(.plain).foregroundStyle(Theme.dim)
                            Button("Unlock", action: submitCode).buttonStyle(.plain).foregroundStyle(Theme.violet)
                        }.font(Theme.rounded(15, .medium))
                    } else {
                        field { TextField("", text: $email, prompt: Text("Email").foregroundStyle(Theme.faint))
                            .textContentType(.username).focused($focus, equals: .email)
                            #if os(iOS)
                            .textInputAutocapitalization(.never).keyboardType(.emailAddress)
                            #endif
                        }
                        field { SecureField("", text: $password, prompt: Text("Chronicles password").foregroundStyle(Theme.faint))
                            .textContentType(.password).focused($focus, equals: .password).onSubmit(submit) }
                        if app.store.settings.quickUnlock && ChroniclesConnection.hasQuickUnlock {
                            Button { Task { await c.quickUnlock() } } label: {
                                Label("Unlock with \(ChroniclesConnection.biometryName)", systemImage: "touchid")
                                    .font(Theme.rounded(15, .medium)).foregroundStyle(Theme.violet)
                            }.buttonStyle(.plain).disabled(c.state == .unlocking)
                        }
                        Button(action: submit) {
                            HStack { if c.state == .unlocking { ProgressView().controlSize(.small) }; Text("Unlock") }
                                .font(Theme.rounded(16, .medium)).padding(.horizontal, 30).padding(.vertical, 11)
                                .background(LinearGradient(colors: [Theme.violet, Theme.magenta.opacity(0.8)], startPoint: .leading, endPoint: .trailing), in: Capsule())
                        }
                        .buttonStyle(.plain).disabled(c.state == .unlocking || email.isEmpty || password.isEmpty)
                    }
                    if let e = c.lastError { Text(e).font(Theme.rounded(13)).foregroundStyle(Theme.rose).multilineTextAlignment(.center) }
                }
                .frame(maxWidth: 340)

                if app.store.settings.chroniclesEmail == nil {
                    Text("Smith works with your Chronicles account. First switch on the Chronicles AI app in Chronicles: Settings → In-App AI.")
                        .font(Theme.rounded(12)).foregroundStyle(Theme.faint).multilineTextAlignment(.center).padding(.horizontal, 30)
                }
                Spacer()
            }
            .padding(24)
        }
        .environment(\.colorScheme, .dark)
        .onAppear {
            email = app.store.settings.chroniclesEmail ?? ""
            focus = email.isEmpty ? .email : .password
            // Offer Face ID / Touch ID straight away when it's set up
            if app.store.settings.quickUnlock && ChroniclesConnection.hasQuickUnlock && c.state == .locked {
                Task { await c.quickUnlock() }
            }
        }
        .onChange(of: c.state) { _, s in
            if s == .needsCode { focus = .code }
            if s == .unlocked { password = ""; code = "" }
        }
    }

    private func field<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .textFieldStyle(.plain).font(Theme.rounded(16)).foregroundStyle(Theme.soft)
            .padding(.horizontal, 18).padding(.vertical, 12)
            .background(Color.black.opacity(0.6), in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.08)))
    }

    private func submit() {
        let e = email.trimmingCharacters(in: .whitespaces), p = password
        guard !e.isEmpty, !p.isEmpty else { return }
        Task { await app.chronicles.unlock(email: e, password: p) }
    }

    private func submitCode() {
        let c = code.trimmingCharacters(in: .whitespaces)
        guard !c.isEmpty else { return }
        Task { await app.chronicles.submitCode(c) }
    }
}

/// "Logged oatmeal for breakfast · Undo" — for two minutes after Smith acts in Chronicles.
struct UndoChips: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { tl in
            VStack(alignment: .leading, spacing: 10) {
                ForEach(app.chronicles.undoables.filter { $0.expires > tl.date }) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: "checkmark.circle").foregroundStyle(Theme.teal)
                        Text(item.summary).font(Theme.rounded(13, .regular)).foregroundStyle(Theme.soft)
                            .lineSpacing(5).fixedSize(horizontal: false, vertical: true)
                        Button("Undo") { Task { await app.chronicles.undo(item) } }
                            .buttonStyle(.plain).font(Theme.rounded(12, .medium)).foregroundStyle(Theme.violet)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 11)
                    .background(ChatPill.fill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(ChatPill.edge))
                }
            }
            .onChange(of: tl.date) { _, now in app.chronicles.dropExpiredUndos(now: now) }
        }
    }
}

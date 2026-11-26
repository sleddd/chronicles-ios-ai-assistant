import SwiftUI
import SmithCore

/// Crisis resources, the same lines Chronicles shows (CrisisCard.tsx): one-tap
/// call, text and chat. Eating-disorder risk puts that helpline first; an
/// urgent sign puts 911 first.
struct ResourcesCard: View {
    var kind: RiskKind?
    var urgent = false
    /// One line, for the top of the chat once it goes on.
    var compact = false

    private struct Line: Identifiable {
        let id: String; let name: String; let detail: String; let actions: [(label: String, url: String)]
    }

    private static let emergency = Line(id: "emergency", name: "In danger right now", detail: "",
                                        actions: [("Call 911", "tel:911")])
    private static let lifeline = Line(id: "lifeline", name: "988 Suicide & Crisis Lifeline", detail: "Free, 24 hours a day",
                                       actions: [("Call 988", "tel:988"), ("Text 988", "sms:988"), ("Chat online", "https://988lifeline.org/chat/")])
    private static let textLine = Line(id: "text", name: "Crisis Text Line", detail: "Free, 24 hours a day",
                                       actions: [("Text HOME to 741741", "sms:741741&body=HOME")])
    private static let eating = Line(id: "eating", name: "National Alliance for Eating Disorders", detail: "Mon–Fri, 9 a.m.–7 p.m. Eastern",
                                     actions: [("Call 866-662-1235", "tel:18666621235")])
    private static let abroad = Line(id: "abroad", name: "Outside the US", detail: "Free helplines by country",
                                     actions: [("findahelpline.com", "https://findahelpline.com")])

    private var lines: [Line] {
        var l = kind == .eatingDisorder ? [Self.eating, Self.lifeline, Self.textLine] : [Self.lifeline, Self.textLine, Self.eating]
        if urgent { l.insert(Self.emergency, at: 0) }
        return l + [Self.abroad]
    }

    var body: some View {
        if compact {
            HStack(spacing: 10) {
                Image(systemName: "heart.text.square").foregroundStyle(Theme.rose)
                Text("Help is one tap away:").foregroundStyle(Theme.dim)
                if urgent { Link("911", destination: URL(string: "tel:911")!) }
                Link("Call or text 988", destination: URL(string: "tel:988")!)
                if kind == .eatingDisorder { Link("866-662-1235", destination: URL(string: "tel:18666621235")!) }
            }
            .font(Theme.rounded(12, .medium)).tint(Theme.rose)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Color.black.opacity(0.55), in: Capsule())
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Text(urgent ? "Please reach out now" : "You don’t have to go through this alone")
                    .font(Theme.rounded(16, .semibold)).foregroundStyle(Theme.text)
                Text("Free, confidential support, any time. Smith is an AI and can’t call anyone for you.")
                    .font(Theme.rounded(13)).foregroundStyle(Theme.dim)
                ForEach(lines) { line in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            Text(line.name).font(Theme.rounded(14, .semibold)).foregroundStyle(Theme.text)
                            if !line.detail.isEmpty { Text(line.detail).font(Theme.rounded(12)).foregroundStyle(Theme.faint) }
                        }
                        HStack(spacing: 8) {
                            ForEach(line.actions, id: \.label) { a in
                                Link(destination: URL(string: a.url)!) {
                                    Text(a.label).font(Theme.rounded(13, .medium)).foregroundStyle(Theme.text)
                                        .padding(.horizontal, 12).padding(.vertical, 6)
                                        .overlay(Capsule().stroke(Theme.rose.opacity(0.6)))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: 560, alignment: .leading)
            .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(alignment: .leading) {
                if urgent { RoundedRectangle(cornerRadius: 2).fill(Theme.rose).frame(width: 3).padding(.vertical, 12) }
            }
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(.white.opacity(0.08)))
        }
    }
}

/// Before Smith's AI is used: 18 or older, and what Smith does when someone is struggling.
struct ConsentView: View {
    @Environment(AppModel.self) private var app
    @State private var working = false

    var body: some View {
        ZStack {
            GlowBackground()
            VStack(alignment: .leading, spacing: 16) {
                Caps("Before we start", size: 12, color: Theme.text)
                Text("Smith is for adults").font(Theme.rounded(26)).foregroundStyle(Theme.text)
                VStack(alignment: .leading, spacing: 10) {
                    bullet("Smith is an AI, not a person, a therapist or a crisis service. It can’t call anyone for you.")
                    bullet("If you mention suicide, self-harm or an eating disorder, Smith shows free helplines and won’t give harmful details. In an emergency, call 911; for support any time, call or text 988.")
                    bullet("Requests the AI declines are counted, with nothing of what you said kept. Many in a short time pause Smith’s AI for a day, and repeated pauses turn it off. This follows Anthropic’s usage policies.")
                    bullet("With Chronicles connected, this confirmation and the count are shared with Chronicles’ In-App AI.")
                }
                if let e = app.safety.consentError { Text(e).font(Theme.rounded(12)).foregroundStyle(Theme.rose) }
                Button {
                    working = true
                    Task { await app.safety.confirmAdult(); working = false }
                } label: {
                    HStack { if working { ProgressView().controlSize(.small) }; Text("I’m 18 or older") }
                        .font(Theme.rounded(16, .medium)).padding(.horizontal, 28).padding(.vertical, 11)
                        .background(LinearGradient(colors: [Theme.violet, Theme.magenta.opacity(0.8)], startPoint: .leading, endPoint: .trailing), in: Capsule())
                }
                .buttonStyle(.plain).disabled(working).padding(.top, 6)
            }
            .frame(maxWidth: 520, alignment: .leading)
            .padding(32)
        }
        .environment(\.colorScheme, .dark)
        .foregroundStyle(Theme.text)
    }

    private func bullet(_ t: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle().fill(Theme.violet).frame(width: 5, height: 5)
            Text(t).font(Theme.rounded(14)).foregroundStyle(Theme.soft).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
        }
    }
}

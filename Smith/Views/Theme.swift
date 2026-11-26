import SwiftUI

/// Dark, glowing and calm: near-black with slow violet / indigo glows.
enum Theme {
    static let ink = Color(red: 0.03, green: 0.03, blue: 0.06)
    static let text = Color.white.opacity(0.92)
    static let dim = Color.white.opacity(0.55)
    /// Chat text: softened white, easier on the eyes than full white.
    static let soft = Color.white.opacity(0.78)
    static let faint = Color.white.opacity(0.3)
    static let violet = Color(red: 0.49, green: 0.33, blue: 0.98)
    static let magenta = Color(red: 0.86, green: 0.30, blue: 0.85)
    static let blue = Color(red: 0.26, green: 0.45, blue: 1.0)
    static let teal = Color(red: 0.20, green: 0.78, blue: 0.70)
    static let rose = Color(red: 0.95, green: 0.55, blue: 0.62)
    static let amber = Color(red: 0.98, green: 0.72, blue: 0.38)

    static func rounded(_ size: CGFloat, _ weight: Font.Weight = .light) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

/// Tiny tracked caps for labels.
struct Caps: View {
    let text: String
    var size: CGFloat = 10
    var color: Color = Theme.dim
    init(_ text: String, size: CGFloat = 10, color: Color = Theme.dim) { self.text = text; self.size = size; self.color = color }
    var body: some View {
        Text(text.uppercased()).font(.system(size: size, weight: .medium, design: .rounded)).tracking(2).foregroundStyle(color)
    }
}

/// Near-black with soft colour glows that drift slowly behind everything.
struct GlowBackground: View {
    var warm = false
    var mood = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            let a = Float(sin(t / 7) * 0.12), b = Float(cos(t / 9) * 0.12), c = Float(sin(t / 11) * 0.1)
            // Teal on the left, magenta on the right, violet above
            let glow1 = warm ? Theme.rose : Theme.violet
            let glow2 = warm ? Theme.amber : Theme.teal
            MeshGradient(width: 3, height: 3, points: [
                [0, 0], [0.5 + a, 0], [1, 0],
                [0, 0.5 + b], [0.5 + c, 0.45 + a], [1, 0.5 - b],
                [0, 1], [0.5 - c, 1], [1, 1],
            ], colors: [
                Theme.ink, glow1.opacity(0.35), Theme.ink,
                glow2.opacity(warm ? 0.22 : 0.2), Theme.ink, (warm ? Theme.rose : Theme.magenta).opacity(warm ? 0.18 : 0.26),
                Theme.ink, glow1.opacity(0.28), Theme.ink,
            ])
            .overlay(Theme.ink.opacity(0.35))
        }
        .ignoresSafeArea()
    }
}

struct GlassChip: View {
    let value: String
    let label: String
    var tint: Color? = nil
    var body: some View {
        VStack(spacing: 4) {
            Text(value).font(Theme.rounded(17, .regular)).foregroundStyle(tint ?? Theme.text).lineLimit(1).minimumScaleFactor(0.7)
            Caps(label, size: 8.5, color: tint?.opacity(0.85) ?? Theme.dim)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(minWidth: 78)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.white.opacity(0.08)))
        .environment(\.colorScheme, .dark)
    }
}

/// Set when a screen is shown as a page in the main window (under the tabs);
/// its close button goes back to Today instead of dismissing a sheet.
private struct PageCloseKey: EnvironmentKey { static let defaultValue: (@MainActor () -> Void)? = nil }
extension EnvironmentValues {
    var pageClose: (@MainActor () -> Void)? {
        get { self[PageCloseKey.self] }
        set { self[PageCloseKey.self] = newValue }
    }
}

/// A titled screen: Today, Goals, Me and Settings. In the main window it's a
/// full-width page under the tabs; presented on its own (an editor) it's a glass sheet.
struct GlassSheet<Content: View>: View {
    let title: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.pageClose) private var pageClose
    @ViewBuilder var content: Content

    var body: some View {
        if let pageClose {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    Text(title.uppercased()).font(Theme.rounded(13, .semibold)).tracking(2.4).foregroundStyle(Theme.text)
                    Spacer()
                    Button { pageClose() } label: {
                        Image(systemName: "xmark").font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.soft)
                            .frame(width: 44, height: 44).overlay(Circle().stroke(.white.opacity(0.13)))
                    }
                    .buttonStyle(.plain).help("Back to Today")
                }
                ScrollView { VStack(alignment: .leading, spacing: 16) { content }.padding(.bottom, 32).frame(maxWidth: .infinity, alignment: .leading) }
                    .scrollIndicators(.hidden)
            }
            .foregroundStyle(Theme.text)
        } else {
            ZStack {
                GlowBackground()
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Caps(title, size: 12, color: Theme.text)
                        Spacer()
                        Button { dismiss() } label: {
                            Image(systemName: "xmark").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.dim)
                                .padding(10).background(.ultraThinMaterial, in: Circle())
                        }.buttonStyle(.plain)
                    }
                    .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 12)
                    ScrollView { VStack(alignment: .leading, spacing: 16) { content }.padding(.horizontal, 24).padding(.bottom, 32).frame(maxWidth: .infinity, alignment: .leading) }
                }
            }
            .environment(\.colorScheme, .dark)
            .foregroundStyle(Theme.text)
            #if os(macOS)
            .frame(minWidth: 460, minHeight: 560)
            #endif
        }
    }
}

struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Caps(text, size: 11).padding(.top, 34).padding(.bottom, 4) }
}

struct GlassCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 18) { content }
            .padding(.horizontal, 26).padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .smithCard(radius: 20)
    }
}

/// A chat bubble with the little point at its bottom corner: on the right for
/// your messages, on the left for Smith's.
struct ChatBubble: Shape {
    var tailOnRight: Bool
    var radius: CGFloat = 18
    static let tail: CGFloat = 7

    func path(in r: CGRect) -> Path {
        let t = Self.tail
        let body = CGRect(x: tailOnRight ? r.minX : r.minX + t, y: r.minY, width: r.width - t, height: r.height)
        let rounded = Path(roundedRect: body, cornerRadius: min(radius, body.height / 2), style: .continuous)
        var point = Path()
        if tailOnRight {
            point.move(to: CGPoint(x: body.maxX - 14, y: body.maxY - 12))
            point.addQuadCurve(to: CGPoint(x: r.maxX, y: r.maxY), control: CGPoint(x: body.maxX - 1, y: body.maxY - 3))
            point.addQuadCurve(to: CGPoint(x: body.maxX - 20, y: body.maxY), control: CGPoint(x: body.maxX - 6, y: r.maxY + 0.5))
        } else {
            point.move(to: CGPoint(x: body.minX + 14, y: body.maxY - 12))
            point.addQuadCurve(to: CGPoint(x: r.minX, y: r.maxY), control: CGPoint(x: body.minX + 1, y: body.maxY - 3))
            point.addQuadCurve(to: CGPoint(x: body.minX + 20, y: body.maxY), control: CGPoint(x: body.minX + 6, y: r.maxY + 0.5))
        }
        point.closeSubpath()
        return Path(rounded.cgPath.union(point.cgPath))
    }
}

/// Text with emotes (*laughs*, *grins*) shown softly in italics, without the asterisks.
func emoteText(_ s: String, emote: Color) -> Text {
    var out = Text("")
    var rest = Substring(s)
    while let r = rest.range(of: #"\*[^*\n]{1,40}\*"#, options: .regularExpression) {
        out = out + Text(rest[..<r.lowerBound])
        let inner = rest[r].dropFirst().dropLast()
        out = out + Text(inner).italic().foregroundStyle(emote)
        rest = rest[r.upperBound...]
    }
    return out + Text(rest)
}

extension View {
    /// The glass card used on the home and letters pages: faint fill, hairline edge.
    func smithCard(radius: CGFloat = 24) -> some View {
        self
            .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .background(.ultraThinMaterial.opacity(0.5), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(.white.opacity(0.09)))
    }
}

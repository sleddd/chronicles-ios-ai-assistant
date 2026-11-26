import SwiftUI

/// The talk button.
/// - Idle: a teal-to-pink ring around a dark centre with a microphone, breathing gently.
/// - Listening and speaking: a filled orb with voice bars that move with the sound, inside soft rings.
/// - Thinking: the ring turns.
struct OrbView: View {
    enum Mode { case idle, listening, thinking, speaking }
    var mode: Mode
    var level: Float
    var size: CGFloat = 112
    var warm = false

    private var colors: [Color] {
        warm ? [Theme.rose, Theme.amber, Theme.magenta, Theme.rose]
             : [Theme.teal, Theme.blue, Theme.violet, Theme.magenta, Theme.teal]
    }

    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            let active = mode == .listening || mode == .speaking
            let breathe = 1 + 0.025 * sin(t * 1.6)
            let spin = Angle.degrees(mode == .thinking ? t * 120 : 200)

            ZStack {
                // Glow behind
                Circle()
                    .fill(RadialGradient(colors: [Theme.violet.opacity(active ? 0.5 : 0.32), .clear],
                                         center: .center, startRadius: 4, endRadius: size * 0.95))
                    .frame(width: size * 1.9, height: size * 1.9)
                    .blur(radius: 26)

                if active {
                    // Rings around the orb, the inner ones a little brighter
                    ForEach(0..<3) { i in
                        let pulse = 1 + CGFloat(level) * 0.05 * CGFloat(3 - i)
                        Circle().stroke(Theme.teal.opacity(0.32 - Double(i) * 0.08), lineWidth: 1.2)
                            .frame(width: size * (1.28 + CGFloat(i) * 0.33) * pulse, height: size * (1.28 + CGFloat(i) * 0.33) * pulse)
                    }
                    // The filled orb
                    Circle()
                        .fill(LinearGradient(colors: [Theme.teal, Theme.blue, Theme.violet, Theme.magenta],
                                             startPoint: .leading, endPoint: .trailing))
                        .overlay(Circle().fill(RadialGradient(colors: [.white.opacity(0.28), .clear], center: .center,
                                                              startRadius: 0, endRadius: size * 0.5)))
                        .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 1).padding(size * 0.06))
                        .frame(width: size, height: size)
                        .shadow(color: Theme.violet.opacity(0.6), radius: 24)
                        .scaleEffect(1 + CGFloat(level) * 0.04)
                    // Voice bars
                    HStack(spacing: size * 0.04) {
                        ForEach(0..<7) { i in
                            let shape = [0.22, 0.42, 0.7, 1.0, 0.7, 0.42, 0.22][i]
                            let wobble = 0.75 + 0.25 * sin(t * 7 + Double(i) * 1.3)
                            let h = size * 0.42 * shape * (0.45 + 0.55 * Double(level > 0.02 ? Double(level) * 1.4 : 0.35) * wobble)
                            Capsule().fill(Theme.ink.opacity(0.85))
                                .frame(width: size * 0.035, height: max(size * 0.06, min(size * 0.42, h)))
                        }
                    }
                } else {
                    // Outer hairline ring
                    Circle().stroke(Theme.teal.opacity(0.3), lineWidth: 1.2)
                        .frame(width: size * 1.26, height: size * 1.26)
                    // Dark centre
                    Circle()
                        .fill(RadialGradient(colors: [Theme.violet.opacity(0.35), Theme.ink.opacity(0.9)],
                                             center: UnitPoint(x: 0.55, y: 0.4), startRadius: 2, endRadius: size * 0.6))
                        .frame(width: size, height: size)
                    // The gradient ring
                    Circle()
                        .stroke(AngularGradient(colors: colors, center: .center, angle: spin), lineWidth: size * 0.065)
                        .frame(width: size * 0.95, height: size * 0.95)
                        .shadow(color: Theme.magenta.opacity(0.5), radius: 10)
                    Image(systemName: "mic").font(.system(size: size * 0.2, weight: .light)).foregroundStyle(Theme.teal)
                        .opacity(mode == .thinking ? 0.4 : 1)
                }
            }
            .scaleEffect(mode == .idle ? breathe : 1)
        }
        .frame(width: size * 1.95, height: size * 1.95)
        .contentShape(Circle())
        .accessibilityLabel(mode == .listening ? "Listening" : mode == .speaking ? "Speaking" : "Talk to Smith")
    }
}

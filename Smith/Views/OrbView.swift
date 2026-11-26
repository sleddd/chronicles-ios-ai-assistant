import SwiftUI

/// A glowing ring: breathes while idle, ripples with your voice while
/// listening, and swirls while Smith speaks.
struct OrbView: View {
    enum Mode { case idle, listening, thinking, speaking }
    var mode: Mode
    var level: Float
    var size: CGFloat = 112
    var warm = false

    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            let breathe = 1 + 0.04 * sin(t * 1.6)
            let ripple = 1 + CGFloat(level) * 0.22
            let scale: CGFloat = switch mode {
            case .idle: breathe
            case .listening: ripple
            case .thinking: 1 + 0.03 * sin(t * 5)
            case .speaking: 1 + CGFloat(level) * 0.1 + 0.02 * sin(t * 8)
            }
            let spin = Angle.degrees(t * (mode == .speaking ? 140 : mode == .thinking ? 90 : 18))
            let colors: [Color] = warm
                ? [Theme.rose, Theme.amber, Theme.magenta, Theme.rose]
                : [Theme.violet, Theme.magenta, Theme.blue, Theme.violet]

            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [colors[0].opacity(0.45), .clear], center: .center, startRadius: 4, endRadius: size * 0.9))
                    .frame(width: size * 1.9, height: size * 1.9)
                    .blur(radius: 24)
                    .opacity(mode == .idle ? 0.6 : 0.95)
                Circle()
                    .stroke(AngularGradient(colors: colors, center: .center, angle: spin), lineWidth: size * 0.075)
                    .frame(width: size, height: size)
                    .blur(radius: 1.5)
                Circle()
                    .stroke(AngularGradient(colors: colors, center: .center, angle: spin), lineWidth: size * 0.2)
                    .frame(width: size, height: size)
                    .blur(radius: 18)
                    .opacity(0.8)
                if mode == .listening {
                    ForEach(0..<3) { i in
                        let phase = (t * 0.9 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                        Circle().stroke(colors[1].opacity(0.35 * (1 - phase)), lineWidth: 1.2)
                            .frame(width: size * (1 + phase * 0.7), height: size * (1 + phase * 0.7))
                    }
                }
            }
            .scaleEffect(scale)
        }
        .frame(width: size * 1.9, height: size * 1.9)
        .accessibilityLabel(mode == .listening ? "Listening" : mode == .speaking ? "Speaking" : "Talk to Smith")
    }
}

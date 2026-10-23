//
//  AgentMascot.swift
//  Openchamber
//
//  The agents' pixel mascots, drawn after the ones Droppy ships for its own
//  Agents droplet (ExtensionMedia/ai-mascot-*.svg), with the same geometry
//  and timings, so a session in the notch moves the way it does in Agents.
//  The SVGs animate with SMIL, which nothing in SwiftUI plays, so each one is
//  redrawn here as a few shapes on a clock.
//

import DroppyKit
import SwiftUI

struct AgentMascot: View {
    enum Kind: String {
        case claude, codex, cursor, opencode, antigravity

        init?(provider: String) {
            guard let key = ProviderStyle.key(provider) else { return nil }
            self.init(rawValue: key)
        }
    }

    let kind: Kind
    var size: CGFloat = DroppyLiveActivityMetrics.iconSize
    /// False while nobody can see it, or while the session waits on you:
    /// the clock stops and the mascot holds its first frame.
    var isAnimating = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if isAnimating && !reduceMotion {
                // Discrete steps, as ChamberGlyph: the mascot runs in Droppy's process.
                TimelineView(.periodic(from: .now, by: 1.0 / 12.0)) { timeline in
                    canvas(at: timeline.date.timeIntervalSinceReferenceDate)
                }
            } else {
                canvas(at: 0)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func canvas(at time: TimeInterval) -> some View {
        Canvas { context, canvasSize in
            context.scaleBy(x: canvasSize.width / 24, y: canvasSize.height / 24)
            switch kind {
            case .claude: Self.drawCrab(in: &context, at: time)
            case .codex: Self.drawCloud(in: &context, at: time)
            case .cursor: Self.drawCube(in: &context, at: time)
            case .opencode: Self.drawTerminal(in: &context, at: time)
            case .antigravity: Self.drawArch(in: &context, at: time)
            }
        }
    }
}

// MARK: - Clock

private extension AgentMascot {
    /// Where `time` falls in a loop of `period`, 0 up to 1.
    static func phase(_ time: TimeInterval, _ period: TimeInterval) -> Double {
        time.truncatingRemainder(dividingBy: period) / period
    }

    /// The SVGs' ease-in-out spline (0.42 0 0.58 1), closely enough.
    static func ease(_ t: Double) -> Double { 0.5 - 0.5 * cos(.pi * t) }

    /// `values` at `keyTimes`, eased between each pair, at phase `p`.
    static func keyframes(_ values: [Double], _ keyTimes: [Double], at p: Double) -> Double {
        for index in 1..<keyTimes.count where p <= keyTimes[index] {
            let span = keyTimes[index] - keyTimes[index - 1]
            let t = span > 0 ? (p - keyTimes[index - 1]) / span : 1
            return values[index - 1] + (values[index] - values[index - 1]) * ease(t)
        }
        return values[values.count - 1]
    }

    static func rect(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> Path {
        Path(CGRect(x: x, y: y, width: width, height: height))
    }

    static let white = Color.white
}

// MARK: - Claude: the crab scuttles side to side on alternating legs, claws pumping, and blinks.

private extension AgentMascot {
    static func drawCrab(in context: inout GraphicsContext, at time: TimeInterval) {
        let shell = Color(red: 0.851, green: 0.467, blue: 0.341)
        var crab = context
        crab.translateBy(x: keyframes([-0.8, 0.8, -0.8], [0, 0.5, 1], at: phase(time, 2)), y: 0)
        // Each pair lifts for half of a half-second step, the other pair the other half.
        let lifted = phase(time, 0.5) >= 0.5
        let a: Double = lifted ? -1 : 0, b: Double = lifted ? 0 : -1
        for (x, lift) in [(6.0, a), (13.5, a), (9.0, b), (16.5, b)] {
            crab.fill(rect(x, 15 + lift, 1.5, 4), with: .color(shell))
        }
        crab.fill(rect(1.5, 9.5 + a, 3.5, 3), with: .color(shell))
        crab.fill(rect(19, 9.5 + b, 3.5, 3), with: .color(shell))
        crab.fill(Path(roundedRect: CGRect(x: 4.5, y: 6, width: 15, height: 10), cornerRadius: 0.6), with: .color(shell))
        // A blink near the end of every 3.6 s.
        let blink = keyframes([1, 1, 0.12, 1], [0, 0.9, 0.94, 1], at: phase(time, 3.6))
        let eye = Color(red: 0.078, green: 0.078, blue: 0.075)
        for x in [8.0, 14.4] {
            crab.fill(rect(x, 9.9 + (8.4 - 9.9) * blink, 1.6, 3 * blink), with: .color(eye))
        }
    }
}

// MARK: - Codex: the blue cloud breathes, its prompt chevron nudges forward and the cursor blinks.

private extension AgentMascot {
    static let cloud: Path = {
        var path = Path()
        path.addEllipse(in: CGRect(x: 12 - 6.9, y: 12 - 6.9, width: 13.8, height: 13.8))
        for (x, y) in [(17.54, 14.30), (14.30, 17.54), (9.70, 17.54), (6.46, 14.30),
                       (6.46, 9.70), (9.70, 6.46), (14.30, 6.46), (17.54, 9.70)] {
            path.addEllipse(in: CGRect(x: x - 3.45, y: y - 3.45, width: 6.9, height: 6.9))
        }
        return path
    }()

    static func drawCloud(in context: inout GraphicsContext, at time: TimeInterval) {
        let ink = Color(red: 0.961, green: 0.965, blue: 1)
        var group = context
        let scale = keyframes([1, 1.04, 1], [0, 0.5, 1], at: phase(time, 2.8))
        group.translateBy(x: 12, y: 12)
        group.scaleBy(x: scale, y: scale)
        group.translateBy(x: -12, y: -12)
        group.fill(cloud, with: .linearGradient(
            Gradient(stops: [
                .init(color: Color(red: 0.788, green: 0.722, blue: 1), location: 0),
                .init(color: Color(red: 0.443, green: 0.514, blue: 1), location: 0.45),
                .init(color: Color(red: 0.184, green: 0.231, blue: 0.949), location: 1),
            ]),
            startPoint: CGPoint(x: 9, y: 3), endPoint: CGPoint(x: 15, y: 21)
        ))
        var chevron = Path()
        let nudge = keyframes([0, 0.8, 0], [0, 0.5, 1], at: phase(time, 1.4))
        chevron.addLines([CGPoint(x: 8.4 + nudge, y: 9.3), CGPoint(x: 11.1 + nudge, y: 12), CGPoint(x: 8.4 + nudge, y: 14.7)])
        group.stroke(chevron, with: .color(ink), style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
        let cursorOn = phase(time, 1.4) < 0.5
        group.fill(Path(roundedRect: CGRect(x: 12.7, y: 13.8, width: 4, height: 1.8), cornerRadius: 0.9),
                   with: .color(ink.opacity(cursorOn ? 1 : 0.15)))
    }
}

// MARK: - Cursor: light travels around the cube's three faces while the arrow face taps down once per turn.

private extension AgentMascot {
    static func polygon(_ points: [(Double, Double)]) -> Path {
        var path = Path()
        path.addLines(points.map { CGPoint(x: $0.0, y: $0.1) })
        path.closeSubpath()
        return path
    }

    static func drawCube(in context: inout GraphicsContext, at time: TimeInterval) {
        let p = phase(time, 3)
        let times = [0, 0.333, 0.667, 1]
        let faces: [([(Double, Double)], [Double])] = [
            ([(12, 3), (19.8, 7.5), (12, 12), (4.2, 7.5)], [0.62, 0.2, 0.36, 0.62]),
            ([(12, 12), (19.8, 7.5), (19.8, 16.5), (12, 21)], [0.2, 0.36, 0.62, 0.2]),
            ([(4.2, 7.5), (12, 12), (12, 21), (4.2, 16.5)], [0.36, 0.62, 0.2, 0.36]),
        ]
        for (points, opacities) in faces {
            context.fill(polygon(points), with: .color(white.opacity(keyframes(opacities, times, at: p))))
        }
        var arrow = context
        let tap = keyframes([1, 1, 0.86, 1], [0, 0.78, 0.86, 1], at: p)
        arrow.translateBy(x: 12, y: 12)
        arrow.scaleBy(x: tap, y: tap)
        arrow.translateBy(x: -12, y: -12)
        arrow.fill(polygon([(5.3, 8.1), (18.7, 8.1), (12, 19.7)]), with: .color(white.opacity(0.96)))
    }
}

// MARK: - OpenCode: the square frame holds a terminal block cursor that types up a line and blinks.

private extension AgentMascot {
    static func drawTerminal(in context: inout GraphicsContext, at time: TimeInterval) {
        var frame = rect(5, 3, 14, 18)
        frame.addRect(CGRect(x: 8.2, y: 6.2, width: 7.6, height: 11.6))
        context.fill(frame, with: .color(white), style: FillStyle(eoFill: true))
        context.fill(rect(9.8, 7.8, 4.4, 8.4), with: .color(white.opacity(0.14)))
        // Discrete steps: the caret grows a third at a time, then blinks out once.
        let p = phase(time, 2.4)
        let height = 4.2 * (p < 0.15 ? 0.34 : p < 0.3 ? 0.67 : 1)
        let opacity = (0.65..<0.82).contains(p) ? 0.1 : 0.62
        context.fill(rect(9.8, 16.2 - height, 4.4, height), with: .color(white.opacity(opacity)))
    }
}

// MARK: - Antigravity: the arch levitates while its shadow below shrinks and fades, then settles back.

private extension AgentMascot {
    static let arch: Path = {
        var path = Path()
        func point(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x, y: y) }
        path.move(to: point(3.6, 18.9))
        path.addCurve(to: point(7.6, 12), control1: point(5.4, 17.4), control2: point(6.6, 15.6))
        path.addCurve(to: point(12, 4.6), control1: point(8.7, 7.8), control2: point(10, 4.6))
        path.addCurve(to: point(16.4, 12), control1: point(14, 4.6), control2: point(15.3, 7.8))
        path.addCurve(to: point(20.4, 18.9), control1: point(17.4, 15.6), control2: point(18.6, 17.4))
        path.addCurve(to: point(19.8, 20.2), control1: point(21, 19.4), control2: point(20.6, 20.3))
        path.addCurve(to: point(15.8, 17), control1: point(18.4, 20), control2: point(17, 19))
        path.addCurve(to: point(12, 13.6), control1: point(14.8, 15.3), control2: point(13.8, 13.6))
        path.addCurve(to: point(8.2, 17), control1: point(10.2, 13.6), control2: point(9.2, 15.3))
        path.addCurve(to: point(4.2, 20.2), control1: point(7, 19), control2: point(5.6, 20))
        path.addCurve(to: point(3.6, 18.9), control1: point(3.4, 20.3), control2: point(3, 19.4))
        path.closeSubpath()
        return path
    }()

    static func drawArch(in context: inout GraphicsContext, at time: TimeInterval) {
        let p = phase(time, 2.6)
        let shrink = keyframes([1, 0.66, 1], [0, 0.5, 1], at: p)
        let shadow = CGRect(x: 12 - 5.2 * shrink, y: 22.1 - 0.9 * shrink, width: 10.4 * shrink, height: 1.8 * shrink)
        context.fill(Path(ellipseIn: shadow), with: .color(white.opacity(keyframes([0.26, 0.1, 0.26], [0, 0.5, 1], at: p))))
        var lifted = context
        lifted.translateBy(x: 0, y: keyframes([0.3, -1.5, 0.3], [0, 0.5, 1], at: p))
        lifted.fill(arch, with: .linearGradient(
            Gradient(stops: [
                .init(color: Color(red: 0.204, green: 0.659, blue: 0.325), location: 0),
                .init(color: Color(red: 0.984, green: 0.737, blue: 0.016), location: 0.5),
                .init(color: Color(red: 0.918, green: 0.263, blue: 0.208), location: 1),
            ]),
            startPoint: CGPoint(x: 6, y: 8), endPoint: CGPoint(x: 18, y: 6)
        ))
        lifted.fill(arch, with: .linearGradient(
            Gradient(colors: [Color(red: 0.259, green: 0.522, blue: 0.957).opacity(0), Color(red: 0.239, green: 0.51, blue: 0.969)]),
            startPoint: CGPoint(x: 12, y: 6.5), endPoint: CGPoint(x: 12, y: 14)
        ))
    }
}

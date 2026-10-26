//
//  ChamberGlyph.swift
//  Openchamber
//
//  OpenChamber's open-shell cube, drawn from OpenChamber's own
//  openChamberLogoArt.ts (scripts/brand), with a ring around its silhouette
//  that says the phase. Hand-kept: update it when that drawing changes.
//

import SwiftUI
import DroppyKit

/// What the ring around the cube is doing.
enum ChamberGlyphMotion: Equatable {
    /// No ring: the plain mark, for headers and rows.
    case still
    /// Work of unknown length: the roof tiers light up one at a time, a step
    /// a second, OpenChamber's own loading; a still frame shows a closed ring.
    case sweep
    /// Work with a known end (a scheduled retry, the end of a turn): the ring
    /// fills from the bottom and closes at `end`.
    case fill(start: Date, end: Date)
    /// Something waits on the user: the ring is closed in orange and its glow
    /// switches on and off each second, OpenChamber's own loading rhythm.
    case waiting
    /// The last run failed: the ring is closed in red and holds still, since
    /// anything that moves reads as "still working".
    case failed
}

struct ChamberGlyph: View {
    let motion: ChamberGlyphMotion
    var size: CGFloat = DroppyLiveActivityMetrics.iconSize
    /// False while nobody can see the glyph (the seat was lost, the shelf is
    /// animating): the timeline stops and the glyph draws one still frame.
    var isAnimating = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let interval = tickInterval {
            // Discrete steps rather than per-frame animation: the glyph runs in
            // Droppy's process, and OpenChamber dropped its own smooth pulse for
            // repainting every frame.
            TimelineView(.periodic(from: .now, by: interval)) { timeline in
                canvas(at: timeline.date)
            }
        } else {
            canvas(at: .now)
        }
    }

    private var tickInterval: TimeInterval? {
        guard isAnimating, !reduceMotion else { return nil }
        switch motion {
        case .fill: return 1.0 / 12.0
        case .sweep, .waiting: return 1
        case .still, .failed: return nil
        }
    }

    private func canvas(at date: Date) -> some View {
        let animated = tickInterval != nil
        let ring = ChamberGlyph.ring(for: motion, at: date, animated: animated)
        let litTier = motion == .sweep && animated ? Int(date.timeIntervalSinceReferenceDate) % ChamberGlyph.tiers.count : nil
        return Canvas { context, canvasSize in
            // The edges keep 1.2 points at the notch's sizes, as OpenChamber's widget logo does.
            let points = canvasSize.width / 100
            context.scaleBy(x: points, y: points)
            ChamberGlyph.drawCube(in: &context, dimmed: ring != nil, litTier: litTier, lineWidth: max(2.2, 1.2 / points))
            if let ring {
                ChamberGlyph.drawRing(ring, in: &context)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Ring

extension ChamberGlyph {
    struct Ring: Equatable {
        /// Fractions of each side, measured from the bottom vertex up.
        var from: Double
        var to: Double
        var color: Color
        var glows: Bool
    }

    /// The ring at `date`. With `animated` false the glyph shows the ring's
    /// resting shape: closed for work, so a still frame still says "busy".
    static func ring(for motion: ChamberGlyphMotion, at date: Date, animated: Bool) -> Ring? {
        let primary = AdaptiveColors.notchSurfacePrimaryText
        switch motion {
        case .still:
            return nil
        case .sweep:
            // Moving, the tiers say it; held still, a closed ring still says busy.
            return animated ? nil : Ring(from: 0, to: 1, color: primary, glows: false)
        case let .fill(start, end):
            let span = end.timeIntervalSince(start)
            let progress = span > 0 ? date.timeIntervalSince(start) / span : 1
            return Ring(from: 0, to: animated ? min(1, max(0, progress)) : 1, color: primary, glows: false)
        case .waiting:
            let on = animated && Int(date.timeIntervalSinceReferenceDate) % 2 == 0
            return Ring(from: 0, to: 1, color: .orange, glows: on)
        case .failed:
            return Ring(from: 0, to: 1, color: .red, glows: false)
        }
    }
}

// MARK: - Geometry

extension ChamberGlyph {
    /// The roof tiers, outermost first: their size as a share of the roof, and
    /// their fill at rest, while another tier is lit, and lit.
    static let tiers: [(scale: CGFloat, still: Double, dim: Double, lit: Double)] = [
        (0.8, 0.22, 0.12, 0.55),
        (0.58, 0.27, 0.15, 0.48),
        (0.36, 0.85, 0.38, 0.85),
    ]
}

private extension ChamberGlyph {
    // The logo's -50…50 box moved into a 100-point one: edge 48, centred at (50, 50).
    static let top = CGPoint(x: 50, y: 2)
    static let left = CGPoint(x: 8.432, y: 26)
    static let right = CGPoint(x: 91.568, y: 26)
    static let center = CGPoint(x: 50, y: 50)
    static let bottomLeft = CGPoint(x: 8.432, y: 74)
    static let bottomRight = CGPoint(x: 91.568, y: 74)
    static let bottom = CGPoint(x: 50, y: 98)

    static func polygon(_ points: [CGPoint]) -> Path {
        var path = Path()
        path.addLines(points)
        path.closeSubpath()
        return path
    }

    static func polyline(_ points: [CGPoint]) -> Path {
        var path = Path()
        path.addLines(points)
        return path
    }

    /// The silhouette as two sides that both start at the bottom vertex, so a
    /// trim from 0 grows upward on both at once.
    static let leftSide = polyline([bottom, bottomLeft, left, top])
    static let rightSide = polyline([bottom, bottomRight, right, top])

    /// The roof, or a tier on it, at `scale` of the roof.
    static func rhombus(_ scale: CGFloat) -> Path {
        let half = (x: (right.x - left.x) / 2 * scale, y: (center.y - top.y) / 2 * scale)
        let mid = CGPoint(x: 50, y: 26)
        return polygon([CGPoint(x: mid.x, y: mid.y - half.y), CGPoint(x: mid.x + half.x, y: mid.y),
                        CGPoint(x: mid.x, y: mid.y + half.y), CGPoint(x: mid.x - half.x, y: mid.y)])
    }

    /// The edges: the roof's outline, the shell's sides and the front corner.
    static let shell: Path = {
        var path = polygon([top, left, center, right])
        path.addLines([left, bottomLeft, bottom, bottomRight, right])
        path.move(to: center)
        path.addLine(to: bottom)
        return path
    }()

    /// The open shell: the back walls seen through its missing front, a faint
    /// roof, three tiers that brighten toward the middle, and its edges.
    /// `dimmed` steps it back behind a ring; `litTier` is the one lit while it works.
    static func drawCube(in context: inout GraphicsContext, dimmed: Bool, litTier: Int?, lineWidth: CGFloat) {
        let ink = AdaptiveColors.notchSurfacePrimaryText
        let fade = dimmed ? 0.5 : 1
        context.fill(polygon([left, bottomLeft, center]), with: .color(ink.opacity(0.12 * fade)))
        context.fill(polygon([right, center, bottomRight]), with: .color(ink.opacity(0.15 * fade)))
        context.fill(rhombus(1), with: .color(ink.opacity(0.08 * fade)))
        for (index, tier) in tiers.enumerated() {
            let opacity = litTier.map { $0 == index ? tier.lit : tier.dim } ?? tier.still
            context.fill(rhombus(tier.scale), with: .color(ink.opacity(opacity * fade)))
        }
        context.stroke(shell, with: .color(ink.opacity(dimmed ? 0.35 : 1)),
                       style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
    }

    static func drawRing(_ ring: Ring, in context: inout GraphicsContext) {
        guard ring.to > ring.from else { return }
        let style = StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round)
        var layer = context
        if ring.glows {
            layer.addFilter(.shadow(color: ring.color, radius: 6))
        }
        for side in [leftSide, rightSide] {
            layer.stroke(side.trimmedPath(from: ring.from, to: ring.to), with: .color(ring.color), style: style)
        }
    }
}

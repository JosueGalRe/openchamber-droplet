//
//  ChamberGlyph.swift
//  Openchamber
//
//  OpenChamber's cube, drawn from the geometry in OpenChamber's own
//  OpenChamberLogo.tsx, with a ring around its silhouette that says the phase.
//

import SwiftUI
import DroppyKit

/// What the ring around the cube is doing.
enum ChamberGlyphMotion: Equatable {
    /// No ring: the plain mark, for headers and rows.
    case still
    /// Work of unknown length: a stretch of line climbs both sides and meets at the top.
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
        case .sweep, .fill: return 1.0 / 12.0
        case .waiting: return 1
        case .still, .failed: return nil
        }
    }

    private func canvas(at date: Date) -> some View {
        let ring = ChamberGlyph.ring(for: motion, at: date, animated: tickInterval != nil)
        return Canvas { context, canvasSize in
            context.scaleBy(x: canvasSize.width / 100, y: canvasSize.height / 100)
            ChamberGlyph.drawCube(in: &context, dimmed: motion != .still)
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

    static let sweepPeriod: TimeInterval = 1.6
    static let sweepLength = 46.0 / 144.0

    /// The ring at `date`. With `animated` false the glyph shows the ring's
    /// resting shape: closed for work, so a still frame still says "busy".
    static func ring(for motion: ChamberGlyphMotion, at date: Date, animated: Bool) -> Ring? {
        let primary = AdaptiveColors.notchSurfacePrimaryText
        switch motion {
        case .still:
            return nil
        case .sweep:
            guard animated else { return Ring(from: 0, to: 1, color: primary, glows: false) }
            let phase = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: sweepPeriod) / sweepPeriod
            let head = phase * (1 + sweepLength)
            return Ring(from: max(0, head - sweepLength), to: min(1, head), color: primary, glows: false)
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

private extension ChamberGlyph {
    // The isometric cube from OpenChamberLogo.tsx: edge 48, centred at (50, 50)
    // in a 100-point box.
    static let top = CGPoint(x: 50, y: 2)
    static let left = CGPoint(x: 8.43, y: 26)
    static let right = CGPoint(x: 91.57, y: 26)
    static let center = CGPoint(x: 50, y: 50)
    static let bottomLeft = CGPoint(x: 8.43, y: 74)
    static let bottomRight = CGPoint(x: 91.57, y: 74)
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

    /// The OpenCode mark on the lid, projected onto the top face.
    static let lidTransform = CGAffineTransform(a: 0.866, b: 0.5, c: -0.866, d: 0.5, tx: 50, ty: 26)
        .scaledBy(x: 0.75, y: 0.75)

    static let lidFrame: Path = {
        var path = Path()
        path.addRect(CGRect(x: -16, y: -20, width: 32, height: 40))
        path.addRect(CGRect(x: -8, y: -12, width: 16, height: 24))
        return path.applying(lidTransform)
    }()

    static let lidCaret = Path(CGRect(x: -8, y: -4, width: 16, height: 16)).applying(lidTransform)

    static func drawCube(in context: inout GraphicsContext, dimmed: Bool) {
        let ink = AdaptiveColors.notchSurfacePrimaryText
        let edge = ink.opacity(dimmed ? 0.3 : 1)
        let stroke = StrokeStyle(lineWidth: 5, lineJoin: .round)

        for face in [polygon([center, left, bottomLeft, bottom]), polygon([center, right, bottomRight, bottom])] {
            context.fill(face, with: .color(ink.opacity(dimmed ? 0.12 : 0.25)))
            context.stroke(face, with: .color(edge), style: stroke)
        }
        context.stroke(polygon([top, left, center, right]), with: .color(edge), style: stroke)
        context.fill(lidFrame, with: .color(ink.opacity(dimmed ? 0.85 : 1)), style: FillStyle(eoFill: true))
        context.fill(lidCaret, with: .color(ink.opacity(0.4)))
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

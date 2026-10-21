//
//  Views.swift
//  Openchamber
//
//  Every surface's SwiftUI. Layout follows Droppy's widget rules: no card
//  around the widget, one root padding of `context.contentInsets`, a 12pt
//  header row, leading text and trailing monospaced numbers.
//

import DroppyKit
import SwiftUI

enum Formatting {
    /// `4:12`, `1:04:12`.
    static func elapsed(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        let hours = seconds / 3600, minutes = seconds / 60 % 60, rest = seconds % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, rest)
            : String(format: "%d:%02d", minutes, rest)
    }

    /// `12m`, `1h 12m`, `3d 4h`.
    static func countdown(to date: Date?, from now: Date) -> String {
        guard let date else { return "" }
        let minutes = max(0, Int(date.timeIntervalSince(now) / 60))
        if minutes >= 1440 { return "\(minutes / 1440)d \(minutes % 1440 / 60)h" }
        if minutes >= 60 { return "\(minutes / 60)h \(minutes % 60)m" }
        return "\(minutes)m"
    }

    /// Who is doing the work: `claude-sonnet-4.5 · Build · devbox`. The
    /// provider's name stands in until the session's model is known.
    static func runner(of session: SessionInfo?, server: String?) -> String {
        let model = session?.modelID.map { ($0 as NSString).lastPathComponent }
            ?? ProviderStyle.displayName(session?.providerID ?? "")
        let agent = session?.agent.map { $0.prefix(1).uppercased() + $0.dropFirst() }
        return [model, agent, server].compactMap { $0 }.joined(separator: " · ")
    }

    /// `5-hour limit`, `Weekly · all models`, `Weekly · Fable`.
    static func windowLabel(_ window: QuotaWindow, in provider: ProviderQuota) -> String {
        let base: String
        switch window.name.lowercased() {
        case "5h": base = "5-hour limit"
        case "7d", "weekly", "week": base = "Weekly"
        case "1d", "24h", "daily", "day": base = "Daily"
        case "30d", "monthly", "month": base = "Monthly"
        case "extra_usage": base = "Extra usage"
        default:
            let words = window.name.replacingOccurrences(of: "_", with: " ")
            base = words.prefix(1).uppercased() + words.dropFirst()
        }
        if let model = window.model { return "\(base) · \(model)" }
        let perModel = provider.windows.contains { $0.model != nil && $0.name == window.name }
        return perModel ? "\(base) · all models" : base
    }

    /// `Resets in 4 hr 21 min` within a day, the date after that.
    static func resetText(_ date: Date?, now: Date) -> String {
        guard let date else { return "" }
        let seconds = date.timeIntervalSince(now)
        guard seconds > 0 else { return "Resetting" }
        guard seconds >= 86_400 else {
            let minutes = Int(seconds / 60)
            return minutes >= 60 ? "Resets in \(minutes / 60) hr \(minutes % 60) min" : "Resets in \(minutes) min"
        }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }

    static func usageColor(_ percent: Double?) -> Color {
        switch percent ?? 0 {
        case 95...: return .red
        case 80...: return .orange
        default: return AdaptiveColors.notchSurfacePrimaryText
        }
    }
}

// MARK: - Live activity

struct CompactGlyph: View {
    @ObservedObject var droplet: OpenchamberDroplet
    let size: CGFloat

    var body: some View {
        ChamberGlyph(motion: droplet.glyphMotion, size: size, isAnimating: droplet.seat.isPresented)
    }
}

struct CompactLabel: View {
    @ObservedObject var droplet: OpenchamberDroplet

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let (symbol, text, color) = label(at: timeline.date)
            HStack(spacing: 3) {
                if let symbol {
                    // A lone symbol (the green check) stands in for a word, so it is drawn larger.
                    Image(systemName: symbol).font(.system(size: DroppyLiveActivityMetrics.labelFontSize + (text.isEmpty ? 3 : -2), weight: .semibold))
                }
                Text(verbatim: text)
                    .font(.system(size: DroppyLiveActivityMetrics.labelFontSize, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.75)
            }
            .foregroundStyle(color)
            .lineLimit(1)
            .id(kind)
            .transition(DroppyTransition.compactContent)
        }
    }

    /// Changes only when the label means something else, so the swap
    /// transition plays on "working" to "waiting", not on every second.
    private var kind: String {
        switch droplet.phase {
        case .idle: return "idle"
        case .working: return "working"
        case .retrying: return "retrying"
        case .finishing: return "finishing"
        case .waiting: return "waiting"
        case .failed: return "failed"
        }
    }

    /// The wing is 70pt at rest, so every label fits in about eight characters.
    private func label(at now: Date) -> (symbol: String?, text: String, color: Color) {
        let primary = AdaptiveColors.notchSurfacePrimaryText
        switch droplet.phase {
        case .idle: return (nil, "", primary)
        case let .working(sessions, since):
            let elapsed = Formatting.elapsed(now.timeIntervalSince(since))
            return (nil, sessions > 1 ? "\(sessions)\u{2009}·\u{2009}\(elapsed)" : elapsed, primary)
        case let .retrying(_, _, at): return ("arrow.clockwise", Formatting.elapsed(at.timeIntervalSince(now)), primary)
        case .finishing: return ("checkmark.circle.fill", "", .green)
        case let .waiting(count): return ("hand.raised.fill", "\(count)", .orange)
        case .failed: return ("exclamationmark.triangle.fill", "failed", .red)
        }
    }
}

// MARK: - Widget

extension ShelfWidgetContext {
    /// Droppy marks every widget in a shared row compact, however wide its
    /// share of the row is; a share as wide as a solo widget gets the full layout.
    var isNarrow: Bool { isCompact && availableSize.width < 360 }
}

/// The one widget: a Sessions page and a Usage page. The header says how
/// things stand; the switch at its end changes the page.
struct OpenchamberWidget: View {
    @ObservedObject var droplet: OpenchamberDroplet
    let context: ShelfWidgetContext

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WidgetHeader(status: status) { PageSwitch(droplet: droplet) }
                .padding(.bottom, DroppySpacing.smd)
            if droplet.connection == .noServers {
                NoServersMessage(droplet: droplet)
                Spacer(minLength: 0)
            } else if droplet.tab == .usage {
                UsageRings(droplet: droplet, context: context)
            } else {
                SessionsPage(droplet: droplet, context: context)
            }
        }
        .padding(context.contentInsets)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var status: HeaderStatus {
        guard droplet.tab == .sessions else {
            return HeaderStatus(symbol: "gauge.with.dots.needle.33percent", title: "Usage")
        }
        let busy = droplet.state.busySessionIDs.count
        switch droplet.phase {
        case let .waiting(count):
            let running = busy > 0 && !context.isNarrow ? " · \(busy) running" : ""
            return HeaderStatus(symbol: "hand.raised.fill", title: (context.isNarrow ? "Waiting" : "\(count) waiting") + running, tint: .orange)
        case .working:
            return HeaderStatus(symbol: "play.fill", title: busy == 1 ? "Working" : "\(busy) running")
        case .retrying:
            return HeaderStatus(symbol: "arrow.clockwise", title: "Retrying")
        case .finishing:
            return HeaderStatus(symbol: "checkmark", title: "Done", tint: .green)
        case .failed:
            return HeaderStatus(symbol: "exclamationmark.triangle.fill", title: "Failed", tint: .red)
        case .idle:
            return HeaderStatus(symbol: "checklist", title: "Sessions")
        }
    }
}

struct HeaderStatus: Equatable {
    var symbol: String
    var title: String
    var tint: Color = AdaptiveColors.notchSurfaceSecondaryText
}

private struct WidgetHeader<Trailing: View>: View {
    let status: HeaderStatus
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: DroppySpacing.xsm) {
            Image(systemName: status.symbol).font(.system(size: 11, weight: .semibold))
            Text(status.title)
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
            Spacer(minLength: DroppySpacing.sm)
            trailing
        }
        .foregroundStyle(status.tint)
        .frame(height: 24)
    }
}

/// Two small discs in one track, Droppy's own circle buttons: the page that
/// is showing is green, as in Agents, at a size that leaves the header room.
private struct PageSwitch: View {
    @ObservedObject var droplet: OpenchamberDroplet

    var body: some View {
        HStack(spacing: 2) {
            segment(.sessions, symbol: "checklist", label: "Sessions")
            segment(.usage, symbol: "gauge.with.dots.needle.33percent", label: "Usage")
        }
        .padding(2)
        .background(AdaptiveColors.notchSurfaceCardFill, in: Capsule())
    }

    private func segment(_ tab: OpenchamberDroplet.WidgetTab, symbol: String, label: String) -> some View {
        let selected = droplet.tab == tab
        return Button { droplet.select(tab) } label: {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
        }
        .buttonStyle(DroppyCircleButtonStyle(
            size: 20,
            destructive: false,
            solidFill: selected ? Color.green.opacity(0.24) : Color.clear,
            foregroundColorOverride: selected ? .green : AdaptiveColors.notchSurfaceTertiaryText
        ))
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Sessions page

/// What waits on you first, then what is running; nothing at all becomes a
/// tile per server.
private struct SessionsPage: View {
    @ObservedObject var droplet: OpenchamberDroplet
    let context: ShelfWidgetContext
    /// The session opened from the list; the others fold to a line each.
    @State private var expanded: String?

    private var state: ActivityState { droplet.state }

    var body: some View {
        let busy = state.busySessionIDs
        if let permission = state.permissions.first {
            ApprovalView(droplet: droplet, permission: permission, compact: context.isNarrow)
            if !context.isNarrow, let other = busy.last(where: { $0 != permission.sessionID }) {
                Spacer(minLength: DroppySpacing.sm)
                SessionLine(droplet: droplet, sessionID: other, oneLine: true) { droplet.openSession(other) }
            }
        } else if let form = state.forms.first {
            FormView(droplet: droplet, form: form, compact: context.isNarrow)
        } else if busy.count == 1 {
            SessionHero(droplet: droplet, sessionID: busy[0], compact: context.isNarrow)
        } else if busy.count > 1 {
            VStack(alignment: .leading, spacing: DroppySpacing.smd) {
                if let open = expanded, busy.contains(open) {
                    let others = Array(busy.filter { $0 != open }.suffix(2).reversed())
                    SessionHero(droplet: droplet, sessionID: open, compact: context.isNarrow,
                                lastTextLines: others.count > 1 ? 0 : 1) { expanded = nil }
                        .id(open)
                        .transition(DroppyTransition.element)
                    ForEach(others, id: \.self) { id in
                        SessionLine(droplet: droplet, sessionID: id, oneLine: true) { expanded = id }
                    }
                } else {
                    ForEach(busy.suffix(3).reversed(), id: \.self) { id in
                        SessionLine(droplet: droplet, sessionID: id, oneLine: false, compact: context.isNarrow) { expanded = id }
                    }
                    Spacer(minLength: 0)
                    if busy.count > 3 {
                        Text(verbatim: "+\(busy.count - 3) more")
                            .font(.system(size: 11))
                            .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                    }
                }
            }
            .onChange(of: busy) { _, ids in
                if let open = expanded, !ids.contains(open) { expanded = nil }
            }
        } else if case let .failed(id) = droplet.phase {
            SessionHero(droplet: droplet, sessionID: id, compact: context.isNarrow)
        } else {
            ServerTiles(droplet: droplet, context: context)
        }
    }
}

/// One session, given the room: its title, what it is doing in words, its
/// last words, and along the bottom the run of steps and who is doing it.
private struct SessionHero: View {
    let droplet: OpenchamberDroplet
    let sessionID: String
    let compact: Bool
    /// Lines of the assistant's last words; a hero sharing the page gets fewer.
    var lastTextLines = 2
    /// Set when the hero was opened from the list: a tap folds it back, and
    /// OpenChamber opens only from its button.
    var collapse: (() -> Void)? = nil
    @State private var showsDetail = false

    var body: some View {
        let session = droplet.state.sessions[sessionID]
        let activity = droplet.state.activity[sessionID] ?? SessionActivity()
        let provider = session?.providerID ?? ""
        let failed = droplet.phase == .failed(sessionID: sessionID)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DroppySpacing.sm) {
                AgentMark(provider: provider, size: compact ? 16 : 20)
                Text(session?.title ?? "Session")
                    .font(.system(size: compact ? 14 : 15, weight: .semibold))
                    .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                    .lineLimit(1)
                Spacer(minLength: DroppySpacing.md)
                if !compact {
                    ElapsedText(since: activity.busySince, size: 13)
                }
                Button { droplet.openSession(sessionID) } label: {
                    Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(DroppyCircleButtonStyle(size: 20))
                .help("Open in OpenChamber")
                .accessibilityLabel("Open in OpenChamber")
            }
            // What it is doing and its last words: the part with more to read.
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: DroppySpacing.sm) {
                    NarrationText(narration: failed ? nil : activity.narration, failed: failed, size: compact ? 12 : 13)
                    if !compact {
                        Spacer(minLength: DroppySpacing.md)
                        Text(session?.project ?? "")
                            .font(.system(size: 12))
                            .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                            .lineLimit(1)
                    }
                }
                .padding(.leading, compact ? 0 : 28)
                .padding(.top, DroppySpacing.xs)

                Spacer(minLength: DroppySpacing.sm)

                if !compact, lastTextLines > 0, let text = activity.lastText {
                    Text(text)
                        .font(.system(size: 12))
                        .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                        .lineLimit(lastTextLines)
                        .padding(.leading, DroppySpacing.sm)
                        .overlay(alignment: .leading) {
                            Capsule().fill(AdaptiveColors.notchSurfacePrimaryText.opacity(0.14)).frame(width: 2)
                        }
                        .padding(.bottom, DroppySpacing.sm)
                }
            }
            .contentShape(Rectangle())
            .hoverCard(droplet: droplet, isPresented: $showsDetail) {
                SessionDetail(droplet: droplet, sessionID: sessionID)
            }

            HStack(spacing: DroppySpacing.sm) {
                CallStrip(calls: Array(activity.calls.suffix(compact ? 8 : 12)))
                if !compact, activity.steps > 0 {
                    Text(verbatim: activity.steps == 1 ? "1 step" : "\(activity.steps) steps")
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                }
                Spacer(minLength: DroppySpacing.sm)
                if compact {
                    ElapsedText(since: activity.busySince, size: 13)
                } else {
                    Text(Formatting.runner(of: session, server: droplet.serverLabel(forSession: sessionID)))
                        .font(.system(size: 12))
                        .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if let collapse { collapse() } else { droplet.openSession(sessionID) } }
        .accessibilityAddTraits(.isButton)
    }
}

/// A session in a list: title and time, then what it is doing.
private struct SessionLine: View {
    let droplet: OpenchamberDroplet
    let sessionID: String
    let oneLine: Bool
    /// A narrow row keeps the server, which tells the sessions apart, and drops the project.
    var compact = false
    let tap: () -> Void

    var body: some View {
        let session = droplet.state.sessions[sessionID]
        let activity = droplet.state.activity[sessionID] ?? SessionActivity()
        let title = Text(session?.title ?? "Session")
            .font(.system(size: 13, weight: oneLine ? .medium : .semibold))
            .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: DroppySpacing.sm) {
                AgentMark(provider: session?.providerID ?? "", size: 16)
                if oneLine {
                    (title + Text(verbatim: activity.narration.map { "  " + $0.sentence } ?? "")
                        .font(.system(size: 12))
                        .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText))
                        .lineLimit(1)
                } else {
                    title.lineLimit(1)
                }
                Spacer(minLength: DroppySpacing.sm)
                ElapsedText(since: activity.busySince, size: 12)
            }
            if !oneLine {
                HStack(spacing: DroppySpacing.sm) {
                    NarrationText(narration: activity.narration, failed: false, size: 12)
                    Spacer(minLength: DroppySpacing.sm)
                    Text([droplet.serverLabel(forSession: sessionID), compact ? nil : session?.project].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 11))
                        .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                        .lineLimit(1)
                }
                .padding(.leading, 24)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: tap)
        .accessibilityAddTraits(.isButton)
    }
}

/// **Running** swift test.
private struct NarrationText: View {
    let narration: Narration?
    let failed: Bool
    let size: CGFloat

    var body: some View {
        Group {
            if failed {
                Text("Failed").foregroundStyle(.red)
            } else if let narration {
                Text(narration.verb).fontWeight(.semibold).foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                    + Text(verbatim: narration.object.map { " " + $0 } ?? "").foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
            } else {
                Text("Idle").foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
            }
        }
        .font(.system(size: size))
        .lineLimit(1)
        .truncationMode(.middle)
    }
}

private struct ElapsedText: View {
    let since: Date?
    let size: CGFloat

    var body: some View {
        if let since {
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                Text(verbatim: Formatting.elapsed(timeline.date.timeIntervalSince(since)))
                    .font(.system(size: size, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
            }
        }
    }
}

/// The oldest request, with everything needed to decide on it in view.
private struct ApprovalView: View {
    let droplet: OpenchamberDroplet
    let permission: PendingPermission
    let compact: Bool

    var body: some View {
        let session = droplet.state.sessions[permission.sessionID]
        let command = permission.resources.joined(separator: "\n")
        if compact {
            VStack(alignment: .leading, spacing: DroppySpacing.xs) {
                Text(session?.title ?? "A session")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                    .lineLimit(1)
                Text(command.isEmpty ? permission.action : command)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: DroppySpacing.sm)
                HStack(spacing: DroppySpacing.xsm) {
                    Button("Allow once") { droplet.reply(to: permission, decision: "once") }
                        .buttonStyle(DroppyAccentButtonStyle(color: .orange, size: .small))
                    Spacer(minLength: 0)
                    Button("Reject") { droplet.reply(to: permission, decision: "reject") }
                        .buttonStyle(DroppyQuietButtonStyle(size: .small, destructive: true))
                }
                .frame(height: 28)
            }
        } else {
            VStack(alignment: .leading, spacing: DroppySpacing.xsm) {
                HStack(spacing: DroppySpacing.xsm) {
                    AgentMark(provider: session?.providerID ?? "", size: 16)
                    Text(session?.title ?? "A session")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                        .lineLimit(1)
                    Text("wants to \(permission.action == "bash" || permission.action == "shell" ? "run" : permission.action)")
                        .font(.system(size: 12))
                        .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                        .lineLimit(1)
                        .layoutPriority(1)
                    Spacer(minLength: DroppySpacing.sm)
                    Text([droplet.serverLabel(forSession: permission.sessionID), session?.project].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 11))
                        .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
                .onTapGesture { droplet.openSession(permission.sessionID) }
                if !command.isEmpty {
                    Text(command)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                HStack(spacing: DroppySpacing.xsm) {
                    Button("Allow once") { droplet.reply(to: permission, decision: "once") }
                        .buttonStyle(DroppyAccentButtonStyle(color: .orange, size: .small))
                    Button("Always") { droplet.reply(to: permission, decision: "always") }
                        .buttonStyle(DroppyQuietButtonStyle(size: .small))
                    Spacer(minLength: 0)
                    if droplet.state.pendingCount > 1 {
                        Text(verbatim: "+\(droplet.state.pendingCount - 1)")
                            .font(.system(size: 11, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                    }
                    Button("Reject") { droplet.reply(to: permission, decision: "reject") }
                        .buttonStyle(DroppyQuietButtonStyle(size: .small, destructive: true))
                }
            }
            .padding(DroppySpacing.smd)
            .background(AdaptiveColors.notchSurfaceCardFill, in: RoundedRectangle(cornerRadius: DroppyRadius.medium, style: .continuous))
        }
    }
}

/// Forms can hold any number of fields, so they are answered in OpenChamber.
private struct FormView: View {
    let droplet: OpenchamberDroplet
    let form: PendingForm
    let compact: Bool

    var body: some View {
        let session = droplet.state.sessions[form.sessionID]
        VStack(alignment: .leading, spacing: DroppySpacing.xs) {
            Text(form.title)
                .font(.system(size: compact ? 14 : 15, weight: .semibold))
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                .lineLimit(2)
            Text(session.map { "\($0.title) · \($0.project)" } ?? "A session asks")
                .font(.system(size: 12))
                .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                .lineLimit(1)
            Spacer(minLength: DroppySpacing.sm)
            HStack {
                Button("Answer in OpenChamber") { droplet.openSession(form.sessionID) }
                    .buttonStyle(DroppyAccentButtonStyle(color: .orange, size: .small))
                Spacer(minLength: 0)
            }
            .frame(height: 28)
        }
    }
}

/// Nothing running: one tile per server and how it is doing, where Agents
/// shows a tile per agent.
private struct ServerTiles: View {
    @ObservedObject var droplet: OpenchamberDroplet
    let context: ShelfWidgetContext

    var body: some View {
        HStack(spacing: context.isNarrow ? DroppySpacing.md : DroppySpacing.xl) {
            ForEach(droplet.servers.prefix(context.isNarrow ? 2 : 4)) { server in
                VStack(spacing: DroppySpacing.xsm) {
                    ChamberGlyph(motion: .still, size: context.isNarrow ? 22 : 28)
                        .frame(width: context.isNarrow ? 46 : 58, height: context.isNarrow ? 46 : 58)
                        .background(AdaptiveColors.notchSurfaceCardFill, in: RoundedRectangle(cornerRadius: DroppyRadius.ml, style: .continuous))
                    Text(server.label)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                        .lineLimit(1)
                    Text(status(of: server))
                        .font(.system(size: 11))
                        .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                        .lineLimit(1)
                }
                .frame(maxWidth: 96)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func status(of server: ChamberServer) -> String {
        switch droplet.serverStates[server.id]?.connection ?? .connecting {
        case .live: return droplet.serverStates[server.id]?.route?.hasPrefix("Through") == true ? "Idle · relay" : "Idle"
        case .offline: return "Unreachable"
        case .connecting: return "Connecting"
        case .failed: return "Reconnecting"
        case .noServers: return ""
        }
    }
}

private struct WidgetMessage: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct NoServersMessage: View {
    let droplet: OpenchamberDroplet

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            WidgetMessage(text: "OpenChamber Desktop isn't set up on this Mac yet.")
            Button("Open settings") { droplet.openSettings() }
                .buttonStyle(DroppyQuietButtonStyle(size: .small))
        }
    }
}

/// The provider's icon when Droppy has one, else OpenChamber's cube.
private struct AgentMark: View {
    let provider: String
    let size: CGFloat

    var body: some View {
        if ProviderStyle.image(provider) != nil {
            ProviderIcon(provider: provider, name: provider, size: size)
        } else {
            ChamberGlyph(motion: .still, size: size)
        }
    }
}

/// The turn's calls, oldest first: white while running, green done, red
/// failed. A run going wrong shows before you read a word.
private struct CallStrip: View {
    let calls: [ToolCall]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(calls, id: \.id) { call in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(color(call.mark))
                    .frame(width: 4, height: 10)
            }
        }
        .accessibilityHidden(true)
    }

    private func color(_ mark: ToolMark) -> Color {
        switch mark {
        case .running: return AdaptiveColors.notchSurfacePrimaryText
        case .succeeded: return .green.opacity(0.85)
        case .failed: return .red.opacity(0.85)
        }
    }
}

// MARK: - Usage page

/// One ring per provider: what is left of its tightest window, in the
/// provider's colour around its icon. A click opens every window.
struct UsageRings: View {
    @ObservedObject var droplet: OpenchamberDroplet
    let context: ShelfWidgetContext

    var body: some View {
        let all = droplet.usage
        let layout = RingLayout(count: all.count, width: context.availableSize.width, compact: context.isNarrow)
        Group {
            if all.isEmpty {
                WidgetMessage(text: droplet.connection == .live ? "No plan usage from OpenChamber yet." : "OpenChamber isn't reachable.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                HStack(alignment: .top, spacing: layout.spacing) {
                    ForEach(all.prefix(layout.visible)) { provider in
                        RingTile(droplet: droplet, provider: provider, diameter: layout.diameter, width: layout.tileWidth)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            if !context.isPreview { droplet.refreshUsage(ifOlderThan: 60) }
        }
    }
}

/// Rings shrink until every provider fits, down to a size that still reads;
/// past that, the ones that do not fit are left out.
struct RingLayout: Equatable {
    let diameter: CGFloat
    let tileWidth: CGFloat
    let spacing: CGFloat
    let visible: Int

    init(count: Int, width: CGFloat, compact: Bool) {
        let largest: CGFloat = compact ? 50 : 62
        let smallest: CGFloat = 36
        // A tile is its ring plus room for a label under it.
        let labelRoom: CGFloat = 24
        spacing = compact ? DroppySpacing.sm : DroppySpacing.lg
        let fits = max(1, Int((width + spacing) / (smallest + labelRoom + spacing)))
        visible = max(1, min(count, fits))
        tileWidth = min(largest + labelRoom + 16, (width + spacing) / CGFloat(visible) - spacing)
        diameter = min(largest, max(smallest, tileWidth - labelRoom))
    }
}

private struct RingTile: View {
    let droplet: OpenchamberDroplet
    let provider: ProviderQuota
    let diameter: CGFloat
    let width: CGFloat
    @State private var showsDetail = false

    var body: some View {
        let left = provider.percentLeft ?? 100
        let line = diameter * 0.085
        Button { showsDetail.toggle() } label: {
            VStack(spacing: DroppySpacing.xs) {
                ZStack {
                    Circle().stroke(AdaptiveColors.notchSurfacePrimaryText.opacity(0.12), lineWidth: line)
                    // What is used is the gap from twelve o'clock; the arc is what is left.
                    Circle()
                        .trim(from: 1 - left / 100, to: 1)
                        .stroke(ProviderStyle.color(provider.provider), style: StrokeStyle(lineWidth: line, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    ProviderIcon(provider: provider.provider, name: provider.name, size: diameter * 0.46)
                }
                .frame(width: diameter, height: diameter)
                .padding(line / 2)
                Text(provider.name)
                    .font(.system(size: diameter < 48 ? 12 : 13, weight: .semibold))
                    .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(verbatim: provider.caption)
                    .font(.system(size: diameter < 48 ? 11 : 12))
                    .monospacedDigit()
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
            }
            .frame(width: width)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(provider.name), \(provider.caption)")
        .hoverCard(droplet: droplet, isPresented: $showsDetail) {
            UsageDetail(droplet: droplet, provider: provider)
        }
    }
}

/// A card hanging under a view while the pointer is on either. It opens a
/// beat after the pointer arrives, so sweeping across opens nothing, and
/// closes a beat after it leaves both, so crossing the gap keeps it open.
/// The shelf stays open while it shows, or leaving the shelf for the card
/// would close the shelf under it.
private struct HoverCard<Card: View>: ViewModifier {
    let droplet: OpenchamberDroplet
    @Binding var isPresented: Bool
    @ViewBuilder let card: () -> Card
    @State private var overAnchor = false
    @State private var overCard = false
    @State private var pending: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onHover { overAnchor = $0; hoverChanged() }
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                card().onHover { overCard = $0; hoverChanged() }
            }
            .onChange(of: isPresented) { _, shown in droplet.holdShelfOpen(shown) }
            // Gone with the card up: nothing else would let go of the shelf.
            .onDisappear {
                pending?.cancel()
                if isPresented { isPresented = false; droplet.holdShelfOpen(false) }
            }
    }

    private func hoverChanged() {
        pending?.cancel()
        let wanted = overAnchor || overCard
        guard wanted != isPresented else { return }
        pending = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(wanted ? 180 : 300))
            guard !Task.isCancelled else { return }
            isPresented = wanted
        }
    }
}

extension View {
    fileprivate func hoverCard<Card: View>(droplet: OpenchamberDroplet, isPresented: Binding<Bool>, @ViewBuilder card: @escaping () -> Card) -> some View {
        modifier(HoverCard(droplet: droplet, isPresented: isPresented, card: card))
    }
}

/// More of a session than the shelf has room for: the whole command or path
/// of the call it is in and its last words, each capped so the card stays a
/// glance, not a transcript.
private struct SessionDetail: View {
    @ObservedObject var droplet: OpenchamberDroplet
    let sessionID: String

    var body: some View {
        let session = droplet.state.sessions[sessionID]
        let activity = droplet.state.activity[sessionID] ?? SessionActivity()
        let running = activity.calls.last { $0.mark == .running }
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(session?.title ?? "Session").font(.system(size: 15, weight: .semibold)).lineLimit(2)
                Text([Formatting.runner(of: session, server: droplet.serverLabel(forSession: sessionID)), session?.project]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let running {
                VStack(alignment: .leading, spacing: 4) {
                    Text(Narration(call: running).verb).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    if let target = running.target {
                        Text(target)
                            .font(.system(size: 12, design: .monospaced))
                            .lineLimit(6)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if let text = activity.lastText {
                Text(text)
                    .font(.system(size: 13))
                    .lineLimit(10)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if activity.steps > 0 {
                Text(verbatim: activity.steps == 1 ? "1 step this turn" : "\(activity.steps) steps this turn")
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 340, alignment: .leading)
    }
}

/// Every window of one provider, like Agents' usage card.
private struct UsageDetail: View {
    let droplet: OpenchamberDroplet
    let provider: ProviderQuota

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    ProviderIcon(provider: provider.provider, name: provider.name, size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(provider.name).font(.system(size: 15, weight: .semibold))
                        let detail = [provider.plan, provider.server].compactMap { $0 }.joined(separator: " · ")
                        if !detail.isEmpty {
                            Text(detail).font(.system(size: 13)).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 12)
                    Button { droplet.refreshUsage(ifOlderThan: 0) } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .help("Refresh")
                }
                ForEach(provider.windows) { window in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: DroppySpacing.sm) {
                            Text(Formatting.windowLabel(window, in: provider)).font(.system(size: 14))
                            Spacer(minLength: 12)
                            Text(Formatting.resetText(window.resetAt, now: timeline.date))
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                            Text(verbatim: window.usedPercent.map { "\(Int($0.rounded()))%" } ?? window.valueLabel ?? "–")
                                .font(.system(size: 14, weight: .semibold))
                                .monospacedDigit()
                        }
                        if window.usedPercent != nil {
                            UsageBar(percent: window.usedPercent, color: ProviderStyle.color(provider.provider))
                        }
                    }
                }
            }
            .padding(16)
            .frame(width: 340)
        }
    }
}

private struct UsageBar: View {
    let percent: Double?
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule()
                    .fill(color)
                    .frame(width: max(6, proxy.size.width * min(1, max(0, (percent ?? 0) / 100))))
            }
        }
        .frame(height: 6)
    }
}

/// Colours and icons per provider. The icons are the ones Droppy ships for its
/// own Agents droplet, read from Droppy's bundle since the droplet runs in it;
/// in the harness they are absent and a monogram stands in.
@MainActor
enum ProviderStyle {
    private static var images: [String: NSImage] = [:]

    nonisolated static func key(_ provider: String) -> String? {
        let id = provider.lowercased()
        if id.contains("claude") || id.contains("anthropic") { return "claude" }
        if id.contains("codex") || id.contains("openai") || id.contains("chatgpt") { return "codex" }
        if id.contains("cursor") { return "cursor" }
        if id.contains("opencode") { return "opencode" }
        if id.contains("antigravity") { return "antigravity" }
        return nil
    }

    /// What Agents calls the agent: the product, not the provider id.
    nonisolated static func displayName(_ provider: String) -> String {
        let id = provider.lowercased()
        switch key(provider) {
        case "claude": return "Claude"
        case "codex": return id.contains("codex") ? "Codex" : "OpenAI"
        case "opencode": return "OpenCode"
        case "cursor": return "Cursor"
        case "antigravity": return "Antigravity"
        default: break
        }
        switch id {
        case "": return "OpenChamber"
        case "google", "google-vertex": return "Gemini"
        case "github-copilot": return "Copilot"
        default: return provider.prefix(1).uppercased() + provider.dropFirst()
        }
    }

    static func color(_ provider: String) -> Color {
        switch key(provider) {
        case "claude": return Color(red: 0.88, green: 0.54, blue: 0.36)
        case "codex": return Color(red: 0.36, green: 0.56, blue: 0.97)
        case "antigravity": return Color(red: 0.38, green: 0.62, blue: 1)
        default: return AdaptiveColors.notchSurfacePrimaryText.opacity(0.85)
        }
    }

    static func image(_ provider: String) -> NSImage? {
        guard let key = key(provider) else { return nil }
        if let cached = images[key] { return cached }
        let image = Bundle.main
            .url(forResource: "ai-assistant-\(key)", withExtension: "png", subdirectory: "ExtensionMedia")
            .flatMap(NSImage.init(contentsOf:))
        images[key] = image
        return image
    }
}

private struct ProviderIcon: View {
    let provider: String
    let name: String
    let size: CGFloat

    var body: some View {
        if let image = ProviderStyle.image(provider) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
        } else {
            Text(verbatim: String(name.prefix(1)).uppercased())
                .font(.system(size: size * 0.5, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(ProviderStyle.color(provider).opacity(0.85), in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
        }
    }
}

// MARK: - HUD

/// The strip: glyph at the left edge, the tool at the right, nothing under
/// the camera in between.
struct PermissionStrip: View {
    let action: String

    var body: some View {
        HStack(spacing: 0) {
            ChamberGlyph(motion: .waiting, size: DroppyLiveActivityMetrics.iconSize, isAnimating: false)
            Spacer(minLength: 0)
            Text(verbatim: action)
                .font(.system(size: DroppyLiveActivityMetrics.labelFontSize, weight: .semibold))
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
        }
        .frame(maxWidth: .infinity)
    }
}

struct PermissionCard: View {
    let permission: PendingPermission
    let session: SessionInfo?
    let onAllow: @MainActor () -> Void
    let onReject: @MainActor () -> Void
    let onOpen: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.xsm) {
            // The card is 344pt wide on a notch and 208 on an island: the tool
            // never truncates, the session title does.
            HStack(spacing: DroppySpacing.xsm) {
                Text(verbatim: permission.action)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                    .layoutPriority(1)
                Text(verbatim: session?.title ?? "")
                    .font(.system(size: 11))
                    .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            Text(permission.resources.joined(separator: "\n"))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                .lineLimit(2)
                .truncationMode(.middle)
            HStack(spacing: DroppySpacing.xsm) {
                Button("Allow once", action: onAllow)
                    .buttonStyle(DroppyAccentButtonStyle(color: .orange, size: .small))
                Button("Reject", action: onReject)
                    .buttonStyle(DroppyQuietButtonStyle(size: .small, destructive: true))
                Spacer(minLength: 0)
                Button("Open", action: onOpen)
                    .buttonStyle(DroppyQuietButtonStyle(size: .small))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A turn's notice in the strip: OpenChamber's cube at the left edge, what
/// happened at the right, nothing under the camera.
struct NoticeStrip: View {
    let motion: ChamberGlyphMotion
    let symbol: String
    let label: String
    let tint: Color

    var body: some View {
        HStack(spacing: 0) {
            ChamberGlyph(motion: motion, size: DroppyLiveActivityMetrics.iconSize, isAnimating: false)
            Spacer(minLength: 0)
            HStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: DroppyLiveActivityMetrics.labelFontSize - 2, weight: .semibold))
                Text(verbatim: label).font(.system(size: DroppyLiveActivityMetrics.labelFontSize, weight: .semibold))
            }
            .foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity)
    }
}

/// The card a notice grows into: who, what it said, and the way back to it.
struct NoticeCard: View {
    enum DetailStyle { case quote, code, plain }

    let title: String
    let meta: String?
    let detail: String?
    let detailStyle: DetailStyle
    let action: String
    var accent = false
    let onAction: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.xsm) {
            Text(verbatim: title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                .lineLimit(detailStyle == .plain ? 2 : 1)
            if let detail {
                switch detailStyle {
                case .quote:
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, DroppySpacing.sm)
                        .overlay(alignment: .leading) {
                            Capsule().fill(AdaptiveColors.notchSurfacePrimaryText.opacity(0.14)).frame(width: 2)
                        }
                case .code:
                    Text(detail)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                case .plain:
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: DroppySpacing.xsm) {
                if accent {
                    Button(action, action: onAction)
                        .buttonStyle(DroppyAccentButtonStyle(color: .orange, size: .small))
                    Spacer(minLength: 0)
                } else {
                    if let meta {
                        Text(verbatim: meta)
                            .font(.system(size: 11))
                            .monospacedDigit()
                            .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Button(action, action: onAction)
                        .buttonStyle(DroppyQuietButtonStyle(size: .small))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct UsageStrip: View {
    let provider: String
    let percent: Double
    let label: String

    var body: some View {
        HStack(spacing: 0) {
            ProviderIcon(provider: provider, name: label, size: DroppyLiveActivityMetrics.iconSize + 2)
            Spacer(minLength: 0)
            Text(verbatim: "\(Int(percent))%")
                .font(.system(size: DroppyLiveActivityMetrics.labelFontSize, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Formatting.usageColor(percent))
                .accessibilityLabel(label)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Menu bar

struct MenuBarSummary: View {
    @ObservedObject var droplet: OpenchamberDroplet

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.xs) {
            Text(OpenchamberDroplet.summary(of: droplet.phase, now: Date()))
                .font(.system(size: 13, weight: .semibold))
            ForEach(droplet.state.busySessionIDs.prefix(5), id: \.self) { id in
                Button(droplet.state.sessions[id]?.title ?? "Session") { droplet.openSession(id) }
                    .buttonStyle(.borderless)
                    .font(.system(size: 13))
            }
            if let (provider, window) = droplet.usage.compactMap({ p in p.tightest.map { (p, $0) } }).first {
                Text(verbatim: "\(provider.name) \(Formatting.windowLabel(window, in: provider)): \(window.usedPercent.map { "\(Int($0))%" } ?? "–")")
                    .font(.system(size: 12))
                    .foregroundStyle(AdaptiveColors.secondaryTextAuto)
            }
        }
        .foregroundStyle(AdaptiveColors.primaryTextAuto)
        .padding(.vertical, DroppySpacing.xs)
        .frame(minWidth: 200, alignment: .leading)
    }
}

// MARK: - Settings pane

struct OpenchamberSettings: View {
    @ObservedObject var droplet: OpenchamberDroplet

    var body: some View {
        DropletSettingsPane {
            DropletSettingsSection {
                settingsSectionHeader("Servers")
            } content: {
                DropletSettingsCard {
                    ForEach(droplet.servers) { server in
                        DropletControlRow(title: server.label, infoTip: tip(for: server)) {
                            DropletValuePill(text: status(of: droplet.serverStates[server.id]?.connection ?? .connecting))
                        }
                    }
                    DropletControlRow(
                        title: droplet.servers.isEmpty ? "No servers found" : "From OpenChamber Desktop",
                        infoTip: "The servers and tokens OpenChamber Desktop already uses, read from ~/.config/openchamber/settings.json. A host is reached at its own address first and through OpenChamber's relay when that does not answer."
                    ) {
                        Button("Reload") { droplet.reloadServers() }
                            .buttonStyle(.bordered)
                    }
                }
            }

            DropletSettingsSection {
                settingsSectionHeader("Notch")
            } content: {
                DropletSettingsCard {
                    DropletToggleRow(
                        title: "Show a card when a session needs you",
                        subtitle: "Allow once or reject from the notch. Always stays in the shelf widget.",
                        isOn: preference("permissionCards", value: droplet.showsPermissionCards)
                    )
                    DropletToggleRow(
                        title: "Show a card when a session asks a question",
                        subtitle: "Answered in OpenChamber.",
                        isOn: preference("questionCards", value: droplet.showsQuestionCards)
                    )
                    DropletToggleRow(
                        title: "Show a card when a turn ends",
                        subtitle: "The session's last message. Not while OpenChamber is in front.",
                        isOn: preference("doneCards", value: droplet.showsDoneCards)
                    )
                    DropletToggleRow(
                        title: "Show a card when a turn fails",
                        subtitle: "The error OpenCode reported.",
                        isOn: preference("failureCards", value: droplet.showsFailureCards)
                    )
                    DropletToggleRow(
                        title: "Warn about plan usage",
                        subtitle: "A short notice when a usage window passes 80% and 95%.",
                        isOn: preference("usageWarnings", value: droplet.warnsAboutUsage)
                    )
                }
            }
        }
    }

    private func status(of connection: OpenchamberDroplet.Connection) -> String {
        switch connection {
        case .noServers: return "Not set up"
        case .offline: return "Unreachable"
        case .connecting: return "Connecting"
        case .live: return "Connected"
        case .failed: return "Reconnecting"
        }
    }

    /// How the server is reached, and why the last attempt failed, behind the row's (i).
    private func tip(for server: ChamberServer) -> String {
        let address = droplet.serverStates[server.id]?.route
            ?? (server.directURLs.map(\.origin) + (server.relay == nil ? [] : ["OpenChamber's relay"])).joined(separator: ", ")
        if case let .failed(message) = droplet.serverStates[server.id]?.connection {
            return "\(address)\n\(message)"
        }
        return address
    }

    private func preference(_ key: String, value: Bool) -> Binding<Bool> {
        Binding(get: { value }, set: { droplet.setPreference($0, forKey: key) })
    }
}

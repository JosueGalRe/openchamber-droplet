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
            return (nil, sessions > 1 ? "\(sessions) · \(elapsed)" : elapsed, primary)
        case let .retrying(_, _, at): return ("arrow.clockwise", Formatting.elapsed(at.timeIntervalSince(now)), primary)
        case .finishing: return ("checkmark.circle.fill", "", .green)
        case let .waiting(count): return ("hand.raised.fill", "\(count)", .orange)
        case .failed: return ("exclamationmark.triangle.fill", "failed", .red)
        }
    }
}

// MARK: - Widget

/// The one widget: a Sessions page and a Usage page, switched from buttons in
/// the header the way Droppy's Agents switches Progress and Usage.
struct OpenchamberWidget: View {
    @ObservedObject var droplet: OpenchamberDroplet
    let context: ShelfWidgetContext

    private var state: ActivityState { droplet.state }

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            WidgetHeader(
                symbol: droplet.tab == .sessions ? "checklist" : "gauge.with.dots.needle.33percent",
                title: droplet.tab == .sessions ? "Sessions" : "Usage"
            ) {
                HStack(spacing: DroppySpacing.xsm) {
                    TabButton(droplet: droplet, tab: .sessions, symbol: "checklist", label: "Sessions", size: buttonSize)
                    TabButton(droplet: droplet, tab: .usage, symbol: "gauge.with.dots.needle.33percent", label: "Usage", size: buttonSize)
                }
            }
            if droplet.connection == .noServers {
                NoServersMessage(droplet: droplet)
                Spacer(minLength: 0)
            } else if droplet.tab == .usage {
                UsageRings(droplet: droplet, context: context)
            } else if state.pendingCount == 0, state.busySessionIDs.isEmpty {
                ServerTiles(droplet: droplet, context: context)
            } else {
                if context.isCompact { compact } else { full }
                Spacer(minLength: 0)
            }
        }
        .padding(context.contentInsets)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var buttonSize: CGFloat { context.isCompact ? 24 : 28 }

    /// The session the page follows: one in a tool call right now, else one
    /// that has done something, else the one that started last.
    private var primarySessionID: String? {
        let busy = state.busySessionIDs
        return busy.last { state.activity[$0]?.calls.last?.mark == .running }
            ?? busy.last { state.activity[$0]?.calls.isEmpty == false }
            ?? busy.last
    }

    @ViewBuilder private var full: some View {
        if let permission = state.permissions.first {
            PermissionTile(droplet: droplet, permission: permission, more: state.pendingCount - 1)
            if let id = primarySessionID { SessionRow(droplet: droplet, sessionID: id) }
        } else if let form = state.forms.first {
            FormTile(droplet: droplet, form: form, session: state.sessions[form.sessionID])
            if let id = primarySessionID { SessionRow(droplet: droplet, sessionID: id) }
        } else if let id = primarySessionID {
            SessionProgress(droplet: droplet, sessionID: id, compact: false)
            let others = state.busySessionIDs.filter { $0 != id }
            if !others.isEmpty {
                Text(verbatim: "+\(others.count) more · " + others.compactMap { state.sessions[$0]?.title }.joined(separator: ", "))
                    .font(.system(size: 11))
                    .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder private var compact: some View {
        switch droplet.phase {
        case let .waiting(count):
            BigFigure(value: "\(count)", label: count == 1 ? "needs you" : "need you", color: .orange)
            Spacer(minLength: 0)
            if let oldest = state.permissions.first {
                HStack(spacing: DroppySpacing.xsm) {
                    Button("Allow once") { droplet.reply(to: oldest, decision: "once") }
                        .buttonStyle(DroppyAccentButtonStyle(color: .orange, size: .small))
                    Spacer(minLength: 0)
                    Button { droplet.openSession(oldest.sessionID) } label: { Image(systemName: "arrow.up.forward") }
                        .buttonStyle(DroppyCircleButtonStyle(size: 24))
                        .accessibilityLabel("Open in OpenChamber")
                }
                .frame(height: 28)
            }
        case .working:
            if let id = primarySessionID {
                SessionProgress(droplet: droplet, sessionID: id, compact: true)
            }
        case .failed:
            BigFigure(value: "!", label: "a session failed", color: .red)
        case .retrying, .finishing, .idle:
            BigFigure(value: "\(state.busySessionIDs.count)", label: "active", color: AdaptiveColors.notchSurfacePrimaryText)
        }
    }
}

private struct WidgetHeader<Trailing: View>: View {
    let symbol: String
    let title: String
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: DroppySpacing.xsm) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium))
            Text(title).font(.system(size: 12, weight: .semibold))
            Spacer(minLength: 0)
            trailing
        }
        .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
    }
}

/// A page switch in the header: green while its page is showing, as in Agents.
private struct TabButton: View {
    @ObservedObject var droplet: OpenchamberDroplet
    let tab: OpenchamberDroplet.WidgetTab
    let symbol: String
    let label: String
    let size: CGFloat

    var body: some View {
        let selected = droplet.tab == tab
        Button { droplet.select(tab) } label: { Image(systemName: symbol) }
            .buttonStyle(DroppyCircleButtonStyle(
                size: size,
                destructive: false,
                solidFill: selected ? Color.green.opacity(0.22) : AdaptiveColors.notchSurfaceCardFill,
                foregroundColorOverride: selected ? .green : AdaptiveColors.notchSurfaceSecondaryText
            ))
            .help(label)
            .accessibilityLabel(label)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Nothing running: one tile per server and how it is doing, where Agents
/// shows a tile per agent.
private struct ServerTiles: View {
    @ObservedObject var droplet: OpenchamberDroplet
    let context: ShelfWidgetContext

    var body: some View {
        HStack(spacing: context.isCompact ? DroppySpacing.md : DroppySpacing.xl) {
            ForEach(droplet.servers.prefix(context.isCompact ? 2 : 4)) { server in
                VStack(spacing: DroppySpacing.xsm) {
                    ChamberGlyph(motion: .still, size: context.isCompact ? 22 : 28)
                        .frame(width: context.isCompact ? 46 : 58, height: context.isCompact ? 46 : 58)
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

private struct BigFigure: View {
    let value: String
    let label: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: value)
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
        }
    }
}

/// The oldest request, with everything needed to decide on it in view: the
/// tool, the session, and the full command.
private struct PermissionTile: View {
    let droplet: OpenchamberDroplet
    let permission: PendingPermission
    let more: Int

    var body: some View {
        let session = droplet.state.sessions[permission.sessionID]
        VStack(alignment: .leading, spacing: DroppySpacing.xsm) {
            HStack(spacing: DroppySpacing.xsm) {
                Circle().fill(.orange).frame(width: 6, height: 6)
                Text(permission.action)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                Text([droplet.serverLabel(forSession: permission.sessionID), session?.project, session?.title].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11))
                    .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                    .lineLimit(1)
                Spacer(minLength: DroppySpacing.sm)
                if more > 0 {
                    Text(verbatim: "+\(more)")
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                }
            }
            if !permission.resources.isEmpty {
                Text(permission.resources.joined(separator: "\n"))
                    .font(.system(size: 11, design: .monospaced))
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
                Button("Reject") { droplet.reply(to: permission, decision: "reject") }
                    .buttonStyle(DroppyQuietButtonStyle(size: .small, destructive: true))
                Button { droplet.openSession(permission.sessionID) } label: { Image(systemName: "arrow.up.forward") }
                    .buttonStyle(DroppyCircleButtonStyle(size: 24))
                    .accessibilityLabel("Open in OpenChamber")
            }
        }
        .padding(DroppySpacing.sm)
        .background(AdaptiveColors.notchSurfaceCardFill, in: RoundedRectangle(cornerRadius: DroppyRadius.medium, style: .continuous))
    }
}

/// Forms can hold any number of fields, so they are answered in OpenChamber.
private struct FormTile: View {
    let droplet: OpenchamberDroplet
    let form: PendingForm
    let session: SessionInfo?

    var body: some View {
        HStack(spacing: DroppySpacing.sm) {
            Circle().fill(.orange).frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 1) {
                Text(form.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                    .lineLimit(1)
                Text(session.map { "\($0.project) · \($0.title)" } ?? "A session asks")
                    .font(.system(size: 11))
                    .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: DroppySpacing.sm)
            Button("Answer") { droplet.openSession(form.sessionID) }
                .buttonStyle(DroppyAccentButtonStyle(color: .orange, size: .small))
        }
        .padding(DroppySpacing.sm)
        .background(AdaptiveColors.notchSurfaceCardFill, in: RoundedRectangle(cornerRadius: DroppyRadius.medium, style: .continuous))
    }
}

/// One session the way Agents shows one: who is working and on what, the last
/// tool calls with their outcome, and what the assistant last said.
private struct SessionProgress: View {
    let droplet: OpenchamberDroplet
    let sessionID: String
    let compact: Bool

    var body: some View {
        let session = droplet.state.sessions[sessionID]
        let activity = droplet.state.activity[sessionID] ?? SessionActivity()
        let provider = session?.providerID ?? ""
        let accent = ProviderStyle.accent(provider)
        let title = session?.title ?? "Session"
        HStack(alignment: .top, spacing: DroppySpacing.md) {
            VStack(alignment: .leading, spacing: compact ? 4 : 6) {
                HStack(spacing: DroppySpacing.xsm) {
                    AgentMark(provider: provider, size: compact ? 18 : 22)
                    Text(ProviderStyle.displayName(provider))
                        .font(.system(size: compact ? 13 : 15, weight: .bold))
                        .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                        .layoutPriority(1)
                    if !compact {
                        Circle().fill(accent).frame(width: 6, height: 6)
                        Text(title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(accent)
                            .lineLimit(1)
                    }
                    Spacer(minLength: DroppySpacing.sm)
                    if let since = activity.busySince {
                        TimelineView(.periodic(from: .now, by: 1)) { timeline in
                            Text(verbatim: Formatting.elapsed(timeline.date.timeIntervalSince(since)))
                                .font(.system(size: 12, weight: .medium))
                                .monospacedDigit()
                                .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                        }
                    }
                }
                if compact {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(accent)
                        .lineLimit(1)
                }
                ForEach(activity.calls.suffix(compact ? 2 : 3), id: \.id) { call in
                    CallRow(call: call, accent: accent, compact: compact)
                }
            }
            if !compact, let text = activity.lastText {
                // A fixed width, so the title truncates rather than the message,
                // which grows down to four lines.
                Text(text)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 150, alignment: .leading)
                    .padding(DroppySpacing.md)
                    .background(AdaptiveColors.notchSurfaceCardFill, in: RoundedRectangle(cornerRadius: DroppyRadius.large, style: .continuous))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { droplet.openSession(sessionID) }
        .accessibilityAddTraits(.isButton)
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

/// `✓ read  formatters.js`, `▶ bash  swift test`, `✗ edit  Views.swift`.
private struct CallRow: View {
    let call: ToolCall
    let accent: Color
    let compact: Bool

    var body: some View {
        HStack(spacing: DroppySpacing.xsm) {
            Image(systemName: symbol)
                .font(.system(size: compact ? 10 : 11, weight: .bold))
                .foregroundStyle(call.mark == .failed ? Color.red : accent)
                .frame(width: 14)
            Text(call.name)
                .font(.system(size: compact ? 12 : 13))
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                .lineLimit(1)
                .layoutPriority(1)
            if let target = call.target {
                Text(target)
                    .font(.system(size: compact ? 11 : 12))
                    .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private var symbol: String {
        switch call.mark {
        case .running: return "play.fill"
        case .succeeded: return "checkmark"
        case .failed: return "xmark"
        }
    }
}

private struct SessionRow: View {
    let droplet: OpenchamberDroplet
    let sessionID: String

    var body: some View {
        let session = droplet.state.sessions[sessionID]
        let activity = droplet.state.activity[sessionID] ?? SessionActivity()
        HStack(alignment: .center, spacing: DroppySpacing.sm) {
            VStack(alignment: .leading, spacing: 1) {
                Text(session?.title ?? "Session")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                    .lineLimit(1)
                Text(detail(server: droplet.serverLabel(forSession: sessionID), session: session, call: activity.currentCall))
                    .font(.system(size: 11))
                    .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: DroppySpacing.md)
            VStack(alignment: .trailing, spacing: 3) {
                if let since = activity.busySince {
                    TimelineView(.periodic(from: .now, by: 1)) { timeline in
                        Text(verbatim: Formatting.elapsed(timeline.date.timeIntervalSince(since)))
                            .font(.system(size: 12, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                    }
                }
                CallStrip(calls: activity.calls)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { droplet.openSession(sessionID) }
        .accessibilityAddTraits(.isButton)
    }

    private func detail(server: String?, session: SessionInfo?, call: ToolCall?) -> String {
        let action = call.map { [$0.name, $0.target].compactMap { $0 }.joined(separator: " ") }
        return [server, session?.project, action].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// The last calls of a session, oldest first: white while running, green
/// done, red failed. Enough to see a run going wrong without opening it.
private struct CallStrip: View {
    let calls: [ToolCall]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(calls, id: \.id) { call in
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(color(call.mark))
                    .frame(width: 3, height: 9)
            }
        }
        .accessibilityHidden(true)
    }

    private func color(_ mark: ToolMark) -> Color {
        switch mark {
        case .running: return AdaptiveColors.notchSurfaceSecondaryText
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
        let providers = Array(droplet.usage.prefix(capacity))
        Group {
            if providers.isEmpty {
                WidgetMessage(text: droplet.connection == .live ? "No plan usage from OpenChamber yet." : "OpenChamber isn't reachable.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                HStack(alignment: .top, spacing: context.isCompact ? DroppySpacing.md : DroppySpacing.xl) {
                    ForEach(providers) { provider in
                        RingTile(droplet: droplet, provider: provider, diameter: context.isCompact ? 50 : 62)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            if !context.isPreview { droplet.refreshUsage(ifOlderThan: 60) }
        }
    }

    private var capacity: Int {
        max(1, Int(context.availableSize.width / (context.isCompact ? 84 : 100)))
    }
}

private struct RingTile: View {
    let droplet: OpenchamberDroplet
    let provider: ProviderQuota
    let diameter: CGFloat
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
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                    .lineLimit(1)
                Text(verbatim: "\(Int(left.rounded()))% left")
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(provider.name), \(Int(left.rounded())) percent left")
        .popover(isPresented: $showsDetail, arrowEdge: .bottom) {
            UsageDetail(droplet: droplet, provider: provider)
        }
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
                            Text(verbatim: window.usedPercent.map { "\(Int($0.rounded()))%" } ?? "–")
                                .font(.system(size: 14, weight: .semibold))
                                .monospacedDigit()
                        }
                        UsageBar(percent: window.usedPercent, color: ProviderStyle.color(provider.provider))
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

    static func key(_ provider: String) -> String? {
        let id = provider.lowercased()
        if id.contains("claude") || id.contains("anthropic") { return "claude" }
        if id.contains("codex") || id.contains("openai") || id.contains("chatgpt") { return "codex" }
        if id.contains("cursor") { return "cursor" }
        if id.contains("opencode") { return "opencode" }
        if id.contains("antigravity") { return "antigravity" }
        return nil
    }

    /// What Agents calls the agent: the product, not the model id.
    static func displayName(_ provider: String) -> String {
        switch provider.lowercased() {
        case "": return "OpenChamber"
        case "anthropic", "claude": return "Claude"
        case "openai": return "OpenAI"
        case "codex": return "Codex"
        case "opencode", "opencode-go": return "OpenCode"
        case "google", "google-vertex": return "Gemini"
        case "github-copilot": return "Copilot"
        default: return provider.prefix(1).uppercased() + provider.dropFirst()
        }
    }

    /// The session title's colour: the brand's, or OpenChamber's orange.
    static func accent(_ provider: String) -> Color {
        key(provider) == nil || key(provider) == "opencode" || key(provider) == "cursor" ? .orange : color(provider)
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
                        infoTip: "The servers and tokens OpenChamber Desktop already uses, read from ~/.config/openchamber/settings.json. Relay-only hosts are left out."
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

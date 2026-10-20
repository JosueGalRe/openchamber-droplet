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
                    Image(systemName: symbol).font(.system(size: DroppyLiveActivityMetrics.labelFontSize - 2, weight: .semibold))
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
        case .finishing: return ("checkmark", "done", primary)
        case let .waiting(count): return ("hand.raised.fill", "\(count)", .orange)
        case .failed: return ("exclamationmark.triangle.fill", "failed", .red)
        }
    }
}

// MARK: - Sessions widget

struct SessionsWidget: View {
    @ObservedObject var droplet: OpenchamberDroplet
    let context: ShelfWidgetContext

    private var state: ActivityState { droplet.state }

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            WidgetHeader(title: "OpenChamber") {
                if !context.isCompact, !state.busySessionIDs.isEmpty {
                    Text(verbatim: "\(state.busySessionIDs.count) active")
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                }
            }
            switch droplet.connection {
            case .noServers:
                NoServersMessage(droplet: droplet)
            case .offline:
                WidgetMessage(text: "OpenChamber isn't running.")
            case let .failed(message):
                WidgetMessage(text: "Can't reach OpenChamber. \(message)")
            case .connecting, .live:
                if context.isCompact { compact } else { full }
            }
            Spacer(minLength: 0)
        }
        .padding(context.contentInsets)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private var full: some View {
        if let permission = state.permissions.first {
            PermissionTile(droplet: droplet, permission: permission, more: state.pendingCount - 1)
        } else if let form = state.forms.first {
            FormTile(droplet: droplet, form: form, session: state.sessions[form.sessionID])
        }
        let rows = state.busySessionIDs.prefix(state.pendingCount > 0 ? 1 : 3)
        if rows.isEmpty, state.pendingCount == 0 {
            WidgetMessage(text: "No sessions running.")
        }
        ForEach(Array(rows), id: \.self) { id in
            SessionRow(droplet: droplet, sessionID: id)
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
        case let .working(sessions, since):
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                BigFigure(
                    value: Formatting.elapsed(timeline.date.timeIntervalSince(since)),
                    label: sessions == 1 ? "working" : "\(sessions) working",
                    color: AdaptiveColors.notchSurfacePrimaryText
                )
            }
        case .failed:
            BigFigure(value: "!", label: "a session failed", color: .red)
        case .retrying, .finishing, .idle:
            BigFigure(value: "\(state.busySessionIDs.count)", label: "active", color: AdaptiveColors.notchSurfacePrimaryText)
        }
    }
}

private struct WidgetHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: DroppySpacing.xsm) {
            ChamberGlyph(motion: .still, size: 12)
            Text(title).font(.system(size: 12, weight: .semibold))
            Spacer(minLength: 0)
            trailing
        }
        .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
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

// MARK: - Usage widget

struct UsageWidget: View {
    @ObservedObject var droplet: OpenchamberDroplet
    let context: ShelfWidgetContext

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            WidgetHeader(title: "Usage") { EmptyView() }
            if droplet.usage.isEmpty {
                WidgetMessage(text: droplet.connection == .noServers
                    ? "OpenChamber Desktop isn't set up on this Mac yet."
                    : "No plan usage from OpenChamber yet.")
            } else {
                TimelineView(.periodic(from: .now, by: 60)) { timeline in
                    if context.isCompact { compact(now: timeline.date) } else { full(now: timeline.date) }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(context.contentInsets)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            if !context.isPreview { droplet.refreshUsage(ifOlderThan: 60) }
        }
    }

    private func full(now: Date) -> some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            ForEach(droplet.usage.prefix(2)) { provider in
                VStack(alignment: .leading, spacing: DroppySpacing.xs) {
                    HStack(spacing: DroppySpacing.xsm) {
                        Text(provider.name)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                        if let plan = provider.plan {
                            Text(plan)
                                .font(.system(size: 11))
                                .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                        }
                    }
                    ForEach(provider.windows.prefix(2)) { window in
                        HStack(spacing: DroppySpacing.sm) {
                            Text(window.name)
                                .frame(width: 24, alignment: .leading)
                                .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                            UsageBar(percent: window.usedPercent)
                            Text(verbatim: window.usedPercent.map { "\(Int($0))%" } ?? "–")
                                .frame(width: 34, alignment: .trailing)
                                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                            Text(verbatim: Formatting.countdown(to: window.resetAt, from: now))
                                .frame(width: 50, alignment: .trailing)
                                .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                        }
                        .font(.system(size: 11))
                        .monospacedDigit()
                    }
                }
            }
        }
    }

    /// The window closest to running out as a ring, and the next two as lines.
    @ViewBuilder private func compact(now: Date) -> some View {
        let windows = droplet.usage
            .flatMap { provider in provider.windows.map { (provider: provider, window: $0) } }
            .sorted { ($0.window.usedPercent ?? 0) > ($1.window.usedPercent ?? 0) }
        if let top = windows.first {
            VStack(alignment: .leading, spacing: DroppySpacing.sm) {
                HStack(spacing: DroppySpacing.md) {
                    UsageRing(percent: top.window.usedPercent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: "\(top.provider.name) · \(top.window.name)")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                            .lineLimit(1)
                        Text(verbatim: "resets in \(Formatting.countdown(to: top.window.resetAt, from: now))")
                            .font(.system(size: 11))
                            .monospacedDigit()
                            .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                    }
                }
                ForEach(windows.dropFirst().prefix(2), id: \.window.id) { entry in
                    HStack {
                        Text(verbatim: "\(entry.provider.name) \(entry.window.name)")
                            .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                            .lineLimit(1)
                        Spacer(minLength: DroppySpacing.md)
                        Text(verbatim: entry.window.usedPercent.map { "\(Int($0))%" } ?? "–")
                            .foregroundStyle(Formatting.usageColor(entry.window.usedPercent))
                    }
                    .font(.system(size: 11))
                    .monospacedDigit()
                }
            }
        }
    }
}

private struct UsageBar: View {
    let percent: Double?

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(AdaptiveColors.notchSurfacePrimaryText.opacity(0.12))
                Capsule()
                    .fill(Formatting.usageColor(percent))
                    .frame(width: proxy.size.width * min(1, max(0, (percent ?? 0) / 100)))
            }
        }
        .frame(height: 5)
    }
}

private struct UsageRing: View {
    let percent: Double?

    var body: some View {
        ZStack {
            Circle().stroke(AdaptiveColors.notchSurfacePrimaryText.opacity(0.12), lineWidth: 4)
            Circle()
                .trim(from: 0, to: min(1, max(0, (percent ?? 0) / 100)))
                .stroke(Formatting.usageColor(percent), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(verbatim: percent.map { "\(Int($0))%" } ?? "–")
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
        }
        .frame(width: 44, height: 44)
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
    let percent: Double
    let label: String

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .font(.system(size: DroppyLiveActivityMetrics.iconSize, weight: .semibold))
                .foregroundStyle(Formatting.usageColor(percent))
            Spacer(minLength: 0)
            Text(verbatim: "\(Int(percent))%")
                .font(.system(size: DroppyLiveActivityMetrics.labelFontSize, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
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
                Text(verbatim: "\(provider.name) \(window.name): \(window.usedPercent.map { "\(Int($0))%" } ?? "–")")
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

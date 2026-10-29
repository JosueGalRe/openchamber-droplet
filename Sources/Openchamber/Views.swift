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
import UniformTypeIdentifiers

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

    /// Who is doing the work: `Opus 5.5 xhigh · Build · devbox`. The model's id
    /// stands in when the server's catalog has no name for it, and the
    /// provider's name until the session's model is known.
    static func runner(of session: SessionInfo?, model name: String? = nil, server: String?) -> String {
        let base = name ?? session?.modelID.map { ($0 as NSString).lastPathComponent }
            ?? ProviderStyle.displayName(session?.providerID ?? "")
        let model = [base, session?.variant.flatMap { $0 == "default" ? nil : $0 }].compactMap { $0 }.joined(separator: " ")
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

    /// `Runs out in 2h 10m` within a day, `Runs out Thu` after that.
    static func runsOut(_ date: Date, now: Date) -> String {
        guard date.timeIntervalSince(now) >= 60 else { return "Ran out" }
        guard date.timeIntervalSince(now) >= 86_400 else { return "Runs out in \(countdown(to: date, from: now))" }
        return "Runs out \(date.formatted(.dateTime.weekday(.abbreviated)))"
    }

    /// `1h 42m`, `42m`: time spent, where `elapsed` is time on a clock.
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }

    /// `a.swift, b.swift and c.swift`.
    static func list(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
    }

    /// A message's first sentence, its markdown dropped, short enough for one
    /// row; nil for nothing to say.
    static func headline(from text: String?, limit: Int = 70) -> String? {
        guard let text else { return nil }
        let plain = String(inlineMarkdown(text).characters)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"“”'")))
        guard !plain.isEmpty else { return nil }
        let line = plain.split(whereSeparator: \.isNewline).first.map(String.init) ?? plain
        let sentence = line.range(of: #"[.!?](\s|$)"#, options: .regularExpression).map { String(line[..<$0.lowerBound]) } ?? line
        // It follows the title in a row: "Fix the test — switched to UTC". An
        // acronym keeps its capitals.
        let first = sentence.dropFirst().first?.isLowercase == true ? sentence.prefix(1).lowercased() + sentence.dropFirst() : sentence
        return first.count > limit ? String(first.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…" : first
    }

    /// A path inside the session's project without the project's folder, and
    /// `~` for the home folder; anything else as it is.
    static func shortPath(_ text: String, in directory: String?) -> String {
        if let directory, !directory.isEmpty, text.hasPrefix(directory + "/") { return String(text.dropFirst(directory.count + 1)) }
        let home = NSHomeDirectory()
        return text.hasPrefix(home + "/") ? "~" + text.dropFirst(home.count) : text
    }

    /// `870k`, `1M`, `1.5M`: a token count at a glance.
    static func tokens(_ count: Int) -> String {
        let thousands = Int((Double(count) / 1_000).rounded())
        if thousands < 1_000 { return count < 1_000 ? "\(count)" : "\(thousands)k" }
        let millions = (Double(count) / 100_000).rounded() / 10
        return millions == millions.rounded() ? "\(Int(millions))M" : "\(millions)M"
    }

    /// The end of text still being written, where the new words are.
    static func tail(_ text: String, limit: Int = 160) -> String {
        guard text.count > limit else { return text }
        let end = text.suffix(limit)
        return "…" + (end.firstIndex(of: " ").map { end[end.index(after: $0)...] } ?? end)
    }

    /// An agent's words with their inline markdown drawn: `code` in mono,
    /// **bold**, a link as its text. Nothing in the notch follows a link.
    static func inlineMarkdown(_ text: String) -> AttributedString {
        guard var attributed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
            return AttributedString(text)
        }
        for range in attributed.runs.filter({ $0.link != nil }).map(\.range) { attributed[range].link = nil }
        return attributed
    }

    /// What a permission asks to do, as a verb: `run`, `edit`, `fetch`.
    static func permissionVerb(_ action: String) -> String {
        switch action {
        case "bash", "shell": return "run"
        case "webfetch": return "fetch"
        default: return action.replacingOccurrences(of: "_", with: " ")
        }
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
        // The agent's own mascot while it works or waits, as Agents shows it;
        // the cube for everything else, whose ring tells retry, done and failed.
        let kind = { (provider: String?) in provider.flatMap(AgentMascot.Kind.init(provider:)) }
        let (mascot, mood): (AgentMascot.Kind?, AgentMascot.Mood) = switch droplet.phase {
        case .working: (kind(droplet.leadProvider), .working)
        case .waiting: (kind(droplet.leadProvider), .still)
        case .finishing: (kind(droplet.lastFinishedProvider), .done)
        case let .failed(id): (kind(droplet.state.sessions[id]?.providerID), .failed)
        case .idle, .retrying: (nil, .still)
        }
        Group {
            if let mascot {
                AgentMascot(kind: mascot, size: size, isAnimating: droplet.seat.isPresented, mood: mood)
            } else {
                ChamberGlyph(motion: droplet.glyphMotion, size: size, isAnimating: droplet.seat.isPresented)
            }
        }
        .overlay {
            // A session let run: a yellow ring that empties as its time runs out.
            if let run = droplet.autoRuns.values.min(by: { $0.until < $1.until }) {
                AutoRunRing(until: run.until).padding(-3)
            }
        }
        .id("\(mascot?.rawValue ?? "cube").\(mood)")
        .transition(DroppyTransition.compactContent)
    }
}

/// What is left of a session's run without asking, as a ring.
struct AutoRunRing: View {
    let until: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let left = max(0, min(1, until.timeIntervalSince(timeline.date) / OpenchamberDroplet.autoRunLength))
            Circle()
                .trim(from: 0, to: left)
                .stroke(Color.yellow, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .accessibilityHidden(true)
    }
}

/// `auto 11:32`: a session let run, and for how much longer. A click ends it.
struct AutoRunBadge: View {
    @ObservedObject var droplet: OpenchamberDroplet
    let run: OpenchamberDroplet.AutoRun

    var body: some View {
        Button { droplet.endAutoRun(run) } label: {
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                Text(verbatim: "auto \(Formatting.elapsed(run.until.timeIntervalSince(timeline.date)))")
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.yellow)
            }
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("Approving everything until then. Click to ask again.")
    }
}

struct CompactLabel: View {
    @ObservedObject var droplet: OpenchamberDroplet

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let (symbol, text, color) = label(at: timeline.date)
            // The wing gives the label 48 points: dots and a time fit while the
            // turn is under ten minutes and two run. Past that the dots give way
            // to a count (working, they are all white and say only how many),
            // then the time to the dots. The count's size is explicit:
            // ViewThatFits measures text unscaled.
            ViewThatFits(in: .horizontal) {
                row(symbol: symbol, text: text, dots: dots)
                if let dots {
                    if !text.isEmpty {
                        row(symbol: symbol, text: "\(dots.count)\u{2009}·\u{2009}\(text)", dots: nil, size: DroppyLiveActivityMetrics.labelFontSize - 2)
                    }
                    row(symbol: symbol, text: "", dots: dots)
                }
            }
            .foregroundStyle(color)
            .lineLimit(1)
            .id(kind)
            .transition(DroppyTransition.compactContent)
        }
    }

    private func row(symbol: String?, text: String, dots: [Bool]?, size: CGFloat = DroppyLiveActivityMetrics.labelFontSize) -> some View {
        HStack(spacing: 3) {
            if let dots {
                // One per session, orange for one that waits on you: who needs
                // you reads without a number.
                HStack(spacing: 3) {
                    ForEach(dots.indices, id: \.self) { index in
                        Circle()
                            .fill(dots[index] ? Color.orange : AdaptiveColors.notchSurfacePrimaryText)
                            .frame(width: 5, height: 5)
                    }
                }
                .padding(.trailing, 2)
            }
            if let symbol {
                // A lone symbol (the green check) stands in for a word, so it is drawn larger.
                Image(systemName: symbol).font(.system(size: DroppyLiveActivityMetrics.labelFontSize + (text.isEmpty ? 3 : -2), weight: .semibold))
            }
            Text(verbatim: text)
                .font(.system(size: size, weight: .medium, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.75)
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

    /// Dots while two to four sessions work or wait, else the count says it.
    private var dots: [Bool]? {
        switch droplet.phase {
        case .working, .waiting: return droplet.sessionDots
        default: return nil
        }
    }

    /// The wing is 70pt at rest, so every label fits in about eight characters.
    private func label(at now: Date) -> (symbol: String?, text: String, color: Color) {
        let primary = AdaptiveColors.notchSurfacePrimaryText
        switch droplet.phase {
        case .idle: return (nil, "", primary)
        case let .working(sessions, since):
            let elapsed = Formatting.elapsed(now.timeIntervalSince(since))
            return (nil, sessions > 1 && dots == nil ? "\(sessions)\u{2009}·\u{2009}\(elapsed)" : elapsed, primary)
        case let .retrying(_, _, at): return ("arrow.clockwise", Formatting.elapsed(at.timeIntervalSince(now)), primary)
        case .finishing: return ("checkmark.circle.fill", "", .green)
        case let .waiting(count): return ("hand.raised.fill", dots == nil ? "\(count)" : "", .orange)
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
            WidgetHeader(status: status) {
                if droplet.presenting {
                    Button { droplet.setPresenting(false) } label: {
                        Image(systemName: "eye.slash").font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(DroppyCircleButtonStyle(size: 20))
                    .help("Commands and messages are hidden. Click to show them.")
                    .accessibilityLabel("Show commands and messages")
                }
                PageSwitch(droplet: droplet)
            }
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
            return HeaderStatus(symbol: "calendar", title: "Today")
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
            let others = busy.filter { $0 != permission.sessionID }
            if !context.isNarrow, let other = others.last {
                Spacer(minLength: DroppySpacing.sm)
                SessionLine(droplet: droplet, sessionID: other, oneLine: true, more: others.count - 1) { droplet.openSession(other) }
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
            TodayPage(droplet: droplet, context: context)
        }
    }
}

/// One session, given the room: its title, what it is doing in words, its
/// last words, and along the bottom the run of steps and who is doing it.
private struct SessionHero: View {
    @ObservedObject var droplet: OpenchamberDroplet
    let sessionID: String
    let compact: Bool
    /// Lines of the assistant's last words; a hero sharing the page gets fewer.
    var lastTextLines = 2
    /// Set when the hero was opened from the list: a tap folds it back, and
    /// OpenChamber opens only from its button.
    var collapse: (() -> Void)? = nil
    @State private var showsDetail = false
    @State private var dropTargeted = false
    /// The last words' height as the row shows them and as they would be whole.
    @State private var shownWordsHeight: CGFloat = 0
    @State private var wholeWordsHeight: CGFloat = 0

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
                if let run = droplet.autoRuns[sessionID] {
                    AutoRunBadge(droplet: droplet, run: run)
                }
                if !compact {
                    ElapsedText(since: activity.busySince, size: 13)
                    Button { droplet.focus(sessionID) } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 9, weight: .semibold))
                    }
                    .buttonStyle(DroppyCircleButtonStyle(size: 20))
                    .help("Show the whole session")
                    .accessibilityLabel("Show the whole session")
                }
                Button { droplet.openSession(sessionID) } label: {
                    Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(DroppyCircleButtonStyle(size: 20))
                .help("Open in OpenChamber")
                .accessibilityLabel("Open in OpenChamber")
            }
            // What it is doing, its last words and the run of steps: the part
            // with more to read, so the card hangs under all of it and never
            // over the model's row.
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: DroppySpacing.sm) {
                        NarrationText(narration: failed ? nil : activity.narration, failed: failed, size: compact ? 12 : 13,
                                      stuck: droplet.stuck[sessionID], hidesObject: droplet.presenting)
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

                    if !compact, lastTextLines > 0, droplet.presenting, activity.lastText != nil || activity.liveText != nil {
                        HiddenWhilePresenting().padding(.bottom, DroppySpacing.sm)
                    } else if !compact, lastTextLines > 0, let text = activity.liveText.flatMap({ $0.isEmpty ? nil : $0 }) ?? activity.lastText {
                        AgentWords(text: text, live: activity.liveText?.isEmpty == false)
                            .font(.system(size: 12))
                            .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                            .lineLimit(lastTextLines)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { shownWordsHeight = $0 }
                            .background(alignment: .topLeading) {
                                // The same words unlimited and unseen: taller means the row cuts them.
                                AgentWords(text: text, live: false)
                                    .font(.system(size: 12))
                                    .fixedSize(horizontal: false, vertical: true)
                                    .hidden()
                                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { wholeWordsHeight = $0 }
                            }
                            .padding(.leading, DroppySpacing.sm)
                            .overlay(alignment: .leading) {
                                Capsule().fill(AdaptiveColors.notchSurfacePrimaryText.opacity(0.14)).frame(width: 2)
                            }
                            .padding(.bottom, DroppySpacing.sm)
                    }
                }
                HStack(spacing: DroppySpacing.sm) {
                    CallStrip(calls: Array(activity.calls.suffix(compact ? 8 : 12)))
                    // The strip shows the steps; the count only says what it has no room for.
                    if !compact, activity.steps > activity.calls.suffix(12).count {
                        Text(verbatim: "\(activity.steps) steps")
                            .font(.system(size: 12))
                            .monospacedDigit()
                            .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                    }
                    if !compact, let share = droplet.contextShare(forSession: sessionID) {
                        ContextMeter(share: share)
                    }
                    Spacer(minLength: DroppySpacing.sm)
                    if compact {
                        ElapsedText(since: activity.busySince, size: 13)
                    } else {
                        Text(Formatting.runner(of: session, model: droplet.modelName(forSession: sessionID), server: droplet.serverLabel(forSession: sessionID)))
                            .font(.system(size: 12))
                            .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
            }
            .contentShape(Rectangle())
            .hoverCard(droplet: droplet, isPresented: $showsDetail) {
                SessionDetail(droplet: droplet, sessionID: sessionID,
                              showsLastText: compact || lastTextLines == 0 || wholeWordsHeight > shownWordsHeight + 1)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if let collapse { collapse() } else { droplet.openSession(sessionID) } }
        .accessibilityAddTraits(.isButton)
        .sessionDropTarget(droplet: droplet, sessionID: sessionID, isTargeted: $dropTargeted)
    }
}

extension View {
    /// Files dropped on a session go to it; the row lights up while they hover.
    func sessionDropTarget(droplet: OpenchamberDroplet, sessionID: String, isTargeted: Binding<Bool>) -> some View {
        background(
            AdaptiveColors.notchSurfaceCardFill.opacity(isTargeted.wrappedValue ? 1 : 0),
            in: RoundedRectangle(cornerRadius: DroppyRadius.small, style: .continuous)
        )
        .onDrop(of: [.fileURL], isTargeted: isTargeted) { providers in
            Task { @MainActor in
                var urls: [URL] = []
                for provider in providers {
                    let url = await withCheckedContinuation { (done: CheckedContinuation<URL?, Never>) in
                        _ = provider.loadObject(ofClass: URL.self) { url, _ in done.resume(returning: url) }
                    }
                    if let url { urls.append(url) }
                }
                droplet.dropFiles(urls, on: sessionID)
            }
            return true
        }
    }
}

/// A session in a list: title and time, then what it is doing.
private struct SessionLine: View {
    @ObservedObject var droplet: OpenchamberDroplet
    let sessionID: String
    let oneLine: Bool
    /// A narrow row keeps the server, which tells the sessions apart, and drops the project.
    var compact = false
    /// Sessions running that have no row of their own on the page.
    var more = 0
    let tap: () -> Void
    @State private var dropTargeted = false

    var body: some View {
        let session = droplet.state.sessions[sessionID]
        let activity = droplet.state.activity[sessionID] ?? SessionActivity()
        let stuck = droplet.stuck[sessionID]
        let title = Text(session?.title ?? "Session")
            .font(.system(size: 13, weight: oneLine ? .medium : .semibold))
            .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
        let doing: String? = stuck.map { droplet.presenting ? $0.headline : $0.sentence }
            ?? activity.narration.map { droplet.presenting ? $0.verb : $0.sentence }
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: DroppySpacing.sm) {
                AgentMark(provider: session?.providerID ?? "", size: 16)
                if oneLine {
                    (title + Text(verbatim: doing.map { "  " + $0 } ?? "")
                        .font(.system(size: 12))
                        .foregroundStyle(stuck == nil ? AdaptiveColors.notchSurfaceTertiaryText : Color.yellow))
                        .lineLimit(1)
                } else {
                    title.lineLimit(1)
                }
                Spacer(minLength: DroppySpacing.sm)
                if more > 0 {
                    Text(verbatim: "+\(more) more")
                        .font(.system(size: 11))
                        .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                        .fixedSize()
                }
                if let run = droplet.autoRuns[sessionID] {
                    AutoRunBadge(droplet: droplet, run: run)
                }
                ElapsedText(since: activity.busySince, size: 12)
            }
            if !oneLine {
                HStack(spacing: DroppySpacing.sm) {
                    NarrationText(narration: activity.narration, failed: false, size: 12, stuck: stuck, hidesObject: droplet.presenting)
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
        .sessionDropTarget(droplet: droplet, sessionID: sessionID, isTargeted: $dropTargeted)
    }
}

/// **Running** swift test.
private struct NarrationText: View {
    let narration: Narration?
    let failed: Bool
    let size: CGFloat
    /// Said in yellow instead, when the session looks stuck.
    var stuck: OpenchamberDroplet.StuckReason? = nil
    /// Presentation mode: the verb, not the command or the file.
    var hidesObject = false

    var body: some View {
        Group {
            if failed {
                Text("Failed").foregroundStyle(.red)
            } else if let stuck {
                Text(verbatim: hidesObject ? stuck.headline : stuck.sentence).fontWeight(.medium).foregroundStyle(.yellow)
            } else if let narration {
                // The title above is the only white: the verb leads the line by weight alone.
                Text(narration.verb).fontWeight(.medium).foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                    + Text(verbatim: hidesObject ? "" : narration.object.map { " " + $0 } ?? "").foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
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

/// What the agent said, its markdown drawn; while it is still writing, the
/// newest words and a caret that blinks.
struct AgentWords: View {
    let text: String
    let live: Bool
    /// While live, how much of the end to show; nil shows all of it.
    var tail: Int? = 160

    var body: some View {
        if live {
            TimelineView(.periodic(from: .now, by: 0.5)) { timeline in
                let on = Int(timeline.date.timeIntervalSinceReferenceDate * 2) % 2 == 0
                Text(Formatting.inlineMarkdown(tail.map { Formatting.tail(text, limit: $0) } ?? text))
                    + Text(verbatim: " ▍").foregroundStyle(on ? AdaptiveColors.notchSurfaceSecondaryText : .clear)
            }
        } else {
            Text(Formatting.inlineMarkdown(text))
        }
    }
}

/// How full the model's context window is: a short bar and the share, orange from 80%.
struct ContextMeter: View {
    let share: Double
    /// Said instead of the share, as `870k of 1M tokens`.
    var label: String? = nil
    var size: CGFloat = 12

    var body: some View {
        let full = share >= 0.8
        HStack(spacing: 5) {
            Capsule()
                .fill(AdaptiveColors.notchSurfacePrimaryText.opacity(0.14))
                .frame(width: 24, height: 4)
                .overlay(alignment: .leading) {
                    Capsule().fill(full ? Color.orange : AdaptiveColors.notchSurfaceSecondaryText).frame(width: max(4, 24 * share), height: 4)
                }
            Text(verbatim: label ?? "\(Int((share * 100).rounded()))% context")
                .font(.system(size: size))
                .monospacedDigit()
                .foregroundStyle(full ? Color.orange : AdaptiveColors.notchSurfaceTertiaryText)
        }
        .lineLimit(1)
        .fixedSize()
        .help("How full the model's context window is")
    }
}

/// The oldest request, with everything needed to decide on it in view.
private struct ApprovalView: View {
    @ObservedObject var droplet: OpenchamberDroplet
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
                request(command, size: 11)
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
                        .layoutPriority(1)
                    Spacer(minLength: DroppySpacing.sm)
                    Text([droplet.serverLabel(forSession: permission.sessionID), session?.project].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 11))
                        .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
                .onTapGesture { droplet.openSession(permission.sessionID) }
                request(command, size: 11.5)
                    .lineLimit(2)
                    .truncationMode(.middle)
                HStack(spacing: DroppySpacing.xsm) {
                    Button("Allow once") { droplet.reply(to: permission, decision: "once") }
                        .buttonStyle(DroppyAccentButtonStyle(color: .orange, size: .small))
                    Button("Always") { droplet.reply(to: permission, decision: "always") }
                        .buttonStyle(DroppyQuietButtonStyle(size: .small))
                    Button("Let it run 15m") { droplet.letRun(permission) }
                        .buttonStyle(DroppyQuietButtonStyle(size: .small))
                        .help("Allow this, and everything it asks for the next 15 minutes")
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

    /// **Run** `swift build`: the verb in the waiting orange, then what it acts on.
    private func request(_ command: String, size: CGFloat) -> Text {
        let verb = Formatting.permissionVerb(permission.action)
        let shown = droplet.presenting && !command.isEmpty ? "hidden while presenting" : command
        return Text(verbatim: verb.prefix(1).uppercased() + verb.dropFirst())
            .font(.system(size: size + 0.5, weight: .semibold))
            .foregroundStyle(.orange)
            + Text(verbatim: shown.isEmpty ? "" : "  " + shown)
            .font(.system(size: size, design: .monospaced))
            .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
    }
}

/// Forms can hold any number of fields, so they are answered in OpenChamber.
private struct FormView: View {
    @ObservedObject var droplet: OpenchamberDroplet
    let form: PendingForm
    let compact: Bool

    var body: some View {
        let session = droplet.state.sessions[form.sessionID]
        VStack(alignment: .leading, spacing: DroppySpacing.xs) {
            Text(Formatting.inlineMarkdown(form.title))
                .font(.system(size: compact ? 14 : 15, weight: .semibold))
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                .lineLimit(2)
            Text(session.map { "\($0.title) · \($0.project)" } ?? "A session asks")
                .font(.system(size: 12))
                .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                .lineLimit(1)
            Spacer(minLength: DroppySpacing.sm)
            NoticeActions(actions: OpenchamberDroplet.answers(
                to: form,
                pick: { droplet.answer(form, with: $0) },
                openChamber: { droplet.openSession(form.sessionID) }
            ))
            .frame(height: 28)
        }
    }
}

/// Nothing running: one tile per server and how it is doing, where Agents
/// shows a tile per agent: what the agents did today, and each server as a dot.
private struct TodayPage: View {
    @ObservedObject var droplet: OpenchamberDroplet
    let context: ShelfWidgetContext

    var body: some View {
        let today = droplet.today.day == OpenchamberDroplet.TodayStats.key(for: Date()) ? droplet.today : .init(day: "")
        VStack(alignment: .leading, spacing: 0) {
            if today.turns == 0 && today.answered == 0 {
                WidgetMessage(text: "Nothing has run today yet.")
            } else {
                HStack(alignment: .firstTextBaseline, spacing: context.isNarrow ? DroppySpacing.lg : 28) {
                    stat("\(today.turns)", today.turns == 1 ? "turn" : "turns")
                    stat(Formatting.duration(today.seconds), "agent time")
                    if !context.isNarrow {
                        stat("\(today.answered)", "answered")
                        if !today.lines.isEmpty {
                            VStack(alignment: .leading, spacing: 2) {
                                DiffText(diff: today.lines, size: 18)
                                label("lines")
                            }
                        }
                    }
                }
            }
            Spacer(minLength: DroppySpacing.sm)
            if !context.isNarrow {
                WeekStrip(days: droplet.days, today: today)
                Spacer(minLength: DroppySpacing.sm)
            }
            HStack(spacing: DroppySpacing.lg) {
                ForEach(droplet.servers.prefix(context.isNarrow ? 2 : 4)) { server in
                    let state = droplet.serverStates[server.id]
                    let connection = state?.connection ?? .connecting
                    HStack(spacing: 5) {
                        Circle().fill(connection.color).frame(width: 6, height: 6)
                        Text(verbatim: [server.label, connection == .live && state?.isRelayed == true ? "relay" : nil].compactMap { $0 }.joined(separator: " · "))
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                    .lineLimit(1)
                    .help(connection.label(relayed: state?.isRelayed == true))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func stat(_ value: String, _ name: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: value)
                .font(.system(size: 22, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
            label(name)
        }
    }

    private func label(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.system(size: 11.5))
            .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
    }
}

/// The last seven days of agent time, a bar each, today in white.
private struct WeekStrip: View {
    let days: [String: OpenchamberDroplet.TodayStats]
    let today: OpenchamberDroplet.TodayStats

    var body: some View {
        let now = Date()
        let week = (0..<7).map { offset -> (label: String, seconds: TimeInterval, isToday: Bool) in
            let date = Calendar.current.date(byAdding: .day, value: offset - 6, to: now) ?? now
            let key = OpenchamberDroplet.TodayStats.key(for: date)
            let seconds = offset == 6 ? today.seconds : days[key]?.seconds ?? 0
            return (offset == 6 ? "Today" : date.formatted(.dateTime.weekday(.abbreviated)), seconds, offset == 6)
        }
        let longest = max(week.map(\.seconds).max() ?? 0, 1)
        HStack(alignment: .bottom, spacing: DroppySpacing.md) {
            ForEach(week.indices, id: \.self) { index in
                let day = week[index]
                VStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(day.isToday ? AdaptiveColors.notchSurfacePrimaryText : AdaptiveColors.notchSurfacePrimaryText.opacity(0.22))
                        .frame(width: 18, height: max(3, 22 * day.seconds / longest))
                        .frame(height: 22, alignment: .bottom)
                    Text(verbatim: day.label)
                        .font(.system(size: 9.5, weight: day.isToday ? .semibold : .regular))
                        .foregroundStyle(day.isToday ? AdaptiveColors.notchSurfacePrimaryText : AdaptiveColors.notchSurfaceTertiaryText)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .help("\(day.label): \(Formatting.duration(day.seconds)) of agent time")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("This week: \(Formatting.duration(week.map(\.seconds).reduce(0, +))) of agent time")
    }
}

/// `+42 −7`, green and red, in mono: lines a turn or a day changed.
struct DiffText: View {
    let diff: TurnDiff
    var size: CGFloat = 11

    var body: some View {
        (Text(verbatim: "+\(diff.additions)").foregroundStyle(.green)
            + Text(verbatim: " −\(diff.deletions)").foregroundStyle(.red))
            .font(.system(size: size, weight: .medium, design: .monospaced))
            .lineLimit(1)
    }
}

extension OpenchamberDroplet.ServerState {
    var isRelayed: Bool { route?.hasPrefix("Through") == true }
}

extension OpenchamberDroplet.Connection {
    func label(relayed: Bool) -> String {
        switch self {
        case .noServers: return "Not set up"
        case .offline: return "Unreachable"
        case .connecting: return "Connecting"
        case .live: return relayed ? "Connected · relay" : "Connected"
        case .failed: return "Reconnecting"
        }
    }

    /// The dot the settings and the Today page show, System Settings' colours for a network.
    var color: Color {
        switch self {
        case .live: return .green
        case .connecting, .failed: return .orange
        case .offline: return .red
        case .noServers: return .secondary
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
        let line = diameter * 0.085
        let now = Date()
        let pace = provider.pace(at: now)
        Button { showsDetail.toggle() } label: {
            VStack(spacing: DroppySpacing.xs) {
                ZStack {
                    if let left = provider.percentLeft {
                        Circle().stroke(AdaptiveColors.notchSurfacePrimaryText.opacity(0.12), lineWidth: line)
                        // What is used is the gap from twelve o'clock; the arc is what is left.
                        Circle()
                            .trim(from: 1 - left / 100, to: 1)
                            .stroke(ProviderStyle.color(provider.provider), style: StrokeStyle(lineWidth: line, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        if let pace {
                            // Where the gap would end by now at an even pace: a gap past
                            // the mark is usage ahead of the clock.
                            PaceMark(length: line + 4)
                                .offset(y: -diameter / 2)
                                .rotationEffect(.degrees(pace.expected * 3.6))
                        }
                    } else {
                        // Nothing to run out of ("Unlimited", a balance): dots, no arc,
                        // spaced so a whole number of them closes the circle.
                        let around = CGFloat.pi * diameter
                        Circle().stroke(
                            AdaptiveColors.notchSurfacePrimaryText.opacity(0.32),
                            style: StrokeStyle(lineWidth: line * 0.55, lineCap: .round, dash: [0.01, around / (around / (line * 1.4)).rounded() - 0.01])
                        )
                    }
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
                if let pace {
                    Text(verbatim: pace.runsOut.map { Formatting.runsOut($0, now: now) } ?? "Lasts until reset")
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(pace.runsOut == nil ? AdaptiveColors.notchSurfaceTertiaryText : Color.orange)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            .frame(width: width)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel([provider.name, provider.caption, pace?.runsOut.map { Formatting.runsOut($0, now: now) }].compactMap { $0 }.joined(separator: ", "))
        .hoverCard(droplet: droplet, isPresented: $showsDetail) {
            UsageDetail(droplet: droplet, provider: provider)
        }
    }
}

/// A tick across a ring or a bar, white with a dark edge so it reads on any colour.
struct PaceMark: View {
    let length: CGFloat

    var body: some View {
        Capsule()
            .fill(AdaptiveColors.notchSurfacePrimaryText)
            .frame(width: 2, height: length)
            .padding(1)
            .background(Capsule().fill(Color.black.opacity(0.7)))
            .accessibilityHidden(true)
    }
}

/// A card hanging under a view while the pointer is on either. It opens a
/// beat after the pointer arrives, so sweeping across opens nothing, and
/// closes a beat after it leaves both, so crossing the gap keeps it open.
/// The shelf stays open while it shows, or leaving the shelf for the card
/// would close the shelf under it. It is the notch's black, arrow and all:
/// the system's glass let whatever was behind the shelf show through.
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
                card()
                    .environment(\.colorScheme, .dark)
                    .presentationBackground(Color.black)
                    .onHover { overCard = $0; hoverChanged() }
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

/// More of a session than the shelf has room for, without repeating its row:
/// what you asked, what it is on now (the whole command, its thinking or the
/// words it is writing), what it said last, and how far the turn and its
/// context have gone. Each block is capped so the card stays a glance.
private struct SessionDetail: View {
    @ObservedObject var droplet: OpenchamberDroplet
    let sessionID: String
    /// False when the row already shows the last message whole.
    var showsLastText = true

    var body: some View {
        let activity = droplet.state.activity[sessionID] ?? SessionActivity()
        let prompt = activity.prompt?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let directory = droplet.state.sessions[sessionID]?.directory
        let command = activity.calls.last { $0.mark == .running }.flatMap { call in
            (call.detail ?? call.target).map { (Narration(call: call).verb, Formatting.shortPath($0, in: directory)) }
        }
        let writing = activity.liveText?.nilIfEmpty
        let thinking = activity.reasoning?.nilIfEmpty
        let last = writing == nil && showsLastText ? activity.lastText : nil
        VStack(alignment: .leading, spacing: 11) {
            if droplet.presenting {
                HiddenWhilePresenting()
            } else {
                if let prompt {
                    block("You asked") {
                        Text(verbatim: String(prompt.prefix(600))).lineLimit(3)
                    }
                }
                if let command {
                    block(command.0) {
                        Text(verbatim: command.1).font(.system(size: 12, design: .monospaced)).lineLimit(6)
                    }
                } else if let writing {
                    block("Writing") {
                        AgentWords(text: writing, live: true, tail: 240).lineLimit(6)
                    }
                } else if let thinking {
                    block("Thinking") {
                        Text(Formatting.inlineMarkdown(Formatting.tail(thinking, limit: 240))).italic().lineLimit(6)
                    }
                }
                if let last {
                    block("Last message") {
                        Text(Formatting.inlineMarkdown(last)).lineLimit(5)
                    }
                }
                if prompt == nil, command == nil, writing == nil, thinking == nil, last == nil {
                    Text(verbatim: activity.narration?.sentence ?? "Nothing to show yet")
                        .font(.system(size: 12.5))
                        .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                }
            }
            footer(activity)
        }
        .padding(16)
        .frame(width: 340, alignment: .leading)
        .onAppear { droplet.lookUpPrompt(forSession: sessionID) }
    }

    private func block<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
            content()
                .font(.system(size: 12.5))
                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// `12 steps · ▬ 870k of 1M tokens   compacts soon`.
    @ViewBuilder
    private func footer(_ activity: SessionActivity) -> some View {
        let window = droplet.contextWindow(forSession: sessionID)
        let share = droplet.contextShare(forSession: sessionID)
        if activity.steps > 0 || share != nil {
            HStack(spacing: DroppySpacing.sm) {
                if activity.steps > 0 {
                    Text(verbatim: activity.steps == 1 ? "1 step" : "\(activity.steps) steps")
                }
                if let tokens = activity.contextTokens, let window, let share {
                    if activity.steps > 0 { Text(verbatim: "·") }
                    ContextMeter(share: share, label: "\(Formatting.tokens(tokens)) of \(Formatting.tokens(window)) tokens", size: 11.5)
                    Spacer(minLength: DroppySpacing.sm)
                    // OpenCode compacts the context once it overflows.
                    if share >= 0.8 {
                        Text("Compacts soon").foregroundStyle(.orange)
                    }
                }
            }
            .font(.system(size: 11.5))
            .monospacedDigit()
            .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
            .lineLimit(1)
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Expanded surface

/// One session over the whole shelf: every step of the turn, everything it
/// said last, what it changed, and Stop. Answering it stays in OpenChamber:
/// the shelf only takes the keyboard for a widget that grabs it whenever it opens.
struct SessionFocus: View {
    @ObservedObject var droplet: OpenchamberDroplet

    var body: some View {
        if let id = droplet.focusedSessionID ?? droplet.state.busySessionIDs.first {
            content(id)
        } else {
            WidgetMessage(text: "Nothing to show: the session is gone.")
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func content(_ id: String) -> some View {
        let session = droplet.state.sessions[id]
        let activity = droplet.state.activity[id] ?? SessionActivity()
        let live = activity.liveText.flatMap { $0.isEmpty ? nil : $0 }
        let meta = [
            Formatting.runner(of: session, model: droplet.modelName(forSession: id), server: droplet.serverLabel(forSession: id)),
            session?.project,
        ].compactMap { $0 }.joined(separator: " · ")
        let branch = session.flatMap { droplet.state.branches[$0.directory] }
        return VStack(alignment: .leading, spacing: DroppySpacing.md) {
            HStack(spacing: DroppySpacing.smd) {
                AgentMark(provider: session?.providerID ?? "", size: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session?.title ?? "Session")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                    HStack(spacing: 4) {
                        Text(verbatim: meta)
                        if let branch {
                            // The branch keeps its room; the project gives way first.
                            (Text(verbatim: "· ") + Text(Image(systemName: "arrow.triangle.branch")) + Text(verbatim: " \(branch)"))
                                .layoutPriority(1)
                        }
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                }
                .lineLimit(1)
                Spacer(minLength: DroppySpacing.md)
                if let run = droplet.autoRuns[id] {
                    AutoRunBadge(droplet: droplet, run: run)
                }
                ElapsedText(since: activity.busySince, size: 13)
                if activity.isBusy {
                    Button("Stop") { droplet.interrupt(sessionID: id) }
                        .buttonStyle(DroppyQuietButtonStyle(size: .small, destructive: true))
                }
                Button { droplet.openSession(id) } label: {
                    Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(DroppyCircleButtonStyle(size: 20))
                .help("Open in OpenChamber")
                .accessibilityLabel("Open in OpenChamber")
                Button { droplet.closeFocus() } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(DroppyCircleButtonStyle(size: 20))
                .help("Close")
                .accessibilityLabel("Close")
            }

            HStack(alignment: .top, spacing: DroppySpacing.lg) {
                StepList(calls: activity.calls, steps: activity.steps, hidesObjects: droplet.presenting)
                    .frame(width: 190, alignment: .topLeading)
                if droplet.presenting {
                    HiddenWhilePresenting().frame(maxWidth: .infinity, alignment: .topLeading)
                } else {
                    ScrollView {
                        AgentWords(text: live ?? activity.lastText ?? "", live: live != nil, tail: nil)
                            .font(.system(size: 12.5))
                            .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                            .lineSpacing(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    // Follow the words as they come; a finished message reads from the top.
                    .defaultScrollAnchor(live == nil ? .top : .bottom)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)

            HStack(spacing: DroppySpacing.md) {
                if let diff = droplet.turnDiffs[id] {
                    HStack(spacing: 4) {
                        DiffText(diff: diff, size: 12)
                        Text(verbatim: diff.files == 1 ? "in 1 file" : "in \(diff.files) files")
                            .font(.system(size: 12))
                            .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                    }
                    .fixedSize()
                    if !activity.isBusy, activity.promptID != nil {
                        Button { droplet.undoTurn(id) } label: {
                            Image(systemName: "arrow.uturn.backward").font(.system(size: 9, weight: .semibold))
                        }
                        .buttonStyle(DroppyCircleButtonStyle(size: 20))
                        .help("Undo this turn")
                        .accessibilityLabel("Undo this turn")
                    }
                }
                if let share = droplet.contextShare(forSession: id) {
                    ContextMeter(share: share)
                }
                Spacer(minLength: DroppySpacing.sm)
                // A finished turn takes a quick reply here; the rest is OpenChamber's.
                if !activity.isBusy {
                    ForEach(Array(droplet.quickReplies.prefix(2).enumerated()), id: \.offset) { _, text in
                        Button(text) { droplet.send(text, to: id) }
                            .buttonStyle(DroppyQuietButtonStyle(size: .small))
                    }
                }
                Button("Reply in OpenChamber") { droplet.openSession(id) }
                    .buttonStyle(DroppyAccentButtonStyle(color: .orange, size: .small))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// A turn's calls, oldest first, each with how it went: a dot while running,
/// a check or a cross once over, in the past tense.
private struct StepList: View {
    let calls: [ToolCall]
    let steps: Int
    /// Presentation mode: verbs, no commands or files.
    var hidesObjects = false

    var body: some View {
        if calls.isEmpty {
            WidgetMessage(text: "No steps this turn yet.")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    if steps > calls.count {
                        Text(verbatim: "\(steps - calls.count) earlier steps")
                            .font(.system(size: 11))
                            .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                    }
                    ForEach(calls, id: \.id) { call in
                        let narration = Narration(call: call)
                        let running = call.mark == .running
                        HStack(spacing: 7) {
                            Group {
                                switch call.mark {
                                case .running: Circle().fill(AdaptiveColors.notchSurfacePrimaryText).frame(width: 6, height: 6)
                                case .succeeded: Image(systemName: "checkmark").foregroundStyle(.green)
                                case .failed: Image(systemName: "xmark").foregroundStyle(.red)
                                }
                            }
                            .font(.system(size: 9, weight: .bold))
                            .frame(width: 12)
                            (Text(running ? narration.verb : narration.pastVerb).fontWeight(.medium)
                                + Text(verbatim: hidesObjects ? "" : narration.object.map { " " + $0 } ?? ""))
                                .foregroundStyle(running ? AdaptiveColors.notchSurfacePrimaryText : AdaptiveColors.notchSurfaceSecondaryText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .font(.system(size: 12))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .defaultScrollAnchor(.bottom)
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
                            Text(verbatim: window.usedPercent.map { "\(Int($0.rounded()))%" } ?? window.valueLabel ?? "–")
                                .font(.system(size: 14, weight: .semibold))
                                .monospacedDigit()
                        }
                        let pace = window.pace(at: timeline.date)
                        if window.usedPercent != nil {
                            UsageBar(percent: window.usedPercent, color: ProviderStyle.color(provider.provider), expected: pace?.expected)
                        }
                        if let runsOut = pace?.runsOut {
                            Text(Formatting.runsOut(runsOut, now: timeline.date))
                                .font(.system(size: 12))
                                .foregroundStyle(.orange)
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
    /// Where usage would be by now at an even pace, marked across the bar.
    var expected: Double? = nil

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule()
                    .fill(color)
                    .frame(width: max(6, proxy.size.width * min(1, max(0, (percent ?? 0) / 100))))
                if let expected {
                    PaceMark(length: 10)
                        .position(x: proxy.size.width * min(1, max(0, expected / 100)), y: proxy.size.height / 2)
                }
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
        // A plate under a mark that would vanish on the notch's black: OpenCode's
        // black square, and the monogram of a provider Droppy has no icon for.
        let plate = AdaptiveColors.notchSurfacePrimaryText.opacity(0.16)
        if let image = ProviderStyle.image(provider) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .background(ProviderStyle.key(provider) == "opencode" ? plate : .clear)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
        } else {
            Text(verbatim: String(name.prefix(1)).uppercased())
                .font(.system(size: size * 0.5, weight: .bold, design: .rounded))
                .foregroundStyle(ProviderStyle.color(provider))
                .frame(width: size, height: size)
                .background(plate, in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
        }
    }
}

// MARK: - HUD

/// The strip: glyph at the left edge, the tool at the right, nothing under
/// the camera in between.
struct PermissionStrip: View {
    let action: String

    var body: some View {
        let verb = Formatting.permissionVerb(action)
        HStack(spacing: 0) {
            ChamberGlyph(motion: .waiting, size: DroppyLiveActivityMetrics.iconSize, isAnimating: false)
            Spacer(minLength: 0)
            HStack(spacing: 3) {
                Image(systemName: "hand.raised.fill").font(.system(size: DroppyLiveActivityMetrics.labelFontSize - 2, weight: .semibold))
                Text(verbatim: verb.prefix(1).uppercased() + verb.dropFirst())
                    .font(.system(size: DroppyLiveActivityMetrics.labelFontSize, weight: .semibold))
            }
            .foregroundStyle(.orange)
        }
        .frame(maxWidth: .infinity)
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

/// A button on a notice card. Only decisions get one; opening is the ↗.
struct NoticeAction {
    enum Role { case accent, quiet, destructive }
    let title: String
    let role: Role
    let run: @MainActor () -> Void
}

/// Every card on the notch, laid out like Droppy's own battery and AirPods
/// cards: whose it is and what happened up top (the agent's icon with a
/// badge, the session, the state in its colour), then what it said or wants,
/// then the decision, if there is one.
struct NoticeCard: View {
    enum Style { case text, code, question }

    let provider: String
    let symbol: String
    let tint: Color
    let title: String
    let status: String
    let meta: String
    /// What the turn changed, after the status.
    var diff: TurnDiff? = nil
    let detail: String?
    let style: Style
    /// Presentation mode: the command, message or error stays off the notch.
    var hidesDetail = false
    var actions: [NoticeAction] = []
    /// Set when the turn can be undone: a ↺ beside the ↗.
    var onUndo: (@MainActor () -> Void)? = nil
    let onOpen: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            HStack(spacing: DroppySpacing.smd) {
                ZStack(alignment: .bottomTrailing) {
                    AgentMark(provider: provider, size: 28)
                    // A black ring of fill, not a stroke, parts the badge from the icon.
                    ZStack {
                        Circle().fill(Color.black).frame(width: 16, height: 16)
                        Circle().fill(tint).frame(width: 12, height: 12)
                        Image(systemName: symbol).font(.system(size: 7, weight: .heavy)).foregroundStyle(Color.black)
                    }
                    .offset(x: 5, y: 5)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                        .lineLimit(1)
                    (Text(verbatim: status).fontWeight(.semibold).foregroundStyle(tint)
                        + diffText
                        + Text(verbatim: meta.isEmpty ? "" : " · \(meta)").foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText))
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .lineLimit(1)
                }
                Spacer(minLength: DroppySpacing.sm)
                if let onUndo {
                    Button(action: onUndo) {
                        Image(systemName: "arrow.uturn.backward").font(.system(size: 9, weight: .semibold))
                    }
                    .buttonStyle(DroppyCircleButtonStyle(size: 20))
                    .help("Undo this turn")
                    .accessibilityLabel("Undo this turn")
                }
                Button(action: onOpen) {
                    Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(DroppyCircleButtonStyle(size: 20))
                .help("Open in OpenChamber")
                .accessibilityLabel("Open in OpenChamber")
            }
            if hidesDetail, detail != nil {
                HiddenWhilePresenting()
            } else if let detail {
                // A command or an error is shown as is: its backticks and asterisks are its own.
                Text(style == .code ? AttributedString(detail) : Formatting.inlineMarkdown(detail))
                    .font(style == .code ? .system(size: 11, design: .monospaced) : .system(size: 12))
                    .foregroundStyle(style == .question ? AdaptiveColors.notchSurfacePrimaryText : AdaptiveColors.notchSurfaceSecondaryText)
                    .lineLimit(2)
                    .truncationMode(style == .code ? .middle : .tail)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !actions.isEmpty {
                Spacer(minLength: 0)
                NoticeActions(actions: actions)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// ` · +42 −7 in 3 files`.
    private var diffText: Text {
        guard let diff else { return Text(verbatim: "") }
        let tertiary = AdaptiveColors.notchSurfaceTertiaryText
        return Text(verbatim: " · ").foregroundStyle(tertiary)
            + Text(verbatim: "+\(diff.additions)").foregroundStyle(.green)
            + Text(verbatim: " −\(diff.deletions)").foregroundStyle(.red)
            + Text(verbatim: diff.files == 1 ? " in 1 file" : " in \(diff.files) files").foregroundStyle(tertiary)
    }
}

/// Listening, in the strip: the session's mascot at the left edge, a red dot at the right.
struct VoiceStrip: View {
    @ObservedObject var droplet: OpenchamberDroplet

    var body: some View {
        let provider = droplet.voiceSessionID.flatMap { droplet.state.sessions[$0]?.providerID } ?? ""
        HStack(spacing: 0) {
            if let mascot = AgentMascot.Kind(provider: provider) {
                AgentMascot(kind: mascot, isAnimating: false)
            } else {
                ChamberGlyph(motion: .still)
            }
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                Circle().fill(.red).frame(width: 7, height: 7)
                Text("Listening").font(.system(size: DroppyLiveActivityMetrics.labelFontSize, weight: .semibold))
            }
            .foregroundStyle(.red)
        }
        .frame(maxWidth: .infinity)
    }
}

/// What you are saying, as it is heard, and where it goes.
struct VoiceCard: View {
    @ObservedObject var droplet: OpenchamberDroplet

    var body: some View {
        let id = droplet.voiceSessionID
        let session = id.flatMap { droplet.state.sessions[$0] }
        let heard: String = if case let .listening(_, text) = droplet.voice { text } else { "" }
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            HStack(spacing: DroppySpacing.smd) {
                AgentMark(provider: session?.providerID ?? "", size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: "To \(session?.title ?? "a session")")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                    (Text("Listening").fontWeight(.semibold).foregroundStyle(.red)
                        + Text(verbatim: " · press the shortcut again to send").foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText))
                        .font(.system(size: 11))
                }
                .lineLimit(1)
                Spacer(minLength: 0)
            }
            Text(verbatim: heard.isEmpty ? "Say what the session should do…" : Formatting.tail(heard, limit: 140))
                .font(.system(size: 13))
                .foregroundStyle(heard.isEmpty ? AdaptiveColors.notchSurfaceTertiaryText : AdaptiveColors.notchSurfacePrimaryText)
                .lineLimit(2)
            Spacer(minLength: 0)
            NoticeActions(actions: [
                NoticeAction(title: "Send", role: .accent) { droplet.sendVoice() },
                NoticeAction(title: "Cancel", role: .quiet) { droplet.cancelVoice() },
            ])
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Everything that happened while you were away, a row a session, and the
/// one thing worth doing first.
struct AwayCard: View {
    let droplet: OpenchamberDroplet
    let minutes: Int
    let ended: [OpenchamberDroplet.AwayEntry]
    let waiting: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            HStack {
                Text("While you were away")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                Spacer(minLength: DroppySpacing.sm)
                Text(verbatim: Formatting.duration(TimeInterval(minutes * 60)))
                    .font(.system(size: 11.5))
                    .monospacedDigit()
                    .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
            }
            VStack(alignment: .leading, spacing: DroppySpacing.xsm) {
                ForEach(waiting.prefix(4), id: \.self) { id in
                    row(symbol: "hand.raised.fill", tint: .orange, title: droplet.state.sessions[id]?.title ?? "A session",
                        line: droplet.state.permissions.first { $0.sessionID == id }
                            .map { "waits to \(Formatting.permissionVerb($0.action))" } ?? "has a question", diff: nil)
                }
                ForEach(ended.prefix(max(0, 4 - waiting.count)), id: \.sessionID) { entry in
                    row(symbol: entry.failed ? "xmark" : "checkmark", tint: entry.failed ? .red : .green, title: entry.title,
                        line: droplet.presenting ? nil : entry.headline, diff: entry.diff)
                }
            }
            Spacer(minLength: 0)
            NoticeActions(actions: [
                waiting.first.map { id in NoticeAction(title: "Review the request", role: .accent) { droplet.openSession(id) } }
                    ?? NoticeAction(title: "Open the last one", role: .quiet) { if let id = ended.last?.sessionID { droplet.openSession(id) } },
            ])
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func row(symbol: String, tint: Color, title: String, line: String?, diff: TurnDiff?) -> some View {
        HStack(spacing: DroppySpacing.sm) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 14)
            (Text(verbatim: title).fontWeight(.semibold).foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                + Text(verbatim: line.map { " — \($0)" } ?? "").foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText))
                .font(.system(size: 12))
                .lineLimit(1)
            Spacer(minLength: DroppySpacing.sm)
            if let diff, !diff.isEmpty { DiffText(diff: diff, size: 11).fixedSize() }
        }
    }
}

/// What stands in for a command or a message in presentation mode.
struct HiddenWhilePresenting: View {
    var body: some View {
        Label("Hidden while presenting", systemImage: "eye.slash")
            .font(.system(size: 12))
            .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
            .lineLimit(1)
    }
}

/// A card's decisions in a row, leading, the way Droppy's own cards lay them out.
struct NoticeActions: View {
    let actions: [NoticeAction]

    var body: some View {
        HStack(spacing: DroppySpacing.xsm) {
            ForEach(actions.indices, id: \.self) { index in
                let action = actions[index]
                switch action.role {
                case .accent:
                    Button(action.title, action: action.run).buttonStyle(DroppyAccentButtonStyle(color: .orange, size: .small))
                case .quiet:
                    Button(action.title, action: action.run).buttonStyle(DroppyQuietButtonStyle(size: .small))
                case .destructive:
                    Button(action.title, action: action.run).buttonStyle(DroppyQuietButtonStyle(size: .small, destructive: true))
                }
            }
            Spacer(minLength: 0)
        }
        .lineLimit(1)
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
        let state = droplet.state
        let waiting = Set(state.permissions.map(\.sessionID) + state.forms.map(\.sessionID))
        // What needs you first, then the rest of what is running.
        let ids = (state.permissions.map(\.sessionID) + state.forms.map(\.sessionID) + state.busySessionIDs)
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        VStack(alignment: .leading, spacing: DroppySpacing.xs) {
            Text(verbatim: header)
                .font(.system(size: 13, weight: .semibold))
            ForEach(ids.prefix(5), id: \.self) { id in
                Button { droplet.openSession(id) } label: {
                    HStack(spacing: DroppySpacing.xsm) {
                        Text(state.sessions[id]?.title ?? "Session")
                        if waiting.contains(id) {
                            Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                        }
                    }
                }
                .buttonStyle(.borderless)
                .font(.system(size: 13))
            }
            if let (provider, window) = droplet.usage.compactMap({ p in p.tightest.map { (p, $0) } }).first {
                // Left, not used, the number the Usage page puts under its rings.
                let label = Formatting.windowLabel(window, in: provider)
                let left = window.usedPercent.map { "\(Int((100 - $0).rounded()))% left" } ?? window.valueLabel ?? "–"
                Text(verbatim: "\(provider.name) \(label.prefix(1).lowercased() + label.dropFirst()) · \(left)")
                    .font(.system(size: 12))
                    .foregroundStyle(AdaptiveColors.secondaryTextAuto)
            }
        }
        .foregroundStyle(AdaptiveColors.primaryTextAuto)
        .padding(.vertical, DroppySpacing.xs)
        .frame(minWidth: 200, alignment: .leading)
    }

    /// `1 needs you · 3 running`: the whole state, so the list under it is not read as all waiting.
    private var header: String {
        guard case let .waiting(count) = droplet.phase else { return OpenchamberDroplet.summary(of: droplet.phase, now: Date()) }
        let busy = droplet.state.busySessionIDs.count
        return (["\(count) \(count == 1 ? "needs" : "need") you"] + (busy > 0 ? ["\(busy) running"] : [])).joined(separator: " · ")
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
                        let connection = droplet.serverStates[server.id]?.connection ?? .connecting
                        DropletControlRow(title: server.label, infoTip: tip(for: server)) {
                            // A dot and a word, the way System Settings shows a network's state.
                            HStack(spacing: DroppySpacing.xsm) {
                                Circle().fill(connection.color).frame(width: 7, height: 7)
                                Text(connection.label(relayed: droplet.serverStates[server.id]?.isRelayed == true))
                                    .foregroundStyle(.secondary)
                            }
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
                settingsSectionHeader("Show a card when")
            } content: {
                DropletSettingsCard {
                    DropletToggleRow(
                        title: "A session needs you",
                        subtitle: "Allow once or reject from the notch. Always stays in the shelf widget.",
                        isOn: preference("permissionCards", value: droplet.showsPermissionCards)
                    )
                    DropletToggleRow(
                        title: "A session asks a question",
                        subtitle: "A pick from a short list is answered on the card, anything else in OpenChamber.",
                        isOn: preference("questionCards", value: droplet.showsQuestionCards)
                    )
                    DropletToggleRow(
                        title: "A turn ends",
                        subtitle: "The session's last message. Not while OpenChamber is in front.",
                        isOn: preference("doneCards", value: droplet.showsDoneCards)
                    )
                    DropletToggleRow(
                        title: "A turn fails",
                        subtitle: "The error OpenCode reported.",
                        isOn: preference("failureCards", value: droplet.showsFailureCards)
                    )
                    DropletToggleRow(
                        title: "A session looks stuck",
                        subtitle: "Five minutes without a sound, one command running ten, or the same call failing three times. Stop it from the card, or let it be.",
                        isOn: preference("stuckCards", value: droplet.showsStuckCards)
                    )
                }
            }

            DropletSettingsSection {
                settingsSectionHeader("Quick replies")
            } content: {
                DropletSettingsCard {
                    ForEach(0..<3, id: \.self) { index in
                        DropletControlRow(
                            title: ["First", "Second", "Third"][index],
                            infoTip: index == 0 ? "Buttons on a finished or failed turn's card, sent to the session as they read. The first is the accented one; leave one empty to drop it." : nil
                        ) {
                            TextField("", text: quickReply(index), prompt: Text(OpenchamberDroplet.defaultQuickReplies[index]))
                                .frame(maxWidth: 220)
                        }
                    }
                }
            }

            DropletSettingsSection {
                settingsSectionHeader("Voice")
            } content: {
                DropletSettingsCard {
                    DropletControlRow(
                        title: "Talk to a session",
                        infoTip: "Bind “Talk to the OpenChamber session that needs you” under Droppy's Shortcuts. Press it, say what the session should do, press it again to send. It goes to the session open over the shelf, else the one that needs you, else the one that finished last. Speech is recognized on this Mac when it can be."
                    ) {
                        if droplet.voiceIsReady {
                            Text("Ready").foregroundStyle(.secondary)
                        } else {
                            Button("Allow microphone") { Task { await droplet.requestVoicePermissions() } }
                                .buttonStyle(.bordered)
                        }
                    }
                }
            }

            DropletSettingsSection {
                settingsSectionHeader("When you come back")
            } content: {
                DropletSettingsCard {
                    DropletToggleRow(
                        title: "Sum up what happened while you were away",
                        subtitle: "After the screen locks or sleeps, or ten minutes without input: one card with what finished and what waits on you.",
                        isOn: preference("awayRecap", value: droplet.recapsAway)
                    )
                    DropletToggleRow(
                        title: "Write each turn's headline with the server's small model",
                        subtitle: "Eight words from the model OpenCode uses for titles. Off, the headline is the first sentence of the message.",
                        isOn: preference("awayHeadlines", value: droplet.writesHeadlines)
                    )
                }
            }

            DropletSettingsSection {
                settingsSectionHeader("Privacy")
            } content: {
                DropletSettingsCard {
                    DropletToggleRow(
                        title: "Offer to send errors I copy",
                        subtitle: "When what you copy reads like a stack trace or a compiler error, a card offers it to the session it most likely belongs to. Nothing is sent until you press Send, and nothing is kept.",
                        isOn: Binding(get: { droplet.offersCopiedErrors }, set: { droplet.setOffersCopiedErrors($0) })
                    )
                    DropletToggleRow(
                        title: "Hide commands and messages",
                        subtitle: "For screen sharing: the notch keeps titles and states but not what agents run or say. A shortcut toggles it too.",
                        isOn: Binding(get: { droplet.presenting }, set: { droplet.setPresenting($0) })
                    )
                }
            }

            DropletSettingsSection {
                settingsSectionHeader("Links")
            } content: {
                DropletSettingsCard {
                    DropletControlRow(
                        title: "Token",
                        infoTip: "droppy://droplet/openchamber/new?project=…&prompt=…, reply?text=…, approve, stop, voice, open and focus, for Raycast, Shortcuts or a script. Any web page can open these links, so all but open and focus need token=."
                    ) {
                        HStack(spacing: DroppySpacing.sm) {
                            Text(verbatim: droplet.linkToken)
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            Button("Copy example") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(
                                    "open \"droppy://droplet/openchamber/new?project=api&prompt=bump%20the%20deps&token=\(droplet.linkToken)\"",
                                    forType: .string
                                )
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }

            DropletSettingsSection {
                settingsSectionHeader("Usage")
            } content: {
                DropletSettingsCard {
                    DropletToggleRow(
                        title: "Warn at 80% and 95%",
                        subtitle: "A short notice on the notch as a usage window passes each.",
                        isOn: preference("usageWarnings", value: droplet.warnsAboutUsage)
                    )
                }
            }
        }
    }

    private func quickReply(_ index: Int) -> Binding<String> {
        Binding(
            get: {
                let stored = droplet.host?.preferences.value(forKey: "quickReplies", default: OpenchamberDroplet.defaultQuickReplies)
                    ?? OpenchamberDroplet.defaultQuickReplies
                return stored.indices.contains(index) ? stored[index] : ""
            },
            set: { text in
                var stored = droplet.host?.preferences.value(forKey: "quickReplies", default: OpenchamberDroplet.defaultQuickReplies)
                    ?? OpenchamberDroplet.defaultQuickReplies
                while stored.count < 3 { stored.append("") }
                stored[index] = text
                droplet.setPreference(stored, forKey: "quickReplies")
            }
        )
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

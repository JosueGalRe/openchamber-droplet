//
//  OpenchamberDroplet.swift
//  Openchamber
//

import Combine
import DroppyKit
import SwiftUI

/// The class Droppy's loader instantiates, named in the bundle's
/// `NSPrincipalClass`. Keep it empty: it runs before the host is ready.
@objc(OpenchamberPrincipal)
public final class OpenchamberPrincipal: NSObject, DropletPrincipal {
    public override init() { super.init() }

    @MainActor public func makeDroplet() -> AnyObject { OpenchamberDroplet() }
}

/// OpenChamber's sessions, approvals and plan usage, in the notch.
@MainActor
public final class OpenchamberDroplet: NSObject, ObservableObject, Droplet {
    /// Must equal `DroppyDropletID` in the bundle's Info.plist and `id` in
    /// droplet.json. The loader refuses the bundle if the three disagree.
    public nonisolated static let id: DropletID = "openchamber"

    enum Connection: Equatable {
        case notPaired
        case offline
        case connecting
        case live
        case failed(String)
    }

    static let sessionsWidgetID: ShelfWidgetID = "sessions"
    static let usageWidgetID: ShelfWidgetID = "usage"
    static let defaultServer = URL(string: "http://127.0.0.1:4097")!

    @Published private(set) var state = ActivityState()
    @Published private(set) var phase: ActivityPhase = .idle
    @Published private(set) var usage: [ProviderQuota] = []
    @Published private(set) var connection: Connection = .notPaired
    @Published private(set) var seat: DropletLiveActivitySeat = .none(.idle)
    @Published var pairingError: String?

    private(set) var host: DropletHost?
    private var client: OpenChamberClient?
    private var feed: Task<Void, Never>?
    private var ticker: AnyCancellable?
    private var usageFetchedAt: Date?
    private var usageRefresh: Task<Void, Never>?
    private var sessionLookups: Set<String> = []
    private var announcedPermissions: Set<String> = []
    private var usageWarnings: Set<String> = []
    private let activitySubject = CurrentValueSubject<LiveActivityState?, Never>(nil)
    private let lockScreenSubject = CurrentValueSubject<LockScreenStatusEntry?, Never>(nil)

    // MARK: Lifecycle

    public func activate(host: DropletHost) throws {
        self.host = host
        if host.environment.isHarness {
            loadSample()
        } else {
            startFeed()
        }
        host.shortcuts.register(id: "approve-oldest", title: "Allow the oldest OpenChamber request once", defaultShortcut: nil) { [weak self] in
            guard let self, let oldest = self.state.permissions.first else { return }
            self.reply(to: oldest, decision: "once")
        }
        host.shortcuts.register(id: "open-waiting", title: "Open the OpenChamber session that needs you", defaultShortcut: nil) { [weak self] in
            guard let self else { return }
            let waiting = self.state.permissions.first?.sessionID ?? self.state.forms.first?.sessionID ?? self.state.busySessionIDs.first
            if let waiting { self.openSession(waiting) }
        }
        host.log.info("OpenChamber activated")
    }

    public func deactivate() {
        feed?.cancel()
        feed = nil
        usageRefresh?.cancel()
        usageRefresh = nil
        ticker?.cancel()
        ticker = nil
        host?.shortcuts.unregister(id: "approve-oldest")
        host?.shortcuts.unregister(id: "open-waiting")
        for id in announcedPermissions { host?.hud.dismiss(id: hudID(id)) }
        activitySubject.send(nil)
        lockScreenSubject.send(nil)
        client = nil
        host = nil
    }

    // MARK: Settings

    var serverURL: URL {
        host?.preferences.value(forKey: "server", as: String.self).flatMap(URL.init(string:)) ?? Self.defaultServer
    }

    var showsPermissionCards: Bool {
        host?.preferences.value(forKey: "permissionCards", default: true) ?? true
    }

    var warnsAboutUsage: Bool {
        host?.preferences.value(forKey: "usageWarnings", default: true) ?? true
    }

    func setPreference<Value: Codable>(_ value: Value, forKey key: String) {
        host?.preferences.setValue(value, forKey: key)
        objectWillChange.send()
    }

    func setServer(_ text: String) {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespaces)), url.scheme?.hasPrefix("http") == true else { return }
        setPreference(url.absoluteString, forKey: "server")
        restartFeed()
    }

    func pair(with link: String) {
        pairingError = nil
        let server = serverURL
        // One key per Mac, so pairing again replaces this device in
        // OpenChamber's list instead of adding a second one.
        let deviceKey = host?.preferences.value(forKey: "deviceKey", as: String.self) ?? {
            let key = "droppy-\(UUID().uuidString)"
            host?.preferences.setValue(key, forKey: "deviceKey")
            return key
        }()
        let appVersion = host?.environment.appVersion ?? "unknown"
        Task {
            do {
                let token = try await OpenChamberClient.redeem(link: link, baseURL: server, deviceKey: deviceKey, appVersion: appVersion)
                guard TokenStore.save(token, for: server) else {
                    pairingError = "The Keychain refused to store the device token."
                    return
                }
                restartFeed()
            } catch {
                pairingError = error.localizedDescription
            }
        }
    }

    func forgetDevice() {
        TokenStore.delete(for: serverURL)
        restartFeed()
    }

    // MARK: Feed

    private func restartFeed() {
        feed?.cancel()
        state = ActivityState()
        usage = []
        usageFetchedAt = nil
        publish()
        startFeed()
    }

    private func startFeed() {
        feed = Task { [weak self] in await self?.runFeed() }
    }

    /// Connects, seeds, streams, and starts over when the stream drops. Waits
    /// on `/health` while OpenChamber is closed, which costs no token.
    private func runFeed() async {
        var backoff: TimeInterval = 2
        var lastEventID: String?
        while !Task.isCancelled {
            let server = serverURL
            guard let token = TokenStore.read(for: server) else {
                connection = .notPaired
                return
            }
            guard await OpenChamberClient.isReachable(server) else {
                connection = .offline
                try? await Task.sleep(for: .seconds(15))
                continue
            }
            let client = OpenChamberClient(baseURL: server, token: token)
            self.client = client
            do {
                connection = .connecting
                apply(try await client.seed())
                apply(.sessionsListed(try await client.recentSessions()))
                let stream = try await client.events(after: lastEventID)
                connection = .live
                backoff = 2
                refreshUsage(ifOlderThan: 60)
                for try await frame in stream {
                    switch frame {
                    case let .ready(replayReset):
                        if replayReset { apply(try await client.seed()) }
                    case let .event(event, eventID):
                        if let eventID { lastEventID = eventID }
                        if let event { apply(event) }
                    }
                }
            } catch OpenChamberError.unauthorized {
                TokenStore.delete(for: server)
                connection = .notPaired
                return
            } catch is CancellationError {
                return
            } catch {
                connection = .failed(error.localizedDescription)
                host?.log.error("event stream ended: \(error.localizedDescription)")
            }
            try? await Task.sleep(for: .seconds(backoff))
            backoff = min(backoff * 2, 30)
        }
    }

    private func apply(_ event: ActivityEvent) {
        let wasBusy = !state.busySessionIDs.isEmpty
        state.apply(event)
        lookUpUnknownSessions()
        announceNewPermissions()
        if wasBusy, state.busySessionIDs.isEmpty {
            // A turn just ended: usage moved, and this is the moment it is worth asking.
            refreshUsage(ifOlderThan: 30)
        }
        publish()
    }

    private func lookUpUnknownSessions() {
        guard let client else { return }
        for id in state.unknownSessionIDs.subtracting(sessionLookups) {
            sessionLookups.insert(id)
            Task {
                if let info = try? await client.session(id: id) {
                    state.apply(.sessionsListed([info]))
                    publish()
                }
            }
        }
    }

    // MARK: Actions

    func reply(to permission: PendingPermission, decision: String) {
        guard let client else { return }
        Task {
            do {
                try await client.reply(to: permission, decision: decision)
                // The `permission.replied` event settles it too; this is so the
                // card goes the moment the click lands.
                apply(.permissionSettled(sessionID: permission.sessionID, requestID: permission.id))
                host?.feedback.play(.success)
            } catch {
                host?.log.error("permission reply failed: \(error.localizedDescription)")
                host?.feedback.play(.failure)
            }
        }
    }

    func interrupt(sessionID: String) {
        guard let client else { return }
        let directory = state.sessions[sessionID]?.directory
        Task { try? await client.interrupt(sessionID: sessionID, directory: directory) }
    }

    func openSession(_ id: String) {
        guard let url = URL(string: "openchamber://session/\(id)") else { return }
        _ = host?.workspace.open(url)
    }

    func openSettings() {
        _ = host?.workspace.openSettings()
    }

    // MARK: Presenting

    /// Recomputes the phase and pushes it to the notch and the lock screen.
    /// Cheap to call often: the host diffs both before it redraws.
    private func publish(now: Date = Date()) {
        let next = state.phase(at: now)
        if next != phase { phase = next }

        if phase == .idle {
            activitySubject.send(nil)
            lockScreenSubject.send(nil)
        } else {
            activitySubject.send(LiveActivityState(
                priority: 150,
                accessibilityTitle: "OpenChamber: \(Self.summary(of: phase, now: now))",
                isInteractive: false,
                joinsPersistentActivitySet: true,
                compactPresentation: nil,
                expandedWidgetID: Self.sessionsWidgetID.rawValue
            ))
            lockScreenSubject.send(LockScreenStatusEntry(
                id: "openchamber.phase",
                systemImage: "cube",
                text: Self.summary(of: phase, now: now),
                detail: "OpenChamber",
                roundedCenterText: Self.badge(of: phase),
                roundedBottomText: "OpenChamber"
            ))
        }
        updateTicker()
    }

    /// Phases move with the clock (a retry comes due, a finish fades, a
    /// failure times out), so a one-second tick runs while anything is shown
    /// and stops the moment the notch has nothing to say.
    private func updateTicker() {
        if phase == .idle {
            ticker?.cancel()
            ticker = nil
        } else if ticker == nil {
            ticker = Timer.publish(every: 1, on: .main, in: .common)
                .autoconnect()
                .sink { [weak self] date in self?.publish(now: date) }
        }
    }

    private func hudID(_ permissionID: String) -> String { "openchamber.permission.\(permissionID)" }

    /// A card for each new request, for twelve seconds. The request stays in
    /// the widget and the live activity after the card goes. "Always" is not
    /// offered here: a standing rule is not something to grant from a card
    /// that passes in front of you.
    private func announceNewPermissions() {
        let current = Set(state.permissions.map(\.id))
        for gone in announcedPermissions.subtracting(current) { host?.hud.dismiss(id: hudID(gone)) }
        announcedPermissions.formIntersection(current)

        guard showsPermissionCards, let host else { return }
        for permission in state.permissions where !announcedPermissions.contains(permission.id) {
            announcedPermissions.insert(permission.id)
            let session = state.sessions[permission.sessionID]
            let request = DropletHUDRequest(
                id: hudID(permission.id),
                duration: 12,
                priority: .high,
                accessibilityLabel: "\(session?.title ?? "A session") asks to run \(permission.action)",
                isExpanded: true,
                expandedContentHeight: 92
            ) {
                PermissionStrip(action: permission.action)
            } expanded: { [weak self] in
                // The host keeps these builders, so they hold the droplet weakly.
                PermissionCard(
                    permission: permission,
                    session: session,
                    onAllow: { self?.reply(to: permission, decision: "once") },
                    onReject: { self?.reply(to: permission, decision: "reject") },
                    onOpen: { self?.openSession(permission.sessionID) }
                )
            }
            _ = host.hud.present(request)
        }
    }

    // MARK: Usage

    /// OpenChamber asks each provider's API on every call, and only Claude's
    /// is cached server-side, so this never polls on a tight loop: on connect,
    /// when a turn ends, when the widget appears, and every five minutes while
    /// something is busy.
    func refreshUsage(ifOlderThan age: TimeInterval) {
        guard let client, usageRefresh == nil else { return }
        if let fetched = usageFetchedAt, Date().timeIntervalSince(fetched) < age { return }
        usageRefresh = Task {
            defer { usageRefresh = nil }
            guard let ids = try? await client.quotaProviderIDs() else { return }
            var results: [ProviderQuota] = []
            for id in ids {
                if let quota = try? await client.quota(providerID: id) { results.append(quota) }
            }
            usage = results
            usageFetchedAt = Date()
            warnAboutUsage()
            scheduleBusyUsageRefresh()
        }
    }

    private func scheduleBusyUsageRefresh() {
        guard !state.busySessionIDs.isEmpty else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(300))
            guard let self, !self.state.busySessionIDs.isEmpty else { return }
            self.refreshUsage(ifOlderThan: 290)
        }
    }

    /// One card per window and threshold until that window resets.
    private func warnAboutUsage() {
        guard warnsAboutUsage, let host else { return }
        for provider in usage {
            for window in provider.windows {
                guard let used = window.usedPercent,
                      let threshold = [95.0, 80.0].first(where: { used >= $0 }) else { continue }
                let key = "\(provider.id).\(window.name).\(Int(threshold)).\(window.resetAt?.timeIntervalSince1970 ?? 0)"
                guard usageWarnings.insert(key).inserted else { continue }
                let label = "\(provider.name) \(window.name) at \(Int(used))%"
                _ = host.hud.present(DropletHUDRequest(id: "openchamber.usage", duration: 4, accessibilityLabel: label) {
                    UsageStrip(percent: used, label: "\(provider.name) \(window.name)")
                })
            }
        }
    }

    // MARK: Formatting

    static func summary(of phase: ActivityPhase, now: Date) -> String {
        switch phase {
        case .idle: return "Idle"
        case let .working(sessions, since):
            let elapsed = Formatting.elapsed(now.timeIntervalSince(since))
            return sessions == 1 ? "Working, \(elapsed)" : "\(sessions) sessions, \(elapsed)"
        case let .retrying(attempt, _, at): return "Retry \(attempt) in \(Formatting.elapsed(at.timeIntervalSince(now)))"
        case .finishing: return "Done"
        case let .waiting(count): return count == 1 ? "Needs you" : "\(count) need you"
        case .failed: return "Failed"
        }
    }

    static func badge(of phase: ActivityPhase) -> String {
        switch phase {
        case let .working(sessions, _): return "\(sessions)"
        case let .waiting(count): return "\(count)"
        case .failed: return "!"
        case .retrying: return "↻"
        case .finishing: return "✓"
        case .idle: return ""
        }
    }

    var glyphMotion: ChamberGlyphMotion {
        switch phase {
        case .idle: return .still
        case .working: return .sweep
        case let .retrying(_, scheduled, at): return .fill(start: scheduled, end: at)
        case let .finishing(from, until): return .fill(start: from, end: until)
        case .waiting: return .waiting
        case .failed: return .failed
        }
    }
}

// MARK: - Live activity

extension OpenchamberDroplet: LiveActivityProviding {
    public var liveActivityState: AnyPublisher<LiveActivityState?, Never> {
        activitySubject.eraseToAnyPublisher()
    }

    public func liveActivitySeatDidChange(_ seat: DropletLiveActivitySeat) {
        self.seat = seat
    }

    public func makeCompactLeading() -> AnyView {
        AnyView(CompactGlyph(droplet: self, size: DroppyLiveActivityMetrics.iconSize))
    }

    public func makeCompactTrailing() -> AnyView {
        AnyView(CompactLabel(droplet: self))
    }

    /// Not mounted by Droppy: hovering the row opens the shelf on the sessions widget.
    public func makeExpanded(context: LiveActivityContext) -> AnyView {
        AnyView(EmptyView())
    }

    public func makeCompanionCompact(context: CompactLiveActivityContext) -> AnyView {
        AnyView(CompactGlyph(droplet: self, size: min(context.slotSize.width, context.slotSize.height)))
    }
}

// MARK: - Shelf widgets

extension OpenchamberDroplet: ShelfWidgetProviding {
    public var widgetDescriptors: [ShelfWidgetDescriptor] {
        [
            ShelfWidgetDescriptor(
                id: Self.sessionsWidgetID,
                title: "OpenChamber",
                systemImage: "cube",
                layoutTraits: ShelfWidgetLayoutTraits(
                    preferredSoloWidth: 440,
                    preferredPairedWidth: 220,
                    contentHeight: .fixed(176)
                ),
                searchKeywords: ["opencode", "agent", "session", "permission", "approve"]
            ),
            ShelfWidgetDescriptor(
                id: Self.usageWidgetID,
                title: "OpenChamber usage",
                systemImage: "gauge.with.dots.needle.50percent",
                layoutTraits: ShelfWidgetLayoutTraits(
                    preferredSoloWidth: 360,
                    preferredPairedWidth: 220,
                    contentHeight: .fixed(150)
                ),
                searchKeywords: ["quota", "limit", "plan", "claude", "codex", "usage"]
            ),
        ]
    }

    public func makeWidgetView(_ id: ShelfWidgetID, context: ShelfWidgetContext) -> AnyView {
        id == Self.usageWidgetID
            ? AnyView(UsageWidget(droplet: self, context: context))
            : AnyView(SessionsWidget(droplet: self, context: context))
    }
}

// MARK: - HUD, lock screen, menu bar

extension OpenchamberDroplet: HUDPresenting {}

extension OpenchamberDroplet: LockScreenStatusProviding {
    public var lockScreenStatus: AnyPublisher<LockScreenStatusEntry?, Never> {
        lockScreenSubject.eraseToAnyPublisher()
    }
}

extension OpenchamberDroplet: MenuBarExtraProviding {
    public func makeMenuBarExtra() -> MenuBarExtraDescriptor? {
        guard connection != .notPaired else { return nil }
        return MenuBarExtraDescriptor(title: "OpenChamber", systemImage: "cube") { [weak self] in
            guard let self else { return AnyView(EmptyView()) }
            return AnyView(MenuBarSummary(droplet: self))
        }
    }
}

// MARK: - Settings pane

extension OpenchamberDroplet: SettingsPaneProviding {
    public func makeSettingsPane(context: SettingsPaneContext) -> AnyView {
        AnyView(OpenchamberSettings(droplet: self))
    }

    public var settingsSearchEntries: [SettingsSearchEntry] {
        [SettingsSearchEntry(title: "OpenChamber pairing", keywords: ["pair", "token", "server", "opencode"])]
    }
}

// MARK: - Harness sample

private extension OpenchamberDroplet {
    /// What the harness shows: no network, one of everything.
    func loadSample() {
        let now = Date()
        state.apply(.sessionsListed([
            SessionInfo(id: "s1", title: "Fix notification title cache", directory: "/Users/me/projects/openchamber", parentID: nil),
            SessionInfo(id: "s2", title: "Design the droplet", directory: "/Users/me/projects/openchamber-droplet", parentID: nil),
        ]))
        state.apply(.executionStarted(sessionID: "s1", at: now.addingTimeInterval(-252)))
        for (index, mark) in [true, true, false, true, true].enumerated() {
            state.apply(.toolStarted(sessionID: "s1", callID: "c\(index)", name: "read"))
            state.apply(.toolFinished(sessionID: "s1", callID: "c\(index)", succeeded: mark))
        }
        state.apply(.toolStarted(sessionID: "s1", callID: "c9", name: "edit"))
        state.apply(.toolCalled(sessionID: "s1", callID: "c9", name: nil, target: "session-runtime.js"))
        state.apply(.executionStarted(sessionID: "s2", at: now.addingTimeInterval(-48)))
        state.apply(.permissionAsked(PendingPermission(
            id: "p1", sessionID: "s2", action: "bash",
            resources: ["swift build -c release --product Openchamber"],
            directory: "/Users/me/projects/openchamber-droplet"
        )))
        usage = [
            ProviderQuota(id: "claude", name: "Claude", plan: "Max", windows: [
                QuotaWindow(name: "5h", usedPercent: 82, windowSeconds: 18_000, resetAt: now.addingTimeInterval(4_320)),
                QuotaWindow(name: "7d", usedPercent: 38, windowSeconds: 604_800, resetAt: now.addingTimeInterval(273_600)),
            ]),
            ProviderQuota(id: "codex", name: "Codex", plan: "Pro", windows: [
                QuotaWindow(name: "5h", usedPercent: 21, windowSeconds: 18_000, resetAt: now.addingTimeInterval(9_600)),
            ]),
        ]
        connection = .live
        announceNewPermissions()
        publish(now: now)
    }
}

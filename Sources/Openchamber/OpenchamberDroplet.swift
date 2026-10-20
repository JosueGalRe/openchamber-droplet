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

/// OpenChamber's sessions, approvals and plan usage, in the notch, from every
/// server OpenChamber Desktop on this Mac is set up for.
@MainActor
public final class OpenchamberDroplet: NSObject, ObservableObject, Droplet {
    /// Must equal `DroppyDropletID` in the bundle's Info.plist and `id` in
    /// droplet.json. The loader refuses the bundle if the three disagree.
    public nonisolated static let id: DropletID = "openchamber"

    enum Connection: Equatable {
        /// OpenChamber Desktop's settings were not found, or list no server.
        case noServers
        case offline
        case connecting
        case live
        case failed(String)
    }

    /// One server's slice of everything the droplet shows.
    struct ServerState: Equatable {
        var activity = ActivityState()
        var connection: Connection = .connecting
        var usage: [ProviderQuota] = []
        var usageFetchedAt: Date?
    }

    static let sessionsWidgetID: ShelfWidgetID = "sessions"
    static let usageWidgetID: ShelfWidgetID = "usage"

    @Published private(set) var servers: [ChamberServer] = []
    @Published private(set) var serverStates: [String: ServerState] = [:]
    /// Every server's activity merged, recomputed on each change.
    @Published private(set) var state = ActivityState()
    @Published private(set) var phase: ActivityPhase = .idle
    @Published private(set) var seat: DropletLiveActivitySeat = .none(.idle)

    private(set) var host: DropletHost?
    private var clients: [String: OpenChamberClient] = [:]
    private var feeds: [String: Task<Void, Never>] = [:]
    private var usageRefreshes: [String: Task<Void, Never>] = [:]
    private var ticker: AnyCancellable?
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
            reloadServers()
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
        stopFeeds()
        ticker?.cancel()
        ticker = nil
        host?.shortcuts.unregister(id: "approve-oldest")
        host?.shortcuts.unregister(id: "open-waiting")
        for id in announcedPermissions { host?.hud.dismiss(id: hudID(id)) }
        activitySubject.send(nil)
        lockScreenSubject.send(nil)
        host = nil
    }

    // MARK: Settings

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

    /// Reads OpenChamber Desktop's servers again and reconnects to each.
    func reloadServers() {
        stopFeeds()
        servers = DesktopServers.load()
        serverStates = Dictionary(uniqueKeysWithValues: servers.map { ($0.id, ServerState()) })
        sessionLookups = []
        publish()
        for server in servers {
            feeds[server.id] = Task { [weak self] in await self?.runFeed(server) }
        }
        host?.log.info("watching \(servers.count) OpenChamber server\(servers.count == 1 ? "" : "s")")
    }

    private func stopFeeds() {
        feeds.values.forEach { $0.cancel() }
        usageRefreshes.values.forEach { $0.cancel() }
        feeds = [:]
        usageRefreshes = [:]
        clients = [:]
    }

    /// The whole droplet's connection, for the widgets: live if any server is.
    var connection: Connection {
        let all = servers.compactMap { serverStates[$0.id]?.connection }
        if all.isEmpty { return .noServers }
        if all.contains(.live) { return .live }
        if all.allSatisfy({ $0 == .offline }) { return .offline }
        return all.first { if case .failed = $0 { return true } else { return false } } ?? .connecting
    }

    /// Every server's plan usage. A remote server's providers carry its name,
    /// since the same provider there is usually another account.
    var usage: [ProviderQuota] {
        servers.flatMap { server in
            (serverStates[server.id]?.usage ?? []).map { quota in
                server.isLocal ? quota : ProviderQuota(id: "\(server.id).\(quota.id)", name: "\(quota.name) · \(server.label)", plan: quota.plan, windows: quota.windows)
            }
        }
    }

    // MARK: Feeds

    /// Connects, seeds, streams, and starts over when the stream drops. Waits
    /// on `/health` while the server is down, which costs no token.
    private func runFeed(_ initial: ChamberServer) async {
        var server = initial
        var backoff: TimeInterval = 2
        var lastEventID: String?
        while !Task.isCancelled {
            guard await OpenChamberClient.isReachable(server.baseURL) else {
                setConnection(.offline, for: server.id)
                try? await Task.sleep(for: .seconds(15))
                continue
            }
            let client = OpenChamberClient(server: server)
            clients[server.id] = client
            do {
                setConnection(.connecting, for: server.id)
                apply(try await client.seed(), from: server.id)
                apply(.sessionsListed(try await client.recentSessions()), from: server.id)
                let stream = try await client.events(after: lastEventID)
                setConnection(.live, for: server.id)
                backoff = 2
                refreshUsage(on: server.id, ifOlderThan: 60)
                for try await frame in stream {
                    switch frame {
                    case let .ready(replayReset):
                        if replayReset { apply(try await client.seed(), from: server.id) }
                    case let .event(event, eventID):
                        if let eventID { lastEventID = eventID }
                        if let event { apply(event, from: server.id) }
                    }
                }
            } catch OpenChamberError.unauthorized {
                // OpenChamber Desktop renews its tokens: take the current one.
                if let fresh = DesktopServers.load().first(where: { $0.id == server.id }), fresh.token != server.token {
                    server = fresh
                    continue
                }
                setConnection(.failed(OpenChamberError.unauthorized.localizedDescription), for: server.id)
                backoff = 60
            } catch is CancellationError {
                return
            } catch {
                setConnection(.failed(error.localizedDescription), for: server.id)
                host?.log.error("\(server.label): event stream ended: \(error.localizedDescription)")
            }
            try? await Task.sleep(for: .seconds(backoff))
            backoff = min(backoff * 2, 60)
        }
    }

    private func setConnection(_ connection: Connection, for serverID: String) {
        guard serverStates[serverID]?.connection != connection else { return }
        serverStates[serverID]?.connection = connection
    }

    private func apply(_ event: ActivityEvent, from serverID: String) {
        guard var server = serverStates[serverID] else { return }
        let wasBusy = !server.activity.busySessionIDs.isEmpty
        server.activity.apply(event)
        serverStates[serverID] = server
        lookUpUnknownSessions(on: serverID)
        if wasBusy, server.activity.busySessionIDs.isEmpty {
            // A turn just ended: usage moved, and this is the moment it is worth asking.
            refreshUsage(on: serverID, ifOlderThan: 30)
        }
        publish()
    }

    private func lookUpUnknownSessions(on serverID: String) {
        guard let client = clients[serverID], let unknown = serverStates[serverID]?.activity.unknownSessionIDs else { return }
        for id in unknown.subtracting(sessionLookups) {
            sessionLookups.insert(id)
            Task {
                if let info = try? await client.session(id: id) { apply(.sessionsListed([info]), from: serverID) }
            }
        }
    }

    /// The server a session belongs to, for routing an action back to it.
    private func serverID(forSession id: String) -> String? {
        serverStates.first { _, server in
            server.activity.activity[id] != nil
                || server.activity.sessions[id] != nil
                || server.activity.permissions.contains { $0.sessionID == id }
                || server.activity.forms.contains { $0.sessionID == id }
        }?.key
    }

    /// The server's name, when there is more than one server to tell apart.
    func serverLabel(forSession id: String) -> String? {
        guard servers.count > 1, let serverID = serverID(forSession: id) else { return nil }
        return servers.first { $0.id == serverID }?.label
    }

    // MARK: Actions

    func reply(to permission: PendingPermission, decision: String) {
        guard let serverID = serverID(forSession: permission.sessionID), let client = clients[serverID] else { return }
        Task {
            do {
                try await client.reply(to: permission, decision: decision)
                // The `permission.replied` event settles it too; this is so the
                // card goes the moment the click lands.
                apply(.permissionSettled(sessionID: permission.sessionID, requestID: permission.id), from: serverID)
                host?.feedback.play(.success)
            } catch {
                host?.log.error("permission reply failed: \(error.localizedDescription)")
                host?.feedback.play(.failure)
            }
        }
    }

    func interrupt(sessionID: String) {
        guard let serverID = serverID(forSession: sessionID), let client = clients[serverID] else { return }
        let directory = state.sessions[sessionID]?.directory
        Task { try? await client.interrupt(sessionID: sessionID, directory: directory) }
    }

    /// Opens the session in OpenChamber Desktop. A remote server's session
    /// opens there too once Desktop is switched to that host.
    func openSession(_ id: String) {
        guard let url = URL(string: "openchamber://session/\(id)") else { return }
        _ = host?.workspace.open(url)
    }

    func openSettings() {
        _ = host?.workspace.openSettings()
    }

    // MARK: Presenting

    /// Merges the servers, recomputes the phase and pushes it to the notch and
    /// the lock screen. Cheap to call often: the host diffs before it redraws.
    private func publish(now: Date = Date()) {
        let merged = ActivityState.merged(servers.compactMap { serverStates[$0.id]?.activity })
        if merged != state { state = merged }
        announceNewPermissions()

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
        for server in servers { refreshUsage(on: server.id, ifOlderThan: age) }
    }

    private func refreshUsage(on serverID: String, ifOlderThan age: TimeInterval) {
        guard let client = clients[serverID], usageRefreshes[serverID] == nil else { return }
        if let fetched = serverStates[serverID]?.usageFetchedAt, Date().timeIntervalSince(fetched) < age { return }
        usageRefreshes[serverID] = Task {
            defer { usageRefreshes[serverID] = nil }
            guard let ids = try? await client.quotaProviderIDs() else { return }
            var results: [ProviderQuota] = []
            for id in ids {
                if let quota = try? await client.quota(providerID: id) { results.append(quota) }
            }
            serverStates[serverID]?.usage = results
            serverStates[serverID]?.usageFetchedAt = Date()
            warnAboutUsage()
            scheduleBusyUsageRefresh(on: serverID)
        }
    }

    private func scheduleBusyUsageRefresh(on serverID: String) {
        guard serverStates[serverID]?.activity.busySessionIDs.isEmpty == false else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(300))
            guard let self, self.serverStates[serverID]?.activity.busySessionIDs.isEmpty == false else { return }
            self.refreshUsage(on: serverID, ifOlderThan: 290)
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
        guard !servers.isEmpty else { return nil }
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
        [SettingsSearchEntry(title: "OpenChamber servers", keywords: ["server", "host", "token", "opencode"])]
    }
}

// MARK: - Harness sample

private extension OpenchamberDroplet {
    /// What the harness shows: no network, two servers, one of everything.
    func loadSample() {
        let now = Date()
        let mac = ChamberServer(id: ChamberServer.localID, label: "This Mac", baseURL: URL(string: "http://127.0.0.1:4097")!, token: "", headers: [:])
        let remote = ChamberServer(id: "remote", label: "devbox", baseURL: URL(string: "http://192.168.1.30:4097")!, token: "", headers: [:])
        servers = [mac, remote]

        var local = ServerState(connection: .live)
        local.activity.apply(.sessionsListed([
            SessionInfo(id: "s1", title: "Fix notification title cache", directory: "/Users/me/projects/openchamber", parentID: nil),
            SessionInfo(id: "s2", title: "Design the droplet", directory: "/Users/me/projects/openchamber-droplet", parentID: nil),
        ]))
        local.activity.apply(.executionStarted(sessionID: "s1", at: now.addingTimeInterval(-252)))
        for (index, mark) in [true, true, false, true, true].enumerated() {
            local.activity.apply(.toolStarted(sessionID: "s1", callID: "c\(index)", name: "read"))
            local.activity.apply(.toolFinished(sessionID: "s1", callID: "c\(index)", succeeded: mark))
        }
        local.activity.apply(.toolStarted(sessionID: "s1", callID: "c9", name: "edit"))
        local.activity.apply(.toolCalled(sessionID: "s1", callID: "c9", name: nil, target: "session-runtime.js"))
        local.activity.apply(.executionStarted(sessionID: "s2", at: now.addingTimeInterval(-48)))
        local.activity.apply(.permissionAsked(PendingPermission(
            id: "p1", sessionID: "s2", action: "bash",
            resources: ["swift build -c release --product Openchamber"],
            directory: "/Users/me/projects/openchamber-droplet"
        )))
        local.usage = [
            ProviderQuota(id: "claude", name: "Claude", plan: "Max", windows: [
                QuotaWindow(name: "5h", usedPercent: 82, windowSeconds: 18_000, resetAt: now.addingTimeInterval(4_320)),
                QuotaWindow(name: "7d", usedPercent: 38, windowSeconds: 604_800, resetAt: now.addingTimeInterval(273_600)),
            ]),
        ]

        var work = ServerState(connection: .live)
        work.activity.apply(.sessionsListed([SessionInfo(id: "w1", title: "Kiro migration", directory: "/home/bryan/work/api", parentID: nil)]))
        work.activity.apply(.executionStarted(sessionID: "w1", at: now.addingTimeInterval(-610)))
        work.usage = [
            ProviderQuota(id: "codex", name: "Codex", plan: "Pro", windows: [
                QuotaWindow(name: "5h", usedPercent: 21, windowSeconds: 18_000, resetAt: now.addingTimeInterval(9_600)),
            ]),
        ]
        serverStates = [mac.id: local, remote.id: work]
        publish(now: now)
    }
}

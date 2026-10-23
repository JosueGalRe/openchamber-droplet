//
//  OpenchamberDroplet.swift
//  Openchamber
//

import AppKit
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
        /// How the current connection reaches the server, for settings.
        var route: String?
    }

    /// The widget's two pages, switched from its header like Agents' Progress and Usage.
    enum WidgetTab: String, Codable {
        case sessions, usage
    }

    /// Kept from when sessions and usage were two widgets, so the one widget
    /// takes the sessions widget's place on the shelf.
    static let widgetID: ShelfWidgetID = "sessions"

    @Published private(set) var servers: [ChamberServer] = []
    @Published private(set) var serverStates: [String: ServerState] = [:]
    /// Every server's activity merged, recomputed on each change.
    @Published private(set) var state = ActivityState()
    @Published private(set) var phase: ActivityPhase = .idle
    @Published private(set) var seat: DropletLiveActivitySeat = .none(.idle)
    @Published private(set) var tab: WidgetTab = .sessions

    private(set) var host: DropletHost?
    private var clients: [String: OpenChamberClient] = [:]
    private var feeds: [String: Task<Void, Never>] = [:]
    private var usageRefreshes: [String: Task<Void, Never>] = [:]
    private var ticker: AnyCancellable?
    private var sessionLookups: Set<String> = []
    private var announcedPermissions: Set<String> = []
    private var announcedForms: Set<String> = []
    /// Turns that ended while the last Done card was up, so it can say "2 done".
    private var recentTurnEnds: [Date] = []
    private var usageWarnings: Set<String> = []
    private let activitySubject = CurrentValueSubject<LiveActivityState?, Never>(nil)
    private let lockScreenSubject = CurrentValueSubject<LockScreenStatusEntry?, Never>(nil)

    // MARK: Lifecycle

    public func activate(host: DropletHost) throws {
        self.host = host
        tab = host.preferences.value(forKey: "tab", default: WidgetTab.sessions)
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
        for id in announcedForms { host?.hud.dismiss(id: formHUDID(id)) }
        host?.hud.dismiss(id: Self.doneHUDID)
        host?.hud.dismiss(id: Self.failedHUDID)
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

    var showsDoneCards: Bool {
        host?.preferences.value(forKey: "doneCards", default: true) ?? true
    }

    var showsFailureCards: Bool {
        host?.preferences.value(forKey: "failureCards", default: true) ?? true
    }

    var showsQuestionCards: Bool {
        host?.preferences.value(forKey: "questionCards", default: true) ?? true
    }

    func select(_ tab: WidgetTab) {
        self.tab = tab
        host?.preferences.setValue(tab, forKey: "tab")
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
                guard !server.isLocal else { return quota }
                return ProviderQuota(
                    id: "\(server.id).\(quota.id)", provider: quota.provider, name: quota.name,
                    plan: quota.plan, server: server.label, windows: quota.windows
                )
            }
        }
    }

    // MARK: Feeds

    /// Connects, seeds, streams, and starts over when the stream drops. Waits
    /// on `/health` while every direct address is down, which costs no token,
    /// and falls back to the relay when the server has one.
    private func runFeed(_ initial: ChamberServer) async {
        var server = initial
        var backoff: TimeInterval = 2
        var lastEventID: String?
        while !Task.isCancelled {
            var wait = backoff
            do {
                guard let route = try await openRoute(to: server) else {
                    // Desktop may have moved the server since the settings were read.
                    if let moved = await movedServer(server) {
                        server = moved
                        continue
                    }
                    setConnection(.offline, for: server.id)
                    try? await Task.sleep(for: .seconds(15))
                    continue
                }
                defer { if case let .relay(tunnel) = route { Task { await tunnel.close() } } }
                let client = OpenChamberClient(server: server, route: route)
                clients[server.id] = client
                serverStates[server.id]?.route = route.description
                setConnection(.connecting, for: server.id)
                apply(try await client.seed(), from: server.id)
                apply(.sessionsListed(try await client.recentSessions()), from: server.id)
                let stream = try await client.events(after: lastEventID)
                setConnection(.live, for: server.id)
                backoff = 2
                wait = 2
                refreshUsage(on: server.id, ifOlderThan: 60)
                // shortcut: a feed that fell back to the relay stays on it until
                // the stream drops; it does not probe for the direct address coming back.
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
                wait = 60
            } catch let error as RelayError where error.isDuplicateClient {
                // The relay gave this device's leg to another client. Taking it
                // back at once would drop that one in turn, so stand aside.
                setConnection(.failed(error.localizedDescription), for: server.id)
                wait = 600
            } catch is CancellationError {
                return
            } catch {
                setConnection(.failed(error.localizedDescription), for: server.id)
                host?.log.error("\(server.label): event stream ended: \(error.localizedDescription)")
            }
            try? await Task.sleep(for: .seconds(wait))
            backoff = min(backoff * 2, 60)
        }
    }

    /// Where an unreachable server went: the settings file's addresses when they
    /// changed, else, for this Mac, the port the running Desktop serves on,
    /// whatever the file says.
    private func movedServer(_ server: ChamberServer) async -> ChamberServer? {
        if let fresh = DesktopServers.load().first(where: { $0.id == server.id }), fresh != server {
            return fresh
        }
        guard server.isLocal else { return nil }
        let pids = NSRunningApplication.runningApplications(withBundleIdentifier: DesktopLinks.bundleID).map(\.processIdentifier)
        for pid in pids {
            let ports = await Task.detached { DesktopServers.listeningPorts(of: pid) }.value
            for port in ports {
                guard let url = URL(string: "http://127.0.0.1:\(port)"), !server.directURLs.contains(url),
                      await OpenChamberClient.isReachable(url) else { continue }
                host?.log.info("This Mac answers on port \(port), not where Desktop's settings say")
                var moved = server
                moved.directURLs = [url]
                return moved
            }
        }
        return nil
    }

    /// The first direct address that answers `/health`, else a relay tunnel
    /// with its handshake done, else nil when the server is unreachable.
    private func openRoute(to server: ChamberServer) async throws -> Route? {
        for url in server.directURLs where await OpenChamberClient.isReachable(url) {
            return .direct(url)
        }
        guard let relay = server.relay else { return nil }
        let tunnel = RelayTunnel(config: relay)
        do {
            try await tunnel.connect(appVersion: "droplet-\(host?.environment.appVersion ?? "unknown")")
        } catch {
            await tunnel.close()
            throw error
        }
        return .relay(tunnel)
    }

    private func setConnection(_ connection: Connection, for serverID: String) {
        guard serverStates[serverID]?.connection != connection else { return }
        serverStates[serverID]?.connection = connection
    }

    private func apply(_ event: ActivityEvent, from serverID: String) {
        guard var server = serverStates[serverID] else { return }
        let wasBusy = !server.activity.busySessionIDs.isEmpty
        var ended: (() -> Void)?
        if case let .executionEnded(id, outcome, at, error) = event {
            let turn = server.activity.activity[id]?.busySince.map { at.timeIntervalSince($0) }
            ended = { [weak self] in self?.announceEnd(of: id, outcome: outcome, error: error, turn: turn) }
        }
        server.activity.apply(event)
        serverStates[serverID] = server
        lookUpUnknownSessions(on: serverID)
        if wasBusy, server.activity.busySessionIDs.isEmpty {
            // A turn just ended: usage moved, and this is the moment it is worth asking.
            refreshUsage(on: serverID, ifOlderThan: 30)
        }
        publish()
        ended?()
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

    /// Opens the session in OpenChamber Desktop, on the instance that owns it:
    /// the link names it, and Desktop opens the session there, in place or in
    /// that instance's window.
    ///
    /// Desktop 2.5.0 and older ignore the name and look the session up on
    /// whatever instance the main window shows when the link arrives. For
    /// them a remote session switches the window to its host first and sends
    /// the session once the switch has had time to land; a relay host is
    /// switched in the renderer, well after the link would have been read.
    func openSession(_ id: String) {
        // shortcut: Droppy's workspace.open refuses every scheme but http(s), mailto and file, and DroppyKit has no way to declare one, so this personal droplet opens the link itself; a Store build needs Droppy to allow openchamber://.
        let serverID = serverID(forSession: id)
        if let version = Self.installedDesktopVersion, DesktopLinks.namesHosts(version: version) {
            // Desktop opens a session in the main window without raising it, so
            // another host's window in front hides it and the click seems to do
            // nothing. Raising the main window first fixes that, and a session of
            // another host still ends up in that host's window, which Desktop raises.
            // shortcut: drop the focus link once Desktop raises the window it opens a session in.
            if let focus = DesktopLinks.focus { NSWorkspace.shared.open(focus) }
            if let url = DesktopLinks.session(id, host: serverID) { NSWorkspace.shared.open(url) }
            return
        }

        // shortcut: the switch-and-wait below is for Desktop 2.5.0 and older; delete it once that version is gone.
        guard let url = DesktopLinks.session(id, host: nil) else { return }
        guard let serverID, serverID != ChamberServer.localID, let hostURL = DesktopLinks.host(serverID) else {
            // shortcut: a local session does not switch Desktop back from a remote host, since the switch reloads the window even when it is already there; send openchamber://host/local first if that bites.
            NSWorkspace.shared.open(url)
            return
        }
        NSWorkspace.shared.open(hostURL)
        // shortcut: a fixed wait for Desktop's host switch, since nothing tells us it finished.
        Task {
            try? await Task.sleep(for: .seconds(3))
            NSWorkspace.shared.open(url)
        }
    }

    /// The installed Desktop's version, read from disk each time: Desktop
    /// updates itself while Droppy keeps running.
    private static var installedDesktopVersion: String? {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: DesktopLinks.bundleID) else { return nil }
        return NSDictionary(contentsOf: app.appending(path: "Contents/Info.plist"))?["CFBundleShortVersionString"] as? String
    }

    /// Keeps the shelf open while a usage card hangs below it, so moving the
    /// pointer into the card does not close the shelf under it.
    func holdShelfOpen(_ holds: Bool) {
        _ = host?.shelf.setHoldsOpen(holds)
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
        announceNewForms()

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
                expandedWidgetID: Self.widgetID.rawValue
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

    /// A card for each new request, up until it is answered here or anywhere
    /// else. "Always" is not offered here: a standing rule is not something to
    /// grant from a card that passes in front of you.
    private func announceNewPermissions() {
        let current = Set(state.permissions.map(\.id))
        for gone in announcedPermissions.subtracting(current) { host?.hud.dismiss(id: hudID(gone)) }
        announcedPermissions.formIntersection(current)

        guard showsPermissionCards, let host else { return }
        for permission in state.permissions where !announcedPermissions.contains(permission.id) {
            announcedPermissions.insert(permission.id)
            // A request must not wait behind the usage page.
            if tab != .sessions { tab = .sessions }
            let session = state.sessions[permission.sessionID]
            let command = permission.resources.joined(separator: "\n")
            let verb = permission.action == "bash" || permission.action == "shell" ? "run" : permission.action
            let meta = [session?.project, serverLabel(forSession: permission.sessionID)].compactMap { $0 }.joined(separator: " · ")
            let request = DropletHUDRequest(
                id: hudID(permission.id),
                duration: nil,
                priority: .high,
                accessibilityLabel: "\(session?.title ?? "A session") asks to \(verb) \(command)",
                isExpanded: true,
                expandedContentHeight: 104
            ) {
                PermissionStrip(action: permission.action)
            } expanded: { [weak self] in
                // The host keeps these builders, so they hold the droplet weakly.
                NoticeCard(
                    provider: session?.providerID ?? "", symbol: "hand.raised.fill", tint: .orange,
                    title: session?.title ?? "A session", status: "Wants to \(verb)", meta: meta,
                    detail: command.isEmpty ? permission.action : command, style: .code,
                    actions: [
                        NoticeAction(title: "Allow once", role: .accent) { self?.reply(to: permission, decision: "once") },
                        NoticeAction(title: "Reject", role: .destructive) { self?.reply(to: permission, decision: "reject") },
                    ],
                    onOpen: { self?.openSession(permission.sessionID) }
                )
            }
            _ = host.hud.present(request)
        }
    }

    private static let doneHUDID = "openchamber.done"
    private static let failedHUDID = "openchamber.failed"
    private func formHUDID(_ formID: String) -> String { "openchamber.form.\(formID)" }

    /// OpenChamber in front already shows what the cards would say.
    private var openChamberIsInFront: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == DesktopLinks.bundleID
    }

    /// A card when a turn ends or fails, the way OpenChamber's own notifications
    /// word it: the session, its project, and the last message or the error.
    /// A subagent's turn is part of its parent's, and a session we have no
    /// record of yet could be one, so neither says anything.
    private func announceEnd(of id: String, outcome: ExecutionOutcome, error: String?, turn: TimeInterval?) {
        guard outcome != .interrupted, let host, !openChamberIsInFront,
              let session = state.sessions[id], session.parentID == nil else { return }
        let place = [session.project, serverLabel(forSession: id)].compactMap { $0 }
        let open: @MainActor () -> Void = { [weak self] in self?.openSession(id) }

        if outcome == .failed {
            guard showsFailureCards else { return }
            _ = host.hud.present(DropletHUDRequest(
                id: Self.failedHUDID, duration: 10, priority: .high,
                accessibilityLabel: "\(session.title) failed", isExpanded: true, expandedContentHeight: 72
            ) {
                NoticeStrip(motion: .failed, symbol: "exclamationmark.triangle.fill", label: "Failed", tint: .red)
            } expanded: {
                NoticeCard(
                    provider: session.providerID ?? "", symbol: "exclamationmark", tint: .red, title: session.title,
                    status: ["Failed", turn.map { "after \(Formatting.elapsed($0))" }].compactMap { $0 }.joined(separator: " "),
                    meta: place.joined(separator: " · "), detail: error ?? "The turn failed.", style: .code, onOpen: open
                )
            })
            return
        }

        guard showsDoneCards else { return }
        let now = Date()
        recentTurnEnds = recentTurnEnds.filter { now.timeIntervalSince($0) < 5 } + [now]
        let others = recentTurnEnds.count - 1
        let last = state.activity[id]?.lastText
        _ = host.hud.present(DropletHUDRequest(
            id: Self.doneHUDID, duration: 5,
            accessibilityLabel: "\(session.title) is done", isExpanded: true, expandedContentHeight: last == nil ? 36 : 72
        ) {
            NoticeStrip(motion: .still, symbol: "checkmark.circle.fill", label: others > 0 ? "\(others + 1) done" : "Done", tint: .green)
        } expanded: {
            NoticeCard(
                provider: session.providerID ?? "", symbol: "checkmark", tint: .green, title: session.title,
                status: ["Done", turn.map { "in \(Formatting.elapsed($0))" }].compactMap { $0 }.joined(separator: " "),
                meta: ((others > 0 ? ["+\(others) more"] : []) + place).joined(separator: " · "),
                detail: last, style: .text, onOpen: open
            )
        })
    }

    /// A card for each new question, up until it is answered. Forms can hold
    /// any number of fields, so they are answered in OpenChamber.
    private func announceNewForms() {
        let current = Set(state.forms.map(\.id))
        for gone in announcedForms.subtracting(current) { host?.hud.dismiss(id: formHUDID(gone)) }
        announcedForms.formIntersection(current)

        guard showsQuestionCards, let host else { return }
        for form in state.forms where !announcedForms.contains(form.id) {
            announcedForms.insert(form.id)
            if tab != .sessions { tab = .sessions }
            guard !openChamberIsInFront else { continue }
            let session = state.sessions[form.sessionID]
            let meta = ([form.moreQuestions > 0 ? "+\(form.moreQuestions) more" : nil, session?.project, serverLabel(forSession: form.sessionID)])
                .compactMap { $0 }.joined(separator: " · ")
            _ = host.hud.present(DropletHUDRequest(
                id: formHUDID(form.id), duration: nil, priority: .high,
                accessibilityLabel: "\(session?.title ?? "A session") asks: \(form.title)", isExpanded: true, expandedContentHeight: 104
            ) {
                NoticeStrip(motion: .waiting, symbol: "questionmark.bubble.fill", label: "Question", tint: .orange)
            } expanded: { [weak self] in
                NoticeCard(
                    provider: session?.providerID ?? "", symbol: "questionmark", tint: .orange,
                    title: session?.title ?? "A session", status: "Asks", meta: meta, detail: form.title, style: .question,
                    actions: [NoticeAction(title: "Answer in OpenChamber", role: .accent) { self?.openSession(form.sessionID) }],
                    onOpen: { self?.openSession(form.sessionID) }
                )
            })
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
            serverStates[serverID]?.usage = ProviderQuota.distinct(results)
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
                let key = "\(provider.id).\(window.id).\(Int(threshold)).\(window.resetAt?.timeIntervalSince1970 ?? 0)"
                guard usageWarnings.insert(key).inserted else { continue }
                let name = "\(provider.name) \(Formatting.windowLabel(window, in: provider))"
                _ = host.hud.present(DropletHUDRequest(id: "openchamber.usage", duration: 4, accessibilityLabel: "\(name) at \(Int(used))%") {
                    UsageStrip(provider: provider.provider, percent: used, label: name)
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
                id: Self.widgetID,
                title: "OpenChamber",
                systemImage: "cube",
                layoutTraits: ShelfWidgetLayoutTraits(
                    preferredSoloWidth: 440,
                    preferredPairedWidth: 240,
                    contentHeight: .fixed(176)
                ),
                searchKeywords: ["opencode", "agent", "session", "permission", "approve", "quota", "usage", "claude", "codex"]
            ),
        ]
    }

    public func makeWidgetView(_ id: ShelfWidgetID, context: ShelfWidgetContext) -> AnyView {
        AnyView(OpenchamberWidget(droplet: self, context: context))
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
        let mac = ChamberServer(id: ChamberServer.localID, label: "This Mac", directURLs: [URL(string: "http://127.0.0.1:4097")!], relay: nil, token: "", headers: [:])
        let remote = ChamberServer(id: "remote", label: "devbox", directURLs: [URL(string: "http://192.168.1.30:4097")!], relay: nil, token: "", headers: [:])
        servers = [mac, remote]

        var local = ServerState(connection: .live)
        local.activity.apply(.sessionsListed([
            SessionInfo(id: "s1", title: "Fix notification title cache", directory: "/Users/me/projects/openchamber", parentID: nil, providerID: "anthropic", modelID: "claude-opus-5-5"),
            SessionInfo(id: "s2", title: "Design the droplet", directory: "/Users/me/projects/openchamber-droplet", parentID: nil, providerID: "anthropic"),
        ]))
        local.activity.apply(.executionStarted(sessionID: "s1", at: now.addingTimeInterval(-252)))
        for (index, mark) in [true, true, false, true, true].enumerated() {
            local.activity.apply(.toolStarted(sessionID: "s1", callID: "c\(index)", name: "read"))
            local.activity.apply(.toolFinished(sessionID: "s1", callID: "c\(index)", succeeded: mark))
        }
        local.activity.apply(.toolStarted(sessionID: "s1", callID: "c9", name: "edit"))
        local.activity.apply(.toolCalled(sessionID: "s1", callID: "c9", name: nil, target: "session-runtime.js"))
        local.activity.apply(.textEnded(sessionID: "s1", text: "23/23 tests pass. Next: build, validate and the shots of the Sessions page."))
        local.activity.apply(.executionStarted(sessionID: "s2", at: now.addingTimeInterval(-48)))
        local.activity.apply(.permissionAsked(PendingPermission(
            id: "p1", sessionID: "s2", action: "bash",
            resources: ["swift build -c release --product Openchamber"],
            directory: "/Users/me/projects/openchamber-droplet"
        )))
        local.usage = [
            ProviderQuota(id: "claude", provider: "claude", name: "Claude", plan: "Max (5x)", windows: [
                QuotaWindow(name: "5h", usedPercent: 3, windowSeconds: 18_000, resetAt: now.addingTimeInterval(15_660)),
                QuotaWindow(name: "7d", usedPercent: 7, windowSeconds: 604_800, resetAt: now.addingTimeInterval(518_400)),
                QuotaWindow(name: "7d", model: "Fable", usedPercent: 0, windowSeconds: 604_800, resetAt: now.addingTimeInterval(518_400)),
            ]),
            ProviderQuota(id: "opencode-go", provider: "opencode-go", name: "OpenCode Go", plan: nil, windows: [
                QuotaWindow(name: "monthly", usedPercent: 3, windowSeconds: 2_592_000, resetAt: now.addingTimeInterval(1_900_000)),
            ]),
        ]

        var work = ServerState(connection: .live)
        work.activity.apply(.sessionsListed([SessionInfo(id: "w1", title: "API migration", directory: "/home/me/work/api", parentID: nil)]))
        work.activity.apply(.executionStarted(sessionID: "w1", at: now.addingTimeInterval(-610)))
        work.usage = [
            ProviderQuota(id: "codex", provider: "codex", name: "Codex", plan: "Pro", windows: [
                QuotaWindow(name: "5h", usedPercent: 0, windowSeconds: 18_000, resetAt: now.addingTimeInterval(9_600)),
            ]),
        ]
        serverStates = [mac.id: local, remote.id: work]
        publish(now: now)
    }
}

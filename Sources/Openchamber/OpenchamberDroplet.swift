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
        /// The catalog's models, keyed `provider/model`.
        var models: [String: CatalogModel] = [:]
    }

    /// What the agents did today, for the widget when nothing is running.
    struct TodayStats: Codable, Equatable {
        /// `2026-10-23`, in this Mac's calendar.
        var day: String
        var turns = 0
        var seconds: TimeInterval = 0
        /// Requests and questions settled, here or in OpenChamber.
        var answered = 0
        var lines = TurnDiff()

        static func key(for date: Date) -> String {
            let day = Calendar.current.dateComponents([.year, .month, .day], from: date)
            return String(format: "%04d-%02d-%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0)
        }
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
    @Published private(set) var today = TodayStats(day: TodayStats.key(for: Date()))
    /// Each recent day's numbers, by `TodayStats.day`.
    @Published private(set) var days: [String: TodayStats] = [:]
    /// What each session's last finished turn changed, once asked.
    @Published private(set) var turnDiffs: [String: TurnDiff] = [:]
    /// The session the full-shelf view shows.
    @Published private(set) var focusedSessionID: String?
    /// Sessions that look stuck, and how; minutes change once a minute.
    @Published private(set) var stuck: [String: StuckReason] = [:]
    /// Sessions let run without asking, until when.
    @Published private(set) var autoRuns: [String: AutoRun] = [:]
    @Published private(set) var voice: VoiceState = .idle
    /// Commands, messages and errors stay off the notch while this is on.
    @Published private(set) var presenting = false

    enum StuckReason: Equatable {
        /// Not one event for this long.
        case quiet(minutes: Int)
        /// One call running this long with nothing else moving, a dev server say.
        case stalled(command: String, minutes: Int)
        /// The same call failing again and again.
        case looping(command: String, failures: Int)
    }

    /// A session OpenChamber auto-approves for a while, and the mode it goes back to.
    struct AutoRun: Codable, Equatable {
        let sessionID: String
        let serverID: String
        let directory: String
        let until: Date
        let restore: String
    }

    enum VoiceState: Equatable {
        case idle
        case listening(sessionID: String, text: String)
    }

    /// One turn that ended while you were away.
    struct AwayEntry: Equatable {
        let sessionID: String
        let title: String
        let failed: Bool
        var headline: String
        var diff: TurnDiff?
    }

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
    /// Words streamed since the last flush, per server and session: a delta
    /// comes per token, and the notch redraws four times a second at most.
    private var pendingText: [String: [String: String]] = [:]
    private var textFlush: Task<Void, Never>?
    private var focusPresentation: ExpandedSurfacePresentation?
    /// When each session last sent anything, and last moved a step on. Kept
    /// out of `@Published`: deltas update them per token.
    private var lastHeard: [String: Date] = [:]
    private var lastProgress: [String: Date] = [:]
    private var announcedStuck: Set<String> = []
    /// Sessions whose stuck card was waved off for the rest of their turn.
    private var stuckSnoozed: Set<String> = []
    private var autoRunTasks: [String: Task<Void, Never>] = [:]
    private var voiceCapture: VoiceCapture?
    private var awayWatcher: AwayWatcher?
    private var clipboardWatcher: ClipboardWatcher?
    private var awayLog: [AwayEntry] = []
    private let activitySubject = CurrentValueSubject<LiveActivityState?, Never>(nil)
    private let lockScreenSubject = CurrentValueSubject<LockScreenStatusEntry?, Never>(nil)

    // MARK: Lifecycle

    public func activate(host: DropletHost) throws {
        self.host = host
        tab = host.preferences.value(forKey: "tab", default: WidgetTab.sessions)
        if let stored = host.preferences.value(forKey: "today", as: TodayStats.self), stored.day == TodayStats.key(for: Date()) {
            today = stored
        }
        days = host.preferences.value(forKey: "days", default: [String: TodayStats]())
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
        host.shortcuts.register(id: "voice-reply", title: "Talk to the OpenChamber session that needs you", defaultShortcut: nil) { [weak self] in
            self?.toggleVoice()
        }
        host.shortcuts.register(id: "presenting", title: "Hide OpenChamber's commands and messages", defaultShortcut: nil) { [weak self] in
            guard let self else { return }
            self.setPresenting(!self.presenting)
        }
        presenting = host.preferences.value(forKey: "presenting", default: false)
        if !host.environment.isHarness {
            resumeAutoRuns()
            let away = AwayWatcher { [weak self] since in self?.cameBack(awaySince: since) }
            away.start()
            awayWatcher = away
            clipboardWatcher = ClipboardWatcher { [weak self] text in self?.offerCopiedError(text) }
            if offersCopiedErrors { clipboardWatcher?.start() }
        }
        host.log.info("OpenChamber activated")
    }

    public func deactivate() {
        // A session let run must not stay on auto because Droppy quit: hand
        // each back its mode while the clients are still here; the stored
        // runs cover a crash.
        for run in autoRuns.values { endAutoRun(run) }
        stopFeeds()
        ticker?.cancel()
        ticker = nil
        for id in ["approve-oldest", "open-waiting", "voice-reply", "presenting"] { host?.shortcuts.unregister(id: id) }
        voiceCapture?.stop()
        voiceCapture = nil
        awayWatcher?.stop()
        awayWatcher = nil
        clipboardWatcher?.stop()
        clipboardWatcher = nil
        autoRunTasks.values.forEach { $0.cancel() }
        autoRunTasks = [:]
        for id in announcedPermissions { host?.hud.dismiss(id: hudID(id)) }
        for id in announcedForms { host?.hud.dismiss(id: formHUDID(id)) }
        for id in announcedStuck { host?.hud.dismiss(id: stuckHUDID(id)) }
        for id in [Self.doneHUDID, Self.failedHUDID, Self.voiceHUDID, Self.awayHUDID, Self.clipboardHUDID, Self.undoHUDID] {
            host?.hud.dismiss(id: id)
        }
        if focusPresentation != nil { host?.notchSurface.dismissExpandedSurface(Self.focusSurfaceID) }
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

    var showsStuckCards: Bool {
        host?.preferences.value(forKey: "stuckCards", default: true) ?? true
    }

    var recapsAway: Bool {
        host?.preferences.value(forKey: "awayRecap", default: true) ?? true
    }

    var writesHeadlines: Bool {
        host?.preferences.value(forKey: "awayHeadlines", default: true) ?? true
    }

    /// Off unless asked for: the pasteboard is the user's.
    var offersCopiedErrors: Bool {
        host?.preferences.value(forKey: "clipboardOffers", default: false) ?? false
    }

    static let defaultQuickReplies = ["Commit it", "Run the tests", "Continue"]

    /// The one-click answers on a finished turn's card, empty ones left out.
    var quickReplies: [String] {
        (host?.preferences.value(forKey: "quickReplies", default: Self.defaultQuickReplies) ?? Self.defaultQuickReplies)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    func setPresenting(_ on: Bool) {
        presenting = on
        host?.preferences.setValue(on, forKey: "presenting")
        if on { host?.hud.dismiss(id: Self.clipboardHUDID) }
    }

    func setOffersCopiedErrors(_ on: Bool) {
        setPreference(on, forKey: "clipboardOffers")
        on ? clipboardWatcher?.start() : clipboardWatcher?.stop()
    }

    /// The secret a `droppy://droplet/openchamber/…` link needs to act: any
    /// web page can open that scheme, and none of them can know this.
    var linkToken: String {
        if let token = host?.preferences.value(forKey: "linkToken", default: ""), !token.isEmpty { return token }
        let token = (0..<24).map { _ in "abcdefghijkmnopqrstuvwxyz23456789".randomElement()! }.map(String.init).joined()
        host?.preferences.setValue(token, forKey: "linkToken")
        return token
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
        textFlush?.cancel()
        textFlush = nil
        pendingText = [:]
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
                let sessions = try await client.recentSessions()
                apply(.sessionsListed(sessions), from: server.id)
                // OpenCode reads its catalog through a project; the most recent
                // session's is one it has open. Without it, sessions show model ids.
                if let directory = sessions.first?.directory, !directory.isEmpty {
                    let id = server.id
                    Task { [weak self] in
                        if let models = try? await client.models(directory: directory) { self?.serverStates[id]?.models = models }
                    }
                }
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
        let now = Date()
        if let id = event.sessionID { lastHeard[id] = now }
        switch event {
        case .heard:
            return
        case let .toolStarted(id, _, _), let .toolFinished(id, _, _), let .stepEnded(id, _), let .textEnded(id, _):
            lastProgress[id] = now
        case let .executionStarted(id, _), let .executionEnded(id, _, _, _):
            lastProgress[id] = now
            // A new turn, or the end of one: a waved-off stuck card may speak again.
            stuckSnoozed.remove(id)
        default:
            break
        }
        switch event {
        case let .textStreamed(id, delta):
            pendingText[serverID, default: [:]][id, default: ""] += delta
            scheduleTextFlush()
            return
        case let .textStarted(id), let .textEnded(id, _), let .executionEnded(id, _, _, _):
            // The block these words belonged to is over; the event says the rest.
            pendingText[serverID]?[id] = nil
        case let .executionStarted(id, _):
            // Last turn's diff does not describe this one.
            if turnDiffs[id] != nil { turnDiffs[id] = nil }
        default:
            break
        }
        let wasBusy = !server.activity.busySessionIDs.isEmpty
        var ended: (() -> Void)?
        if case let .executionEnded(id, outcome, at, error) = event {
            let turn = server.activity.activity[id]?.busySince.map { at.timeIntervalSince($0) }
            if outcome != .interrupted, server.activity.sessions[id]?.parentID == nil, server.activity.sessions[id] != nil {
                countToday { $0.turns += 1; $0.seconds += turn ?? 0 }
            }
            ended = { [weak self] in self?.announceEnd(of: id, outcome: outcome, error: error, turn: turn) }
        }
        switch event {
        case let .permissionSettled(sessionID, requestID) where server.activity.permissions.contains { $0.id == requestID && $0.sessionID == sessionID }:
            countToday { $0.answered += 1 }
        case let .formSettled(sessionID, formID) where server.activity.forms.contains { $0.id == formID && $0.sessionID == sessionID }:
            countToday { $0.answered += 1 }
        default:
            break
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

    private func scheduleTextFlush() {
        guard textFlush == nil else { return }
        textFlush = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled else { return }
            textFlush = nil
            let pending = pendingText
            pendingText = [:]
            for (serverID, sessions) in pending {
                for (id, delta) in sessions { serverStates[serverID]?.activity.apply(.textStreamed(sessionID: id, delta: delta)) }
            }
            publish()
        }
    }

    /// Adds to today's numbers, starting the day over when the date has moved
    /// on, and keeps the last two weeks of days for the week strip.
    private func countToday(_ change: (inout TodayStats) -> Void) {
        let day = TodayStats.key(for: Date())
        var stats = today.day == day ? today : TodayStats(day: day)
        change(&stats)
        stats.lines.names = []
        today = stats
        days[day] = stats
        if days.count > 14 {
            let keep = Set(days.keys.sorted().suffix(14))
            days = days.filter { keep.contains($0.key) }
        }
        host?.preferences.setValue(stats, forKey: "today")
        host?.preferences.setValue(days, forKey: "days")
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

    /// A session's model as the catalog of the server it runs on lists it.
    private func catalogModel(forSession id: String) -> CatalogModel? {
        guard let serverID = serverID(forSession: id), let session = state.sessions[id],
              let provider = session.providerID, let model = session.modelID else { return nil }
        return serverStates[serverID]?.models["\(provider)/\(model)"]
    }

    /// The catalog's name for a session's model, `Opus 5.5`.
    func modelName(forSession id: String) -> String? { catalogModel(forSession: id)?.name }

    /// How full the session's context window is, 0 through 1, once a step has said.
    func contextShare(forSession id: String) -> Double? {
        guard let tokens = state.activity[id]?.contextTokens else { return nil }
        return catalogModel(forSession: id)?.contextShare(of: tokens)
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

    /// Answers a one-pick form with one of its options.
    func answer(_ form: PendingForm, with option: FormChoice.Option) {
        guard let choice = form.choice, let serverID = serverID(forSession: form.sessionID), let client = clients[serverID] else { return }
        Task {
            do {
                try await client.answer(form, key: choice.key, value: option.value)
                apply(.formSettled(sessionID: form.sessionID, formID: form.id), from: serverID)
                host?.feedback.play(.success)
            } catch {
                host?.log.error("form reply failed: \(error.localizedDescription)")
                host?.feedback.play(.failure)
            }
        }
    }

    static let focusSurfaceID: ExpandedSurfaceID = "session"

    /// Takes the whole shelf over with one session: its steps, its words, Stop.
    func focus(_ id: String) {
        focusedSessionID = id
        refreshBranch(forSession: id)
        focusPresentation = host?.notchSurface.presentExpandedSurface(ExpandedSurfacePresentationRequest(surfaceID: Self.focusSurfaceID))
    }

    func closeFocus() {
        host?.notchSurface.dismissExpandedSurface(Self.focusSurfaceID)
    }

    /// The project's branch, asked once per directory; `vcs.branch.updated` keeps it current.
    private func refreshBranch(forSession id: String) {
        guard let directory = state.sessions[id]?.directory, !directory.isEmpty, state.branches[directory] == nil,
              let serverID = serverID(forSession: id), let client = clients[serverID] else { return }
        Task {
            if let branch = try? await client.branch(directory: directory) {
                apply(.branchChanged(directory: directory, branch: branch), from: serverID)
            }
        }
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

    // MARK: Talking back

    /// Who a reply that names no session goes to: the one open over the shelf,
    /// else the one that waits on you, else the one that finished in the last
    /// half hour, else the one that has run longest.
    var replyTarget: String? {
        if let focusedSessionID { return focusedSessionID }
        if let waiting = state.permissions.first?.sessionID ?? state.forms.first?.sessionID { return waiting }
        let finished = state.activity
            .filter { state.sessions[$0.key]?.parentID == nil }
            .compactMap { id, activity in activity.finishedAt.map { (id, $0) } }
            .max { $0.1 < $1.1 }
        if let finished, Date().timeIntervalSince(finished.1) < 30 * 60 { return finished.0 }
        return state.busySessionIDs.first
    }

    /// Sends a session a message; one that is busy gets it when its turn ends.
    func send(_ text: String, to id: String, files: [URL] = []) {
        guard let serverID = serverID(forSession: id), let client = clients[serverID] else {
            host?.feedback.play(.failure)
            return
        }
        let queue = state.activity[id]?.isBusy == true
        let directory = state.sessions[id]?.directory
        Task {
            do {
                try await client.prompt(sessionID: id, text: text, files: files, queue: queue, directory: directory)
                host?.feedback.play(.success)
            } catch {
                host?.log.error("message to a session failed: \(error.localizedDescription)")
                host?.feedback.play(.failure)
            }
        }
    }

    /// Files dropped on a session. Paths on this Mac mean nothing to a remote
    /// host, so only a session on this Mac takes them.
    func dropFiles(_ urls: [URL], on id: String) {
        guard !urls.isEmpty else { return }
        guard serverID(forSession: id) == ChamberServer.localID else {
            host?.log.info("dropped files go to sessions on this Mac only")
            host?.feedback.play(.failure)
            return
        }
        host?.feedback.play(.drop)
        let names = urls.map(\.lastPathComponent).joined(separator: ", ")
        send("Take a look at \(names).", to: id, files: urls)
    }

    // MARK: Undo

    static let undoHUDID = "openchamber.undo"

    /// Rolls the last turn back after asking: its file changes, and its
    /// messages hidden. Reversible until the session's next message.
    func undoTurn(_ id: String) {
        guard let prompt = state.activity[id]?.promptID, let session = state.sessions[id],
              let serverID = serverID(forSession: id), let client = clients[serverID] else { return }
        let diff = turnDiffs[id]
        let names = diff?.names ?? []
        let files = names.isEmpty ? "the files it changed"
            : names.count <= 3 ? Formatting.list(names) : Formatting.list(Array(names.prefix(2)) + ["\(names.count - 2) more"])
        let lines = diff.map { " +\($0.additions) −\($0.deletions) goes away." } ?? ""
        guard DropletConfirmationDialog.present(
            title: "Undo this turn?",
            message: "Puts \(files) back as they were before “\(session.title)” ran, and hides the turn's messages.\(lines) You can bring it back until the session gets its next message.",
            confirmTitle: "Undo",
            symbol: "arrow.uturn.backward"
        ) else { return }
        host?.hud.dismiss(id: Self.doneHUDID)
        Task { [weak self] in
            do {
                try await client.stageRevert(sessionID: id, to: prompt, directory: session.directory)
                guard let self else { return }
                turnDiffs[id] = nil
                host?.feedback.play(.success)
                _ = host?.hud.present(DropletHUDRequest(
                    id: Self.undoHUDID, duration: 10, accessibilityLabel: "\(session.title) undone", isExpanded: true, expandedContentHeight: 72
                ) {
                    NoticeStrip(motion: .still, symbol: "arrow.uturn.backward", label: "Undone", tint: AdaptiveColors.notchSurfacePrimaryText)
                } expanded: { [weak self] in
                    NoticeCard(
                        provider: session.providerID ?? "", symbol: "arrow.uturn.backward", tint: AdaptiveColors.notchSurfacePrimaryText,
                        title: session.title, status: "Turn undone", meta: session.project, detail: nil, style: .text,
                        actions: [NoticeAction(title: "Bring it back", role: .quiet) { self?.bringBack(id) }],
                        onOpen: { self?.openSession(id) }
                    )
                })
            } catch {
                self?.host?.log.error("undo failed: \(error.localizedDescription)")
                self?.host?.feedback.play(.failure)
            }
        }
    }

    private func bringBack(_ id: String) {
        guard let serverID = serverID(forSession: id), let client = clients[serverID] else { return }
        let directory = state.sessions[id]?.directory
        host?.hud.dismiss(id: Self.undoHUDID)
        Task {
            do {
                try await client.clearRevert(sessionID: id, directory: directory)
                host?.feedback.play(.success)
            } catch {
                host?.log.error("bringing a turn back failed: \(error.localizedDescription)")
                host?.feedback.play(.failure)
            }
        }
    }

    // MARK: Let it run

    static let autoRunLength: TimeInterval = 15 * 60

    /// Allows this request and lets OpenChamber approve the session's next
    /// ones for a quarter of an hour, then hands it back the mode it had.
    func letRun(_ permission: PendingPermission) {
        let id = permission.sessionID
        guard let serverID = serverID(forSession: id), let client = clients[serverID] else { return }
        let directory = state.sessions[id]?.directory ?? permission.directory ?? ""
        reply(to: permission, decision: "once")
        Task {
            do {
                var previous = autoRuns[id]?.restore
                if previous == nil { previous = try await client.autoAcceptMode(sessionID: id) ?? "ask" }
                try await client.setAutoAccept(sessionID: id, mode: "auto", directory: directory)
                let run = AutoRun(sessionID: id, serverID: serverID, directory: directory,
                                  until: Date().addingTimeInterval(Self.autoRunLength), restore: previous == "auto" ? "ask" : previous ?? "ask")
                autoRuns[id] = run
                saveAutoRuns()
                scheduleEnd(of: run)
            } catch {
                host?.log.error("letting a session run failed: \(error.localizedDescription)")
                host?.feedback.play(.failure)
            }
        }
    }

    /// Ends a run now, from the badge or because its time is up.
    func endAutoRun(_ run: AutoRun) {
        autoRunTasks[run.sessionID]?.cancel()
        autoRunTasks[run.sessionID] = nil
        autoRuns[run.sessionID] = nil
        saveAutoRuns()
        guard let client = clients[run.serverID] else { return }
        Task { try? await client.setAutoAccept(sessionID: run.sessionID, mode: run.restore, directory: run.directory) }
    }

    /// Runs a crash or a quit left behind: each ends when it was due, the
    /// overdue ones as soon as their server is back.
    private func resumeAutoRuns() {
        let stored = host?.preferences.value(forKey: "autoRuns", default: [AutoRun]()) ?? []
        autoRuns = Dictionary(stored.map { ($0.sessionID, $0) }) { _, latest in latest }
        autoRuns.values.forEach(scheduleEnd(of:))
    }

    private func scheduleEnd(of run: AutoRun) {
        autoRunTasks[run.sessionID]?.cancel()
        autoRunTasks[run.sessionID] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, run.until.timeIntervalSinceNow)))
            // The server may still be connecting after a relaunch.
            for _ in 0..<60 where !Task.isCancelled && self?.clients[run.serverID] == nil {
                try? await Task.sleep(for: .seconds(2))
            }
            guard !Task.isCancelled, let self, autoRuns[run.sessionID] == run else { return }
            endAutoRun(run)
        }
    }

    private func saveAutoRuns() {
        host?.preferences.setValue(Array(autoRuns.values), forKey: "autoRuns")
    }

    // MARK: Stuck

    /// No event at all for this long reads as stuck.
    static let quietAfter: TimeInterval = 5 * 60
    /// One call running this long with no step moving on, a dev server say.
    static let stalledAfter: TimeInterval = 10 * 60

    private func stuckHUDID(_ id: String) -> String { "openchamber.stuck.\(id)" }

    /// What looks stuck now, and a card for each new one. A session waiting
    /// on you, retrying or compacting is not stuck.
    private func updateStuck(now: Date) {
        let waiting = Set(state.permissions.map(\.sessionID) + state.forms.map(\.sessionID))
        var next: [String: StuckReason] = [:]
        for id in state.busySessionIDs where !waiting.contains(id) {
            guard let activity = state.activity[id], activity.retry == nil, !activity.compacting else { continue }
            let since = activity.busySince ?? now
            let quiet = now.timeIntervalSince(lastHeard[id] ?? since)
            let still = now.timeIntervalSince(lastProgress[id] ?? since)
            if let repeated = activity.repeatedFailure {
                next[id] = .looping(command: repeated.call.object ?? repeated.call.verb, failures: repeated.failures)
            } else if quiet >= Self.quietAfter {
                next[id] = .quiet(minutes: Int(quiet / 60))
            } else if let call = activity.calls.last, call.mark == .running, still >= Self.stalledAfter {
                let narration = Narration(call: call)
                next[id] = .stalled(command: narration.object ?? narration.verb, minutes: Int(still / 60))
            }
        }
        if next != stuck { stuck = next }
        guard let host else { return }
        for id in announcedStuck where next[id] == nil { host.hud.dismiss(id: stuckHUDID(id)) }
        announcedStuck.formIntersection(next.keys)
        guard showsStuckCards, !openChamberIsInFront else { return }
        for (id, reason) in next where !announcedStuck.contains(id) && !stuckSnoozed.contains(id) {
            announcedStuck.insert(id)
            presentStuckCard(id, reason: reason)
        }
    }

    private func presentStuckCard(_ id: String, reason: StuckReason) {
        let session = state.sessions[id]
        let activity = state.activity[id] ?? SessionActivity()
        let (symbol, status, detail, keep): (String, String, String, String) = switch reason {
        case let .quiet(minutes):
            ("pause.fill", "Quiet for \(minutes) min", activity.currentCall.map { Narration(call: $0).sentence } ?? "No step running", "Keep waiting")
        case let .stalled(command, minutes):
            ("hourglass", "Running for \(minutes) min", command, "Keep waiting")
        case let .looping(command, failures):
            ("arrow.triangle.2.circlepath", "Going in circles", "\(command) failed \(failures) times", "Let it try")
        }
        let meta = [session?.project, serverLabel(forSession: id)].compactMap { $0 }.joined(separator: " · ")
        _ = host?.hud.present(DropletHUDRequest(
            id: stuckHUDID(id), duration: nil,
            accessibilityLabel: "\(session?.title ?? "A session"): \(status)", isExpanded: true, expandedContentHeight: 104
        ) {
            NoticeStrip(motion: .still, symbol: symbol, label: "Stuck?", tint: .yellow)
        } expanded: { [weak self] in
            NoticeCard(
                provider: session?.providerID ?? "", symbol: symbol, tint: .yellow, title: session?.title ?? "A session",
                status: status, meta: meta, detail: detail, style: .code, hidesDetail: self?.presenting ?? false,
                actions: [
                    NoticeAction(title: "Stop", role: .destructive) {
                        self?.interrupt(sessionID: id)
                        self?.host?.hud.dismiss(id: self?.stuckHUDID(id) ?? "")
                    },
                    NoticeAction(title: keep, role: .quiet) { self?.snoozeStuck(id) },
                ],
                onOpen: { self?.openSession(id) }
            )
        })
    }

    /// Waves a stuck card off for the rest of the session's turn.
    func snoozeStuck(_ id: String) {
        stuckSnoozed.insert(id)
        host?.hud.dismiss(id: stuckHUDID(id))
    }

    // MARK: Voice

    static let voiceHUDID = "openchamber.voice"

    var voiceIsReady: Bool {
        host?.permissions.status(for: .microphone) == .granted && host?.permissions.status(for: .speechRecognition) == .granted
    }

    /// Asked from the settings pane, never from the notch.
    func requestVoicePermissions() async {
        _ = await host?.permissions.request(.microphone)
        _ = await host?.permissions.request(.speechRecognition)
        objectWillChange.send()
    }

    /// The shortcut: the first press starts listening for the session a reply
    /// goes to, the second sends what was said.
    func toggleVoice() {
        if case .listening = voice { sendVoice(); return }
        guard let host else { return }
        guard voiceIsReady else {
            _ = host.workspace.openSettings()
            return
        }
        guard let target = replyTarget else {
            host.feedback.play(.failure)
            return
        }
        let capture = VoiceCapture(onText: { [weak self] text in
            guard let self, case let .listening(id, _) = voice else { return }
            voice = .listening(sessionID: id, text: text)
        }, onEnd: {})
        do {
            try capture.start()
        } catch {
            host.log.error("voice reply could not start: \(error.localizedDescription)")
            host.feedback.play(.failure)
            return
        }
        voiceCapture = capture
        voice = .listening(sessionID: target, text: "")
        _ = host.hud.present(DropletHUDRequest(
            id: Self.voiceHUDID, duration: nil, priority: .high,
            accessibilityLabel: "Listening for \(state.sessions[target]?.title ?? "a session")", isExpanded: true, expandedContentHeight: 104
        ) { [weak self] in
            if let self { VoiceStrip(droplet: self) }
        } expanded: { [weak self] in
            if let self { VoiceCard(droplet: self) }
        })
    }

    func sendVoice() {
        guard case let .listening(id, text) = voice else { return }
        cancelVoice()
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !words.isEmpty { send(words, to: id) }
    }

    func cancelVoice() {
        voiceCapture?.stop()
        voiceCapture = nil
        voice = .idle
        host?.hud.dismiss(id: Self.voiceHUDID)
    }

    // MARK: While you were away

    static let awayHUDID = "openchamber.away"

    /// A turn that ended while you were gone, with a headline: the server's
    /// small model writes one when allowed, the message's first sentence until then.
    private func noteWhileAway(_ id: String, title: String, failed: Bool, text: String?, directory: String) {
        awayLog.append(AwayEntry(sessionID: id, title: title, failed: failed,
                                 headline: Formatting.headline(from: text) ?? (failed ? "the turn failed" : "finished"), diff: nil))
        guard writesHeadlines, let text, !text.isEmpty, !directory.isEmpty,
              let serverID = serverID(forSession: id), let client = clients[serverID] else { return }
        let ask = "In eight words at most, say what this coding agent \(failed ? "ran into" : "did"). Answer with those words only.\n\n"
            + String(text.prefix(2_000))
        Task {
            guard let line = try? await client.generate(prompt: ask, directory: directory),
                  let headline = Formatting.headline(from: line),
                  let index = awayLog.lastIndex(where: { $0.sessionID == id }) else { return }
            awayLog[index].headline = headline
        }
    }

    /// One card for everything that happened while you were gone, instead of
    /// the pile of cards nobody saw.
    private func cameBack(awaySince since: Date) {
        let log = awayLog
        awayLog = []
        let minutes = Int(Date().timeIntervalSince(since) / 60)
        guard recapsAway, minutes >= 5, let host else { return }
        var seen: Set<String> = []
        let waiting = (state.permissions.map(\.sessionID) + state.forms.map(\.sessionID)).filter { seen.insert($0).inserted }
        // The latest turn of each session.
        let ended = Dictionary(log.map { ($0.sessionID, $0) }) { _, latest in latest }.values
            .filter { !waiting.contains($0.sessionID) }
            .sorted { $0.title < $1.title }
        guard !ended.isEmpty || !waiting.isEmpty else { return }
        let rows = min(4, ended.count + waiting.count)
        _ = host.hud.present(DropletHUDRequest(
            id: Self.awayHUDID, duration: 30,
            accessibilityLabel: "While you were away: \(ended.count) done, \(waiting.count) waiting", isExpanded: true,
            expandedContentHeight: CGFloat(30 + rows * 22 + 44)
        ) {
            NoticeStrip(motion: .still, symbol: "moon.fill", label: "While away", tint: AdaptiveColors.notchSurfacePrimaryText)
        } expanded: { [weak self] in
            if let self {
                AwayCard(droplet: self, minutes: minutes, ended: Array(ended), waiting: waiting)
            }
        })
    }

    // MARK: Copied errors

    static let clipboardHUDID = "openchamber.clipboard"

    /// Offers an error you just copied to the session it most likely belongs
    /// to. Nothing is sent until you press Send.
    private func offerCopiedError(_ text: String) {
        guard offersCopiedErrors, !presenting, !openChamberIsInFront, let host,
              let target = clipboardTarget(for: text), let session = state.sessions[target] else { return }
        let meta = ["You copied an error", session.project, serverLabel(forSession: target)].compactMap { $0 }.joined(separator: " · ")
        let excerpt = text.split(separator: "\n", omittingEmptySubsequences: true).prefix(2).joined(separator: "\n")
        _ = host.hud.present(DropletHUDRequest(
            id: Self.clipboardHUDID, duration: 12, accessibilityLabel: "Send the copied error to \(session.title)?",
            isExpanded: true, expandedContentHeight: 104
        ) {
            NoticeStrip(motion: .still, symbol: "doc.on.clipboard", label: "Error", tint: .red)
        } expanded: { [weak self] in
            NoticeCard(
                provider: session.providerID ?? "", symbol: "doc.on.clipboard", tint: AdaptiveColors.notchSurfacePrimaryText,
                title: "Send to \(session.title)?", status: "", meta: meta, detail: excerpt, style: .code,
                actions: [
                    NoticeAction(title: "Send", role: .accent) {
                        self?.send("I copied this error:\n\n```\n\(text.prefix(8_000))\n```", to: target)
                        self?.host?.hud.dismiss(id: Self.clipboardHUDID)
                    },
                    NoticeAction(title: "Not now", role: .quiet) { self?.host?.hud.dismiss(id: Self.clipboardHUDID) },
                ],
                onOpen: { self?.openSession(target) }
            )
        })
    }

    /// The session whose project the error names, busy ones first, else the
    /// session a reply would go to.
    private func clipboardTarget(for text: String) -> String? {
        let named = state.sessions.values
            .filter { $0.parentID == nil && !$0.directory.isEmpty && (text.contains($0.directory) || text.contains("/\($0.project)/")) }
            .max { lhs, rhs in
                let a = state.activity[lhs.id], b = state.activity[rhs.id]
                return (a?.isBusy == true ? 1 : 0, a?.finishedAt ?? .distantPast) < (b?.isBusy == true ? 1 : 0, b?.finishedAt ?? .distantPast)
            }
        return named?.id ?? replyTarget
    }

    // MARK: Starting sessions

    /// A new session in a project, by folder name or path, with its first message.
    func startSession(project: String, prompt: String) {
        let path = (project as NSString).expandingTildeInPath
        let known = state.sessions.values.first {
            path.hasPrefix("/") ? $0.directory == path : $0.project.caseInsensitiveCompare(project) == .orderedSame
        }
        let directory = known?.directory ?? (path.hasPrefix("/") ? path : nil)
        let serverID = known.flatMap { serverID(forSession: $0.id) }
            ?? (servers.contains { $0.isLocal } ? ChamberServer.localID : servers.first?.id)
        guard let directory, let serverID, let client = clients[serverID], !prompt.isEmpty else {
            host?.log.error("no project \"\(project)\" to start a session in")
            host?.feedback.play(.failure)
            return
        }
        Task {
            do {
                guard let session = try await client.createSession(directory: directory) else { throw OpenChamberError.invalidResponse }
                apply(.sessionsListed([session]), from: serverID)
                try await client.prompt(sessionID: session.id, text: prompt, queue: false, directory: directory)
                host?.feedback.play(.success)
            } catch {
                host?.log.error("starting a session failed: \(error.localizedDescription)")
                host?.feedback.play(.failure)
            }
        }
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
        updateStuck(now: now)
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
            let verb = Formatting.permissionVerb(permission.action)
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
                    hidesDetail: self?.presenting ?? false,
                    actions: [
                        NoticeAction(title: "Allow once", role: .accent) { self?.reply(to: permission, decision: "once") },
                        NoticeAction(title: "Let it run 15m", role: .quiet) { self?.letRun(permission) },
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
        guard outcome != .interrupted, let host, let session = state.sessions[id], session.parentID == nil else { return }
        let place = [session.project, serverLabel(forSession: id)].compactMap { $0 }
        let open: @MainActor () -> Void = { [weak self] in self?.openSession(id) }
        // Whether a card may show; what the turn changed is counted either way.
        let showsCard = !openChamberIsInFront
        let last = state.activity[id]?.lastText
        if awayWatcher?.awaySince != nil, recapsAway {
            noteWhileAway(id, title: session.title, failed: outcome == .failed, text: outcome == .failed ? error : last, directory: session.directory)
        }
        let replies = Array(quickReplies.prefix(3))

        if outcome == .failed {
            guard showsCard, showsFailureCards else { return }
            _ = host.hud.present(DropletHUDRequest(
                id: Self.failedHUDID, duration: 12, priority: .high,
                accessibilityLabel: "\(session.title) failed", isExpanded: true, expandedContentHeight: replies.isEmpty ? 72 : 108
            ) {
                NoticeStrip(motion: .failed, symbol: "exclamationmark.triangle.fill", label: "Failed", tint: .red)
            } expanded: { [weak self] in
                NoticeCard(
                    provider: session.providerID ?? "", symbol: "exclamationmark", tint: .red, title: session.title,
                    status: ["Failed", turn.map { "after \(Formatting.elapsed($0))" }].compactMap { $0 }.joined(separator: " "),
                    meta: place.joined(separator: " · "), detail: error ?? "The turn failed.", style: .code,
                    hidesDetail: self?.presenting ?? false,
                    actions: self?.replyActions(replies, to: id, closing: Self.failedHUDID) ?? [], onOpen: open
                )
            })
            return
        }

        let carded = showsCard && showsDoneCards
        let now = Date()
        if carded { recentTurnEnds = recentTurnEnds.filter { now.timeIntervalSince($0) < 5 } + [now] }
        let others = recentTurnEnds.count - 1
        let prompt = state.activity[id]?.promptID
        let client = serverID(forSession: id).flatMap { clients[$0] }
        Task { [weak self] in
            // What the turn changed rides on the card when the server says in time;
            // a slow answer does not hold the card back.
            var diff: TurnDiff?
            if let client, let prompt {
                diff = await Self.within(seconds: 1.5) { try? await client.turnDiff(sessionID: id, from: prompt, directory: session.directory) }
            }
            guard let self, let host = self.host else { return }
            if let diff, !diff.isEmpty {
                turnDiffs[id] = diff
                countToday { $0.lines.additions += diff.additions; $0.lines.deletions += diff.deletions; $0.lines.files += diff.files }
                if let index = awayLog.lastIndex(where: { $0.sessionID == id }) { awayLog[index].diff = diff }
            }
            guard carded else { return }
            let changed: TurnDiff? = diff?.isEmpty == false ? diff : nil
            let undoable = changed != nil && prompt != nil
            let height: CGFloat = (last == nil ? 36 : 72) + (replies.isEmpty ? 0 : 36)
            let status = ["Done", turn.map { "in \(Formatting.elapsed($0))" }].compactMap { $0 }.joined(separator: " ")
            let meta = ((others > 0 ? ["+\(others) more"] : []) + place).joined(separator: " · ")
            _ = host.hud.present(DropletHUDRequest(
                id: Self.doneHUDID, duration: replies.isEmpty ? 5 : 10,
                accessibilityLabel: "\(session.title) is done", isExpanded: true, expandedContentHeight: height
            ) {
                NoticeStrip(motion: .still, symbol: "checkmark.circle.fill", label: others > 0 ? "\(others + 1) done" : "Done", tint: .green)
            } expanded: { [weak self] in
                self?.doneCard(id, session: session, status: status, meta: meta, diff: changed, last: last,
                               replies: replies, undoable: undoable, open: open)
            })
        }
    }

    private func doneCard(
        _ id: String, session: SessionInfo, status: String, meta: String, diff: TurnDiff?, last: String?,
        replies: [String], undoable: Bool, open: @escaping @MainActor () -> Void
    ) -> NoticeCard {
        var undo: (@MainActor () -> Void)?
        if undoable { undo = { [weak self] in self?.undoTurn(id) } }
        return NoticeCard(
            provider: session.providerID ?? "", symbol: "checkmark", tint: .green, title: session.title,
            status: status, meta: meta, diff: diff, detail: last, style: .text, hidesDetail: presenting,
            actions: replyActions(replies, to: id, closing: Self.doneHUDID), onUndo: undo, onOpen: open
        )
    }

    /// The quick replies as a card's buttons, the first in accent.
    func replyActions(_ texts: [String], to id: String, closing hud: String) -> [NoticeAction] {
        texts.enumerated().map { index, text in
            NoticeAction(title: text, role: index == 0 ? .accent : .quiet) { [weak self] in
                self?.send(text, to: id)
                self?.host?.hud.dismiss(id: hud)
            }
        }
    }

    /// The work's answer, or nil when it takes longer than `seconds`.
    private nonisolated static func within<T: Sendable>(seconds: Double, _ work: @escaping @Sendable () async -> T?) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await work() }
            group.addTask { try? await Task.sleep(for: .seconds(seconds)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
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
                    actions: Self.answers(to: form,
                                          pick: { self?.answer(form, with: $0) },
                                          openChamber: { self?.openSession(form.sessionID) }),
                    onOpen: { self?.openSession(form.sessionID) }
                )
            })
        }
    }

    /// A one-pick form's options as buttons, up to three, the recommended one
    /// in accent; more options or an answer of one's own go to OpenChamber.
    static func answers(
        to form: PendingForm,
        pick: @escaping @MainActor (FormChoice.Option) -> Void,
        openChamber: @escaping @MainActor () -> Void
    ) -> [NoticeAction] {
        guard let choice = form.choice else { return [NoticeAction(title: "Answer in OpenChamber", role: .accent, run: openChamber)] }
        let shown = choice.options.prefix(3)
        var actions = shown.map { option in
            NoticeAction(title: option.label, role: option.recommended ? .accent : .quiet) { pick(option) }
        }
        if choice.custom || choice.options.count > shown.count {
            actions.append(NoticeAction(title: "Other…", role: .quiet, run: openChamber))
        }
        return actions
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

    /// The agent whose mascot the notch shows: the session that waits on you,
    /// else the one that has run longest.
    var leadProvider: String? {
        let id = state.permissions.first?.sessionID ?? state.forms.first?.sessionID ?? state.busySessionIDs.first
        return id.flatMap { state.sessions[$0]?.providerID }
    }

    /// The agent of the turn that ended last, which hops on the notch.
    var lastFinishedProvider: String? {
        state.activity.compactMap { id, activity in activity.finishedAt.map { (id, $0) } }
            .max { $0.1 < $1.1 }
            .flatMap { state.sessions[$0.0]?.providerID }
    }

    /// The session the microphone is listening for.
    var voiceSessionID: String? {
        if case let .listening(id, _) = voice { return id }
        return nil
    }

    /// A dot per running session for the notch's wing, `true` for one that
    /// waits on you. Nil for one session, which needs no dot, and past four,
    /// which the wing has no room for.
    var sessionDots: [Bool]? {
        let busy = state.busySessionIDs
        guard (2...4).contains(busy.count) else { return nil }
        let waiting = Set(state.permissions.map(\.sessionID) + state.forms.map(\.sessionID))
        return busy.map(waiting.contains)
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

// MARK: - Expanded surface

/// How Droppy finds the surfaces: it casts the droplet to this and asks for
/// the provider. The harness reads `ExpandedSurfaceProviding` directly, so
/// without this the shots show the surface and Droppy refuses to present it.
extension OpenchamberDroplet: ExpandedSurfaceHosting {
    public var expandedSurfaceProvider: (any ExpandedSurfaceProviding)? { self }
}

extension OpenchamberDroplet: ExpandedSurfaceProviding {
    public var expandedSurfaces: [ExpandedSurfaceDescriptor] {
        // Read, not pointed at: the shelf must not close while the pointer is elsewhere.
        [ExpandedSurfaceDescriptor(id: Self.focusSurfaceID, title: "OpenChamber session", systemImage: "cube", suppresses: [.shelfWidgets, .autoCollapse])]
    }

    public func makeExpandedSurfaceView(_ id: ExpandedSurfaceID, context: ExpandedSurfaceContext) -> AnyView {
        AnyView(SessionFocus(droplet: self))
    }

    public func expandedSurfaceSize(_ id: ExpandedSurfaceID, fitting proposal: ExpandedSurfaceSizeProposal) -> CGSize? {
        CGSize(width: min(560, proposal.maximumSize.width), height: min(260, proposal.maximumSize.height))
    }

    public func expandedSurfaceDidDismiss(_ id: ExpandedSurfaceID, presentation: ExpandedSurfacePresentation, reason: ExpandedSurfaceDismissalReason) {
        guard presentation.id == focusPresentation?.id else { return }
        focusPresentation = nil
        focusedSessionID = nil
    }
}

extension OpenchamberDroplet.StuckReason {
    /// What a row says: `Quiet for 6 min`, `pnpm test failed 4 times`.
    var sentence: String {
        switch self {
        case let .quiet(minutes): return "Quiet for \(minutes) min"
        case let .stalled(command, minutes): return "\(command) running for \(minutes) min"
        case let .looping(command, failures): return "\(command) failed \(failures) times"
        }
    }

    /// The same without the command, for presentation mode.
    var headline: String {
        switch self {
        case let .quiet(minutes): return "Quiet for \(minutes) min"
        case let .stalled(_, minutes): return "Running for \(minutes) min"
        case .looping: return "Going in circles"
        }
    }
}

// MARK: - Links

/// `droppy://droplet/openchamber/<action>?…`, for Raycast, Shortcuts, a
/// Stream Deck or a script. Every web page can open that scheme, so whatever
/// acts on a session needs `token=`, the secret in settings; opening and
/// showing a session need none.
extension OpenchamberDroplet: DropletURLHandling {
    public func handle(_ request: DropletURLRequest) {
        let action = request.path.lowercased()
        guard !LinkAction.needsToken(action) || request.query["token"] == linkToken else {
            host?.log.error("refused droppy://droplet/openchamber/\(action): the token is missing or wrong")
            host?.feedback.play(.failure)
            return
        }
        let named = request.query["session"].flatMap { state.sessions[$0] == nil ? nil : $0 }
        let text = request.query["text"].map { String($0.prefix(10_000)) }
        switch action {
        case "new":
            startSession(project: request.query["project"] ?? "", prompt: String((request.query["prompt"] ?? "").prefix(10_000)))
        case "reply":
            if let text, !text.isEmpty, let id = named ?? replyTarget { send(text, to: id) }
        case "approve":
            if let oldest = state.permissions.first { reply(to: oldest, decision: "once") }
        case "stop":
            if let id = named ?? state.permissions.first?.sessionID ?? state.busySessionIDs.first { interrupt(sessionID: id) }
        case "open":
            if let id = named ?? replyTarget { openSession(id) }
        case "focus":
            if let id = named ?? replyTarget { focus(id) }
        case "voice":
            toggleVoice()
        default:
            host?.log.info("no link action \"\(action)\"")
        }
    }
}

enum LinkAction {
    /// What a link may do without the token: look, never act.
    static func needsToken(_ action: String) -> Bool {
        !["open", "focus"].contains(action)
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
            SessionInfo(id: "s1", title: "Fix notification title cache", directory: "/Users/me/projects/openchamber", parentID: nil, providerID: "claude-code", modelID: "claude-opus-5-5[1m]", agent: "build", variant: "xhigh"),
            SessionInfo(id: "s2", title: "Design the droplet", directory: "/Users/me/projects/openchamber-droplet", parentID: nil, providerID: "anthropic"),
        ]))
        local.activity.apply(.executionStarted(sessionID: "s1", at: now.addingTimeInterval(-252)))
        for (index, (name, target, mark)) in [("read", "title-cache.js", true), ("grep", "notificationTitle", true), ("bash", "pnpm test", false),
                                               ("read", "session-runtime.js", true), ("bash", "pnpm test", true)].enumerated() {
            local.activity.apply(.toolStarted(sessionID: "s1", callID: "c\(index)", name: name))
            local.activity.apply(.toolCalled(sessionID: "s1", callID: "c\(index)", name: nil, target: target))
            local.activity.apply(.toolFinished(sessionID: "s1", callID: "c\(index)", succeeded: mark))
        }
        local.activity.apply(.toolStarted(sessionID: "s1", callID: "c9", name: "edit"))
        local.activity.apply(.toolCalled(sessionID: "s1", callID: "c9", name: nil, target: "session-runtime.js"))
        local.activity.apply(.textEnded(sessionID: "s1", text: "23/23 tests pass. Next: build, validate and the shots of the Sessions page."))
        local.activity.apply(.stepEnded(sessionID: "s1", contextTokens: 412_000))
        local.activity.apply(.branchChanged(directory: "/Users/me/projects/openchamber", branch: "fix/title-cache"))
        local.activity.apply(.executionStarted(sessionID: "s2", at: now.addingTimeInterval(-48)))
        local.activity.apply(.permissionAsked(PendingPermission(
            id: "p1", sessionID: "s2", action: "bash",
            resources: ["swift build -c release --product Openchamber"],
            directory: "/Users/me/projects/openchamber-droplet"
        )))
        local.usage = [
            ProviderQuota(id: "claude", provider: "claude", name: "Claude", plan: "Max (5x)", windows: [
                QuotaWindow(name: "5h", usedPercent: 3, windowSeconds: 18_000, resetAt: now.addingTimeInterval(15_660)),
                QuotaWindow(name: "7d", usedPercent: 41, windowSeconds: 604_800, resetAt: now.addingTimeInterval(518_400)),
                QuotaWindow(name: "7d", model: "Fable", usedPercent: 0, windowSeconds: 604_800, resetAt: now.addingTimeInterval(518_400)),
            ]),
            ProviderQuota(id: "opencode-go", provider: "opencode-go", name: "OpenCode Go", plan: nil, windows: [
                QuotaWindow(name: "monthly", usedPercent: 3, windowSeconds: 2_592_000, resetAt: now.addingTimeInterval(1_900_000)),
            ]),
            ProviderQuota(id: "github-copilot", provider: "github-copilot", name: "GitHub Copilot", plan: nil, windows: [
                QuotaWindow(name: "premium_interactions", usedPercent: nil, windowSeconds: nil, resetAt: nil, valueLabel: "Unlimited"),
            ]),
        ]
        local.models = ["claude-code/claude-opus-5-5[1m]": CatalogModel(name: "Opus 5.5", context: 1_000_000, output: 128_000)]

        var work = ServerState(connection: .live)
        work.activity.apply(.sessionsListed([SessionInfo(id: "w1", title: "API migration", directory: "/home/me/work/api", parentID: nil)]))
        work.activity.apply(.executionStarted(sessionID: "w1", at: now.addingTimeInterval(-610)))
        work.usage = [
            ProviderQuota(id: "codex", provider: "codex", name: "Codex", plan: "Pro", windows: [
                QuotaWindow(name: "5h", usedPercent: 0, windowSeconds: 18_000, resetAt: now.addingTimeInterval(9_600)),
            ]),
        ]
        serverStates = [mac.id: local, remote.id: work]
        turnDiffs = ["s1": TurnDiff(files: 3, additions: 42, deletions: 7)]
        today = TodayStats(day: TodayStats.key(for: now), turns: 7, seconds: 6_120, answered: 3, lines: TurnDiff(files: 9, additions: 318, deletions: 96))
        days = Dictionary(uniqueKeysWithValues: [2.4, 0.5, 0.1, 3.1, 2.2, 3.6, 1.7].enumerated().map { index, hours in
            let day = TodayStats.key(for: now.addingTimeInterval(Double(index - 6) * 86_400))
            return (day, TodayStats(day: day, seconds: hours * 3_600))
        })
        autoRuns["w1"] = AutoRun(sessionID: "w1", serverID: "remote", directory: "/home/me/work/api", until: now.addingTimeInterval(692), restore: "ask")
        focusedSessionID = "s1"
        publish(now: now)
    }
}

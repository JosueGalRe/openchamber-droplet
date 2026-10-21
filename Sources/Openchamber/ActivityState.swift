//
//  ActivityState.swift
//  Openchamber
//
//  Everything the droplet shows, as one value, and the pure function that
//  folds OpenChamber's events into it. No networking and no SwiftUI here, so
//  the tests can drive it with plain JSON.
//

import Foundation

/// A session as OpenCode lists it.
struct SessionInfo: Equatable, Sendable {
    let id: String
    var title: String
    var directory: String
    var parentID: String?
    /// The session's model, as OpenCode records it: `anthropic`, `openai`, `opencode`, …
    var providerID: String? = nil
    var modelID: String? = nil
    /// The agent profile the session runs as: `build`, `plan`, or one of your own.
    var agent: String? = nil

    /// The folder name, which is how OpenChamber's sidebar names a project.
    var project: String { (directory as NSString).lastPathComponent }
}

/// One tool call in the strip of recent calls a session row shows.
enum ToolMark: Equatable, Sendable {
    case running, succeeded, failed
}

struct ToolCall: Equatable, Sendable {
    let id: String
    var name: String
    /// What the call acts on: a file name, a command, a host.
    var target: String?
    var mark: ToolMark
}

struct Retry: Equatable, Sendable {
    var attempt: Int
    var scheduled: Date
    var at: Date
}

/// What one session is doing right now.
struct SessionActivity: Equatable, Sendable {
    var busySince: Date?
    var retry: Retry?
    /// Recent calls, oldest first, capped at ``ActivityState/recentCallLimit``.
    var calls: [ToolCall] = []
    var finishedAt: Date?
    var failedAt: Date?
    /// The assistant's latest finished block of text in this turn.
    var lastText: String?
    /// Tool calls in this turn, all of them; `calls` keeps only the last few.
    var steps = 0

    var isBusy: Bool { busySince != nil }
    /// The call the session is in, if it is in one.
    var currentCall: ToolCall? { calls.last(where: { $0.mark == .running }) ?? (isBusy ? calls.last : nil) }

    /// What the session is doing, in words, while it is busy.
    var narration: Narration? {
        if let running = calls.last(where: { $0.mark == .running }) { return Narration(call: running) }
        return isBusy ? .thinking : nil
    }
}

/// A tool call as a person would say it: "Editing Views.swift", "Running swift test".
struct Narration: Equatable, Sendable {
    let verb: String
    let object: String?

    static let thinking = Narration(verb: "Thinking…", object: nil)

    /// "Editing Views.swift", for a line with no room for weights.
    var sentence: String { [verb, object].compactMap { $0 }.joined(separator: " ") }

    init(verb: String, object: String?) {
        self.verb = verb
        self.object = object
    }

    init(call: ToolCall) {
        var name = call.name.lowercased()
        // `mcp__opencode__shell` is the `shell` tool of an MCP server.
        if name.hasPrefix("mcp__"), let last = name.components(separatedBy: "__").last, !last.isEmpty { name = last }
        switch name {
        case "read", "view", "cat": self.init(verb: "Reading", object: call.target)
        case "edit", "multiedit", "patch", "apply_patch", "str_replace": self.init(verb: "Editing", object: call.target)
        case "write", "create": self.init(verb: "Writing", object: call.target)
        case "bash", "shell", "exec", "run", "terminal": self.init(verb: "Running", object: call.target.flatMap(Self.command))
        case "grep", "glob", "search", "find", "codesearch": self.init(verb: "Searching", object: call.target)
        case "list", "ls": self.init(verb: "Listing", object: call.target)
        case "webfetch", "fetch": self.init(verb: "Fetching", object: call.target)
        case "websearch": self.init(verb: "Searching the web", object: nil)
        case "task", "subagent", "agent": self.init(verb: "Delegating", object: call.target)
        case "todowrite", "todoread", "todo", "plan": self.init(verb: "Planning", object: nil)
        default: self.init(verb: "Using", object: name)
        }
    }

    /// `swift test` out of `cd ~/x && swift test 2>&1 | tail`: the first part
    /// that is not setup, as its program and subcommand, without flags,
    /// redirections, pipes or heredocs.
    static func command(_ line: String) -> String? {
        let setup: Set = ["cd", "export", "source", ".", "set", "pushd", "env", "time", "sudo",
                          "for", "case", "select", "done", "fi", "esac", "true", "false", ":", "[", "[["]
        // `for i in …; do swift test; done`: the words that open a block are not the command.
        let keywords: Set = ["do", "then", "else", "elif", "if", "while", "until", "!", "{"]
        let parts = line
            .components(separatedBy: ";")
            .flatMap { $0.components(separatedBy: "&&") }
            .flatMap { $0.components(separatedBy: "||") }
        for part in parts {
            var words: [String] = []
            for token in part.split(separator: " ").map(String.init) {
                if words.isEmpty, token.contains("="), !token.hasPrefix("-") { continue } // FOO=bar cmd
                if words.isEmpty, keywords.contains(token) { continue }
                if token.hasPrefix("-") || token.contains(where: { "|<>&$(`\"'".contains($0) }) { break }
                words.append(words.isEmpty ? (token as NSString).lastPathComponent : token)
                if words.count == 2 { break }
            }
            guard let program = words.first, !setup.contains(program) else { continue }
            return words.joined(separator: " ")
        }
        return nil
    }
}

struct PendingPermission: Equatable, Identifiable, Sendable {
    let id: String
    let sessionID: String
    /// The tool asking, for example `bash` or `edit`.
    var action: String
    /// What it wants to act on, for example the command.
    var resources: [String]
    var directory: String?
}

struct PendingForm: Equatable, Identifiable, Sendable {
    let id: String
    let sessionID: String
    /// What it asks: the first question, not the form's header.
    var title: String
    var directory: String?
    /// Questions after the first, answered in the same form.
    var moreQuestions = 0
}

enum ExecutionOutcome: String, Equatable, Sendable {
    case succeeded, failed, interrupted
}

/// The facts the reducer understands, already lifted out of the wire format.
enum ActivityEvent: Equatable, Sendable {
    /// `/api/sessions/status`: replaces what is busy and what is pending.
    case seeded(busy: Set<String>, permissions: [PendingPermission], forms: [PendingForm], at: Date)
    case sessionsListed([SessionInfo])
    case executionStarted(sessionID: String, at: Date)
    /// `error` is OpenCode's, as `ProviderAuthError: token expired`, on a failure.
    case executionEnded(sessionID: String, outcome: ExecutionOutcome, at: Date, error: String? = nil)
    case retryScheduled(sessionID: String, attempt: Int, at: Date, scheduled: Date)
    case toolStarted(sessionID: String, callID: String, name: String)
    case toolCalled(sessionID: String, callID: String, name: String?, target: String?)
    case toolFinished(sessionID: String, callID: String, succeeded: Bool)
    case textEnded(sessionID: String, text: String)
    /// `session.created`, `session.renamed`, `session.agent.selected` and
    /// `session.model.selected`: whatever changed, nil for what did not.
    case sessionChanged(SessionChange)
    case permissionAsked(PendingPermission)
    case permissionSettled(sessionID: String, requestID: String)
    case formCreated(PendingForm)
    case formSettled(sessionID: String, formID: String)
    /// OpenChamber's own `openchamber:session-status`, the backstop for a
    /// session whose execution events were missed while disconnected.
    case statusChanged(sessionID: String, busy: Bool, at: Date)
    case sessionDeleted(String)
}

struct SessionChange: Equatable, Sendable {
    let sessionID: String
    var title: String?
    var directory: String?
    var parentID: String?
    var providerID: String?
    var modelID: String?
    var agent: String?
}

/// The one thing the notch says, derived from the whole state.
enum ActivityPhase: Equatable, Sendable {
    case idle
    case working(sessions: Int, since: Date)
    case retrying(attempt: Int, scheduled: Date, at: Date)
    case finishing(from: Date, until: Date)
    case waiting(count: Int)
    case failed(sessionID: String)
}

struct ActivityState: Equatable, Sendable {
    var sessions: [String: SessionInfo] = [:]
    var activity: [String: SessionActivity] = [:]
    /// Oldest first: "approve the oldest" acts on `permissions.first`.
    var permissions: [PendingPermission] = []
    var forms: [PendingForm] = []

    static let recentCallLimit = 12
    /// OpenChamber's own busy-to-idle cooldown (`SESSION_COOLDOWN_DURATION_MS`).
    static let finishingWindow: TimeInterval = 2
    /// How long a failure keeps the notch before it stands down on its own.
    static let failureTTL: TimeInterval = 10 * 60

    var pendingCount: Int { permissions.count + forms.count }

    /// Every server's state as one, for the notch. Each server keeps its own
    /// state so a seed from one never wipes another's pending requests.
    static func merged(_ states: [ActivityState]) -> ActivityState {
        var result = ActivityState()
        for state in states {
            result.sessions.merge(state.sessions) { current, _ in current }
            result.activity.merge(state.activity) { current, _ in current }
            result.permissions += state.permissions
            result.forms += state.forms
        }
        return result
    }

    /// Sessions that are busy now, longest-running first. Subagent sessions
    /// are left out once we know they are subagents: the parent already counts.
    var busySessionIDs: [String] {
        activity
            .filter { $0.value.isBusy && sessions[$0.key]?.parentID == nil }
            .sorted { ($0.value.busySince ?? .distantPast) < ($1.value.busySince ?? .distantPast) }
            .map(\.key)
    }

    /// Ids we have events for but no title yet.
    var unknownSessionIDs: Set<String> {
        let referenced = Set(activity.keys)
            .union(permissions.map(\.sessionID))
            .union(forms.map(\.sessionID))
        return referenced.subtracting(sessions.keys)
    }

    func phase(at now: Date) -> ActivityPhase {
        if pendingCount > 0 { return .waiting(count: pendingCount) }

        if let failed = activity
            .filter({ ($0.value.failedAt.map { now.timeIntervalSince($0) < Self.failureTTL }) ?? false })
            .max(by: { $0.value.failedAt! < $1.value.failedAt! }) {
            return .failed(sessionID: failed.key)
        }

        let busy = busySessionIDs
        if let retry = busy.compactMap({ activity[$0]?.retry }).first(where: { $0.at > now }) {
            return .retrying(attempt: retry.attempt, scheduled: retry.scheduled, at: retry.at)
        }
        if let first = busy.first, let since = activity[first]?.busySince {
            return .working(sessions: busy.count, since: since)
        }

        if let finished = activity.values.compactMap(\.finishedAt).max(),
           now.timeIntervalSince(finished) < Self.finishingWindow {
            return .finishing(from: finished, until: finished.addingTimeInterval(Self.finishingWindow))
        }
        return .idle
    }

    mutating func apply(_ event: ActivityEvent) {
        switch event {
        case let .seeded(busy, permissions, forms, at):
            for id in busy where activity[id]?.isBusy != true {
                activity[id, default: SessionActivity()].busySince = at
            }
            for (id, value) in activity where value.isBusy && !busy.contains(id) {
                activity[id]?.busySince = nil
                activity[id]?.retry = nil
            }
            self.permissions = permissions
            self.forms = forms

        case let .sessionsListed(list):
            for info in list { sessions[info.id] = info }

        case let .executionStarted(id, at):
            var session = activity[id, default: SessionActivity()]
            session.busySince = session.busySince ?? at
            session.retry = nil
            session.failedAt = nil
            session.finishedAt = nil
            // A new turn: last turn's words no longer describe what it is doing.
            session.lastText = nil
            session.steps = 0
            activity[id] = session

        case let .executionEnded(id, outcome, at, _):
            var session = activity[id, default: SessionActivity()]
            session.busySince = nil
            session.retry = nil
            for index in session.calls.indices where session.calls[index].mark == .running {
                session.calls[index].mark = outcome == .succeeded ? .succeeded : .failed
            }
            switch outcome {
            case .succeeded: session.finishedAt = at
            case .failed: session.failedAt = at
            case .interrupted: break
            }
            activity[id] = session

        case let .retryScheduled(id, attempt, at, scheduled):
            var session = activity[id, default: SessionActivity()]
            session.busySince = session.busySince ?? scheduled
            session.retry = Retry(attempt: attempt, scheduled: scheduled, at: at)
            activity[id] = session

        case let .toolStarted(id, callID, name):
            upsertCall(sessionID: id, callID: callID) { $0.name = name }

        case let .toolCalled(id, callID, name, target):
            upsertCall(sessionID: id, callID: callID) { call in
                if let name { call.name = name }
                if let target { call.target = target }
            }

        case let .toolFinished(id, callID, succeeded):
            guard let index = activity[id]?.calls.firstIndex(where: { $0.id == callID }) else { return }
            activity[id]?.calls[index].mark = succeeded ? .succeeded : .failed

        case let .sessionChanged(change):
            var info = sessions[change.sessionID]
                ?? SessionInfo(id: change.sessionID, title: "Untitled session", directory: change.directory ?? "", parentID: change.parentID)
            if let title = change.title, !title.isEmpty { info.title = title }
            if let directory = change.directory { info.directory = directory }
            if let parentID = change.parentID { info.parentID = parentID }
            if let providerID = change.providerID { info.providerID = providerID }
            if let modelID = change.modelID { info.modelID = modelID }
            if let agent = change.agent { info.agent = agent }
            // Only a session we know, or one being created, gets a record:
            // a rename of a session we never listed waits for the lookup.
            if sessions[change.sessionID] != nil || change.directory != nil { sessions[change.sessionID] = info }

        case let .textEnded(id, text):
            activity[id, default: SessionActivity()].lastText = text

        case let .permissionAsked(permission):
            guard !permissions.contains(where: { $0.id == permission.id }) else { return }
            permissions.append(permission)

        case let .permissionSettled(sessionID, requestID):
            permissions.removeAll { $0.id == requestID && $0.sessionID == sessionID }

        case let .formCreated(form):
            guard !forms.contains(where: { $0.id == form.id }) else { return }
            forms.append(form)

        case let .formSettled(sessionID, formID):
            forms.removeAll { $0.id == formID && $0.sessionID == sessionID }

        case let .statusChanged(id, busy, at):
            if busy {
                if activity[id]?.isBusy != true { activity[id, default: SessionActivity()].busySince = at }
            } else if activity[id]?.isBusy == true {
                activity[id]?.busySince = nil
                activity[id]?.retry = nil
            }

        case let .sessionDeleted(id):
            sessions[id] = nil
            activity[id] = nil
            permissions.removeAll { $0.sessionID == id }
            forms.removeAll { $0.sessionID == id }
        }
    }

    private mutating func upsertCall(sessionID: String, callID: String, _ update: (inout ToolCall) -> Void) {
        var session = activity[sessionID, default: SessionActivity()]
        if let index = session.calls.firstIndex(where: { $0.id == callID }) {
            update(&session.calls[index])
        } else {
            var call = ToolCall(id: callID, name: "tool", target: nil, mark: .running)
            update(&call)
            session.calls.append(call)
            session.steps += 1
            if session.calls.count > Self.recentCallLimit {
                session.calls.removeFirst(session.calls.count - Self.recentCallLimit)
            }
        }
        activity[sessionID] = session
    }
}

// MARK: - Wire format

/// Lifts OpenChamber's JSON into ``ActivityEvent``s. Anything it does not
/// recognise is dropped, so a newer OpenCode adding events costs nothing.
enum ActivityWire {
    /// One `payload` from a global WebSocket `event` frame.
    static func event(from payload: [String: Any], now: Date) -> ActivityEvent? {
        guard let type = payload["type"] as? String else { return nil }

        // OpenChamber's synthetic events carry `properties`, not `data`.
        if type == "openchamber:session-status" {
            guard let properties = payload["properties"] as? [String: Any],
                  let id = properties["sessionID"] as? String,
                  let status = properties["status"] as? String else { return nil }
            let at = date(fromMilliseconds: properties["timestamp"]) ?? now
            return .statusChanged(sessionID: id, busy: status == "busy" || status == "retry", at: at)
        }

        guard let data = payload["data"] as? [String: Any] else { return nil }
        let at = date(fromMilliseconds: payload["created"]) ?? now
        let directory = (payload["location"] as? [String: Any])?["directory"] as? String
        let sessionID = data["sessionID"] as? String

        switch type {
        case "session.execution.started":
            return sessionID.map { .executionStarted(sessionID: $0, at: at) }
        case "session.execution.succeeded":
            return sessionID.map { .executionEnded(sessionID: $0, outcome: .succeeded, at: at) }
        case "session.execution.failed":
            let error = data["error"] as? [String: Any]
            let text = [error?["type"] as? String, error?["message"] as? String]
                .compactMap { $0?.isEmpty == false ? $0 : nil }
                .joined(separator: ": ")
            return sessionID.map { .executionEnded(sessionID: $0, outcome: .failed, at: at, error: text.isEmpty ? nil : text) }
        case "session.execution.interrupted":
            // OpenCode shutting down is not the session's doing.
            guard data["reason"] as? String != "shutdown" else { return nil }
            return sessionID.map { .executionEnded(sessionID: $0, outcome: .interrupted, at: at) }
        case "session.retry.scheduled":
            guard let sessionID, let retryAt = date(fromMilliseconds: data["at"]) else { return nil }
            return .retryScheduled(sessionID: sessionID, attempt: data["attempt"] as? Int ?? 1, at: retryAt, scheduled: at)
        case "session.tool.input.started":
            guard let sessionID, let callID = data["id"] as? String, let name = data["name"] as? String else { return nil }
            return .toolStarted(sessionID: sessionID, callID: callID, name: name)
        case "session.tool.called":
            guard let sessionID, let callID = data["id"] as? String else { return nil }
            let input = data["input"] as? [String: Any] ?? [:]
            return .toolCalled(sessionID: sessionID, callID: callID, name: data["name"] as? String, target: target(of: input))
        case "session.created", "session.renamed", "session.agent.selected", "session.model.selected":
            guard let sessionID else { return nil }
            let model = data["model"] as? [String: Any]
            return .sessionChanged(SessionChange(
                sessionID: sessionID,
                title: data["title"] as? String,
                directory: type == "session.created" ? ((data["location"] as? [String: Any])?["directory"] as? String ?? directory) : nil,
                parentID: data["parentID"] as? String,
                providerID: model?["providerID"] as? String,
                modelID: model?["id"] as? String,
                agent: data["agent"] as? String
            ))
        case "session.text.ended":
            guard let sessionID, let text = (data["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return nil }
            return .textEnded(sessionID: sessionID, text: text)
        case "session.tool.success", "session.tool.failed":
            guard let sessionID, let callID = data["id"] as? String else { return nil }
            return .toolFinished(sessionID: sessionID, callID: callID, succeeded: type == "session.tool.success")
        case "permission.asked":
            return permission(from: data, directory: directory).map(ActivityEvent.permissionAsked)
        case "permission.replied":
            guard let sessionID, let requestID = data["requestID"] as? String ?? data["id"] as? String else { return nil }
            return .permissionSettled(sessionID: sessionID, requestID: requestID)
        case "form.created":
            return (data["form"] as? [String: Any]).flatMap { form(from: $0, directory: directory) }.map(ActivityEvent.formCreated)
        case "form.replied", "form.cancelled":
            guard let sessionID, let formID = data["id"] as? String ?? data["formID"] as? String else { return nil }
            return .formSettled(sessionID: sessionID, formID: formID)
        case "session.deleted":
            return sessionID.map(ActivityEvent.sessionDeleted)
        default:
            return nil
        }
    }

    /// `GET /api/sessions/status`.
    static func seed(from body: [String: Any], now: Date) -> ActivityEvent {
        let statuses = body["sessions"] as? [String: [String: Any]] ?? [:]
        let busy = Set(statuses.compactMap { id, value -> String? in
            let status = value["status"] as? String
            return status == "busy" || status == "retry" ? id : nil
        })
        var permissions: [PendingPermission] = []
        var forms: [PendingForm] = []
        for (_, entry) in body["pending"] as? [String: [String: Any]] ?? [:] {
            for item in entry["permissions"] as? [[String: Any]] ?? [] {
                if let permission = permission(from: item, directory: nil) { permissions.append(permission) }
            }
            for item in entry["forms"] as? [[String: Any]] ?? [] {
                if let form = form(from: item, directory: nil) { forms.append(form) }
            }
        }
        return .seeded(busy: busy, permissions: permissions, forms: forms, at: date(fromMilliseconds: body["serverTime"]) ?? now)
    }

    /// One session record from `GET /api/session` or `GET /api/session/:id`.
    static func session(from record: [String: Any]) -> SessionInfo? {
        guard let id = record["id"] as? String else { return nil }
        let directory = (record["location"] as? [String: Any])?["directory"] as? String
            ?? record["directory"] as? String
            ?? ""
        let title = (record["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled session"
        let model = record["model"] as? [String: Any]
        return SessionInfo(
            id: id,
            title: title,
            directory: directory,
            parentID: record["parentID"] as? String,
            providerID: model?["providerID"] as? String,
            modelID: model?["id"] as? String,
            agent: record["agent"] as? String
        )
    }

    static func permission(from data: [String: Any], directory: String?) -> PendingPermission? {
        guard let id = data["id"] as? String, let sessionID = data["sessionID"] as? String else { return nil }
        return PendingPermission(
            id: id,
            sessionID: sessionID,
            action: data["action"] as? String ?? "permission",
            resources: data["resources"] as? [String] ?? [],
            directory: directory
        )
    }

    static func form(from data: [String: Any], directory: String?) -> PendingForm? {
        guard let id = data["id"] as? String, let sessionID = data["sessionID"] as? String else { return nil }
        // A v2 form's title is a header such as "Questions"; the ask is its
        // first field's description, else that field's title, which is how
        // OpenChamber's own notifications read it.
        let fields = data["fields"] as? [[String: Any]] ?? []
        let ask = [fields.first?["description"], fields.first?["title"], data["title"]]
            .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        return PendingForm(id: id, sessionID: sessionID, title: ask ?? "A question", directory: directory,
                           moreQuestions: max(0, fields.count - 1))
    }

    /// The part of a tool's input worth a glance: a file name, a command, a host.
    static func target(of input: [String: Any]) -> String? {
        if let path = input["filePath"] as? String ?? input["path"] as? String {
            return (path as NSString).lastPathComponent
        }
        // A command's first line: a heredoc's body is not something to read in a notch.
        if let command = input["command"] as? String {
            return command.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? command
        }
        if let url = input["url"] as? String { return URL(string: url)?.host ?? url }
        if let pattern = input["pattern"] as? String ?? input["query"] as? String { return pattern }
        return input["description"] as? String
    }

    /// OpenCode stamps events in epoch milliseconds; seconds are accepted too
    /// so a unit change upstream shows up as a wrong time, not a 1970 one.
    static func date(fromMilliseconds value: Any?) -> Date? {
        let number: Double
        switch value {
        case let value as Double: number = value
        case let value as Int: number = Double(value)
        case let value as NSNumber: number = value.doubleValue
        case let value as String:
            if let parsed = ISO8601DateFormatter().date(from: value) { return parsed }
            guard let parsed = Double(value) else { return nil }
            number = parsed
        default: return nil
        }
        return Date(timeIntervalSince1970: number > 1e11 ? number / 1000 : number)
    }
}

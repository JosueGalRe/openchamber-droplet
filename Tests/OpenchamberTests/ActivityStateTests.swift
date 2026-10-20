import Foundation
import Testing
@testable import Openchamber

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private func ms(_ date: Date) -> Int { Int(date.timeIntervalSince1970 * 1000) }

/// Feeds wire payloads through the parser and the reducer, the way the droplet does.
private func state(after payloads: [[String: Any]]) -> ActivityState {
    var state = ActivityState()
    for payload in payloads {
        if let event = ActivityWire.event(from: payload, now: t0) { state.apply(event) }
    }
    return state
}

private func wire(_ type: String, at date: Date = t0, directory: String = "/Users/me/projects/app", _ data: [String: Any]) -> [String: Any] {
    ["type": type, "created": ms(date), "location": ["directory": directory], "data": data]
}

@Test func aTurnWorksThenFinishesThenStandsDown() {
    let state = state(after: [
        wire("session.execution.started", ["sessionID": "s1"]),
        wire("session.tool.input.started", ["sessionID": "s1", "id": "c1", "name": "edit"]),
        wire("session.tool.called", ["sessionID": "s1", "id": "c1", "input": ["filePath": "/repo/src/main.swift"]]),
    ])
    #expect(state.phase(at: t0.addingTimeInterval(5)) == .working(sessions: 1, since: t0))
    #expect(state.activity["s1"]?.currentCall == ToolCall(id: "c1", name: "edit", target: "main.swift", mark: .running))

    var done = state
    done.apply(ActivityWire.event(from: wire("session.tool.success", ["sessionID": "s1", "id": "c1"]), now: t0)!)
    let end = t0.addingTimeInterval(30)
    done.apply(ActivityWire.event(from: wire("session.execution.succeeded", at: end, ["sessionID": "s1"]), now: t0)!)

    #expect(done.activity["s1"]?.calls.map(\.mark) == [.succeeded])
    #expect(done.phase(at: end.addingTimeInterval(1)) == .finishing(from: end, until: end.addingTimeInterval(2)))
    #expect(done.phase(at: end.addingTimeInterval(3)) == .idle)
}

@Test func aPermissionWinsTheNotchUntilItIsAnswered() {
    var state = state(after: [
        wire("session.execution.started", ["sessionID": "s1"]),
        wire("permission.asked", ["id": "p1", "sessionID": "s1", "action": "bash", "resources": ["pnpm test"]]),
    ])
    #expect(state.phase(at: t0) == .waiting(count: 1))
    #expect(state.permissions.first == PendingPermission(id: "p1", sessionID: "s1", action: "bash", resources: ["pnpm test"], directory: "/Users/me/projects/app"))

    state.apply(ActivityWire.event(from: wire("permission.replied", ["sessionID": "s1", "requestID": "p1"]), now: t0)!)
    #expect(state.phase(at: t0) == .working(sessions: 1, since: t0))
}

@Test func aScheduledRetryCountsDownToItsTime() {
    let retryAt = t0.addingTimeInterval(14)
    let state = state(after: [
        wire("session.execution.started", ["sessionID": "s1"]),
        wire("session.retry.scheduled", ["sessionID": "s1", "attempt": 2, "at": ms(retryAt)]),
    ])
    #expect(state.phase(at: t0.addingTimeInterval(1)) == .retrying(attempt: 2, scheduled: t0, at: retryAt))
    // Once the time passes the session is simply working again.
    #expect(state.phase(at: retryAt.addingTimeInterval(1)) == .working(sessions: 1, since: t0))
}

@Test func aFailureHoldsUntilTheNextRunOrItsTimeout() {
    var state = state(after: [
        wire("session.execution.started", ["sessionID": "s1"]),
        wire("session.execution.failed", ["sessionID": "s1", "error": ["message": "boom"]]),
    ])
    #expect(state.phase(at: t0.addingTimeInterval(60)) == .failed(sessionID: "s1"))
    #expect(state.phase(at: t0.addingTimeInterval(ActivityState.failureTTL + 1)) == .idle)

    state.apply(.executionStarted(sessionID: "s1", at: t0.addingTimeInterval(90)))
    #expect(state.phase(at: t0.addingTimeInterval(91)) == .working(sessions: 1, since: t0.addingTimeInterval(90)))
}

@Test func shutdownInterruptionsAreNotTheSessionsDoing() {
    #expect(ActivityWire.event(from: wire("session.execution.interrupted", ["sessionID": "s1", "reason": "shutdown"]), now: t0) == nil)
}

@Test func subagentsDoNotCountOnceKnown() {
    var state = state(after: [
        wire("session.execution.started", ["sessionID": "parent"]),
        wire("session.execution.started", ["sessionID": "child"]),
    ])
    #expect(state.unknownSessionIDs == ["parent", "child"])
    state.apply(.sessionsListed([
        SessionInfo(id: "parent", title: "Fix cache", directory: "/r/app", parentID: nil),
        SessionInfo(id: "child", title: "explore", directory: "/r/app", parentID: "parent"),
    ]))
    #expect(state.busySessionIDs == ["parent"])
    #expect(state.unknownSessionIDs.isEmpty)
}

@Test func theSeedReplacesPendingAndClearsWhatStopped() {
    var state = state(after: [
        wire("session.execution.started", ["sessionID": "stale"]),
        wire("permission.asked", ["id": "old", "sessionID": "stale", "action": "edit", "resources": []]),
    ])
    let body: [String: Any] = [
        "sessions": ["s2": ["status": "busy", "lastUpdateAt": ms(t0)], "stale": ["status": "idle"]],
        "pending": ["s2": ["permissions": [["id": "p2", "sessionID": "s2", "action": "bash", "resources": ["ls"]]], "forms": [["id": "f1", "sessionID": "s2", "title": "Which branch?"]], "pages": []]],
        "serverTime": ms(t0),
    ]
    state.apply(ActivityWire.seed(from: body, now: t0))
    #expect(state.busySessionIDs == ["s2"])
    #expect(state.permissions.map(\.id) == ["p2"])
    #expect(state.forms.map(\.title) == ["Which branch?"])
}

@Test func openChambersStatusEventIsTheBackstop() {
    var state = ActivityState()
    let busy: [String: Any] = ["type": "openchamber:session-status", "properties": ["sessionID": "s1", "status": "busy", "timestamp": ms(t0)]]
    state.apply(ActivityWire.event(from: busy, now: t0)!)
    #expect(state.busySessionIDs == ["s1"])
    let idle: [String: Any] = ["type": "openchamber:session-status", "properties": ["sessionID": "s1", "status": "idle"]]
    state.apply(ActivityWire.event(from: idle, now: t0)!)
    #expect(state.busySessionIDs.isEmpty)
}

@Test func sessionRecordsReadTheV2Location() {
    let info = ActivityWire.session(from: ["id": "s1", "title": "Fix cache", "location": ["directory": "/Users/me/projects/openchamber"], "parentID": "p"])
    #expect(info == SessionInfo(id: "s1", title: "Fix cache", directory: "/Users/me/projects/openchamber", parentID: "p"))
    #expect(info?.project == "openchamber")
}

@Test func timestampsAcceptMillisecondsAndSeconds() {
    #expect(ActivityWire.date(fromMilliseconds: 1_800_000_000_000) == t0)
    #expect(ActivityWire.date(fromMilliseconds: 1_800_000_000) == t0)
}

@Test func theAssistantsLastWordsLastUntilTheNextTurn() {
    var state = state(after: [
        wire("session.execution.started", ["sessionID": "s1"]),
        wire("session.text.ended", ["sessionID": "s1", "assistantMessageID": "m1", "ordinal": 0, "text": "  Looking at the reducer.\n"]),
        wire("session.text.ended", ["sessionID": "s1", "assistantMessageID": "m1", "ordinal": 1, "text": "   "]),
    ])
    #expect(state.activity["s1"]?.lastText == "Looking at the reducer.")

    state.apply(.executionStarted(sessionID: "s1", at: t0.addingTimeInterval(60)))
    #expect(state.activity["s1"]?.lastText == nil)
}

@Test func aCommandShowsItsFirstLineOnly() {
    #expect(ActivityWire.target(of: ["command": "python3 - file.swift <<'EOF'\nprint(1)\nEOF"]) == "python3 - file.swift <<'EOF'")
}

@Test func sessionRecordsCarryTheirModel() {
    let info = ActivityWire.session(from: ["id": "s1", "title": "T", "location": ["directory": "/r/app"], "model": ["id": "claude-opus-5-5", "providerID": "anthropic"]])
    #expect(info?.providerID == "anthropic")
    #expect(info?.modelID == "claude-opus-5-5")
}

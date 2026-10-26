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
    #expect(state.activity["s1"]?.currentCall == ToolCall(id: "c1", name: "edit", target: "main.swift", mark: .running, detail: "/repo/src/main.swift"))

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

@Test func commandsReadAsTheirProgramAndSubcommand() {
    #expect(Narration.command("cd ~/x && export PATH=a:$PATH; droppykit build 2>&1 | grep -E 'x'") == "droppykit build")
    #expect(Narration.command("python3 -I - <<'EOF'") == "python3")
    #expect(Narration.command("FOO=1 /usr/bin/swift test --filter liveRelay") == "swift test")
    #expect(Narration.command("cd ~/projects") == nil)
}

@Test func toolCallsAreNarratedAndCountedPerTurn() {
    var state = state(after: [
        wire("session.execution.started", ["sessionID": "s1"]),
        wire("session.tool.input.started", ["sessionID": "s1", "id": "c1", "name": "read"]),
        wire("session.tool.called", ["sessionID": "s1", "id": "c1", "input": ["filePath": "/r/Views.swift"]]),
        wire("session.tool.success", ["sessionID": "s1", "id": "c1"]),
        wire("session.tool.input.started", ["sessionID": "s1", "id": "c2", "name": "mcp__opencode__shell"]),
        wire("session.tool.called", ["sessionID": "s1", "id": "c2", "input": ["command": "cd ~/x && swift test 2>&1 | tail"]]),
    ])
    #expect(state.activity["s1"]?.narration == Narration(verb: "Running", object: "swift test"))
    #expect(state.activity["s1"]?.steps == 2)

    state.apply(ActivityWire.event(from: wire("session.tool.success", ["sessionID": "s1", "id": "c2"]), now: t0)!)
    #expect(state.activity["s1"]?.narration == .thinking)
    #expect(Narration(call: ToolCall(id: "x", name: "edit", target: "Views.swift", mark: .running)) == Narration(verb: "Editing", object: "Views.swift"))

    state.apply(.executionStarted(sessionID: "s1", at: t0.addingTimeInterval(60)))
    #expect(state.activity["s1"]?.steps == 0)
}

@Test func renamesAndModelOrAgentSwitchesReachTheSession() {
    var state = state(after: [
        wire("session.created", ["sessionID": "s1", "title": "", "location": ["directory": "/r/app"], "agent": "build",
                                 "model": ["id": "claude-sonnet-4.5", "providerID": "kiro"]]),
        wire("session.renamed", ["sessionID": "s1", "title": "Fix the relay"]),
        wire("session.agent.selected", ["sessionID": "s1", "agent": "plan"]),
        wire("session.model.selected", ["sessionID": "s1", "model": ["id": "gpt-5.5", "providerID": "openai"]]),
    ])
    #expect(state.sessions["s1"] == SessionInfo(id: "s1", title: "Fix the relay", directory: "/r/app", parentID: nil,
                                               providerID: "openai", modelID: "gpt-5.5", agent: "plan"))

    // A rename for a session never listed waits for its lookup instead of inventing a record.
    state.apply(ActivityWire.event(from: wire("session.renamed", ["sessionID": "ghost", "title": "?"]), now: t0)!)
    #expect(state.sessions["ghost"] == nil)
}

@Test func theRunnerNamesModelProfileAndServer() {
    let session = SessionInfo(id: "s1", title: "T", directory: "/r", parentID: nil, providerID: "kiro", modelID: "kiro/claude-sonnet-4.5", agent: "build")
    #expect(Formatting.runner(of: session, server: "devbox") == "claude-sonnet-4.5 · Build · devbox")
    #expect(Formatting.runner(of: session, model: "Sonnet 4.5", server: "devbox") == "Sonnet 4.5 · Build · devbox")
    var reasoning = session
    reasoning.variant = "xhigh"
    #expect(Formatting.runner(of: reasoning, model: "Sonnet 4.5", server: nil) == "Sonnet 4.5 xhigh · Build")
    reasoning.variant = "default"
    #expect(Formatting.runner(of: reasoning, model: "Sonnet 4.5", server: nil) == "Sonnet 4.5 · Build")
    #expect(Formatting.runner(of: SessionInfo(id: "s2", title: "T", directory: "/r", parentID: nil, providerID: "claude-code"), server: nil) == "Claude")
}

@Test func aTurnStreamsItsWordsAndCarriesItsContextAndPrompt() {
    var state = state(after: [
        wire("session.inbox.delivered", ["sessionID": "s1", "inboxID": "msg_prompt"]),
        wire("session.execution.started", ["sessionID": "s1"]),
        wire("session.text.started", ["sessionID": "s1", "assistantMessageID": "msg_a", "ordinal": 0]),
        wire("session.text.delta", ["sessionID": "s1", "assistantMessageID": "msg_a", "ordinal": 0, "delta": "The tests "]),
        wire("session.text.delta", ["sessionID": "s1", "assistantMessageID": "msg_a", "ordinal": 0, "delta": "failed"]),
        wire("session.step.ended", ["sessionID": "s1", "tokens": ["input": 1_000, "output": 200, "reasoning": 0, "cache": ["read": 40_000, "write": 800]]]),
    ])
    #expect(state.activity["s1"]?.liveText == "The tests failed")
    #expect(state.activity["s1"]?.narration == .writing)
    #expect(state.activity["s1"]?.contextTokens == 42_000)
    #expect(state.activity["s1"]?.promptID == "msg_prompt")

    state.apply(ActivityWire.event(from: wire("session.text.ended", ["sessionID": "s1", "text": "The tests failed."]), now: t0)!)
    #expect(state.activity["s1"]?.liveText == nil)
    #expect(state.activity["s1"]?.lastText == "The tests failed.")
    #expect(state.activity["s1"]?.narration == .thinking)

    // The server's own total wins over the parts, which add up every round trip.
    #expect(ActivityWire.contextTokens(of: ["total": 9_000, "input": 1, "cache": ["read": 99_999]]) == 9_000)

    state.apply(ActivityWire.event(from: wire("session.compaction.started", ["sessionID": "s1", "reason": "auto", "recent": ""]), now: t0)!)
    #expect(state.activity["s1"]?.narration == .compacting)
    state.apply(ActivityWire.event(from: wire("session.compaction.ended", ["sessionID": "s1", "reason": "auto", "recent": "", "text": "…"]), now: t0)!)
    #expect(state.activity["s1"]?.narration == .thinking)
    #expect(state.activity["s1"]?.contextTokens == nil)
}

@Test func aBranchUpdateLandsOnItsProject() {
    let state = state(after: [wire("vcs.branch.updated", directory: "/r/app", ["branch": "fix/utc"])])
    #expect(state.branches["/r/app"] == "fix/utc")
}

@Test func aOnePickFormBecomesButtonsWithTheRecommendedFirst() {
    let form = ActivityWire.form(from: [
        "id": "f1", "sessionID": "s1", "title": "Questions",
        "fields": [["key": "tz", "type": "string", "title": "Which timezone?", "custom": true, "options": [
            ["value": "local", "label": "The user's timezone"],
            ["value": "utc", "label": "UTC everywhere (Recommended)"],
        ]]],
    ], directory: nil)
    #expect(form?.choice == FormChoice(key: "tz", options: [
        .init(value: "utc", label: "UTC everywhere", recommended: true),
        .init(value: "local", label: "The user's timezone", recommended: false),
    ], custom: true))

    // Two fields, or a field without options, are answered in OpenChamber.
    let two = ActivityWire.form(from: ["id": "f2", "sessionID": "s1", "fields": [
        ["key": "a", "type": "string", "options": [["value": "x", "label": "X"]]],
        ["key": "b", "type": "boolean"],
    ]], directory: nil)
    #expect(two?.choice == nil)
    #expect(ActivityWire.form(from: ["id": "f3", "sessionID": "s1", "fields": [["key": "a", "type": "string"]]], directory: nil)?.choice == nil)
}

@Test func theSameCallFailingThreeTimesIsALoop() {
    var activity = SessionActivity()
    let runs: [(String, ToolMark)] = [("pnpm test", .failed), ("a.ts", .succeeded), ("pnpm test", .failed), ("pnpm test", .failed)]
    activity.calls = runs.enumerated().map { index, run in
        ToolCall(id: "c\(index)", name: run.0 == "a.ts" ? "edit" : "bash", target: run.0, mark: run.1)
    }
    #expect(activity.repeatedFailure?.failures == 3)
    #expect(activity.repeatedFailure?.call.object == "pnpm test")

    // Passing on its latest try ends the loop.
    activity.calls.append(ToolCall(id: "c9", name: "bash", target: "pnpm test", mark: .succeeded))
    #expect(activity.repeatedFailure == nil)
}

@Test func aTurnKnowsWhatItWasAskedAndWhatItIsThinking() {
    var state = state(after: [
        // Queued while the last turn ran: its words come with the queueing, its id with the delivery.
        wire("session.inbox.enqueued", ["sessionID": "s1", "inboxID": "msg_q", "item": ["type": "user", "payload": ["text": "Fix the cache"], "delivery": "queue"]]),
        wire("session.inbox.enqueued", ["sessionID": "s1", "inboxID": "msg_c", "item": ["type": "compaction", "payload": [:]]]),
        wire("session.inbox.delivered", ["sessionID": "s1", "inboxID": "msg_q"]),
        wire("session.execution.started", ["sessionID": "s1"]),
        wire("session.reasoning.started", ["sessionID": "s1", "assistantMessageID": "msg_a", "ordinal": 0]),
        wire("session.reasoning.delta", ["sessionID": "s1", "assistantMessageID": "msg_a", "ordinal": 0, "delta": "The key is "]),
        wire("session.reasoning.delta", ["sessionID": "s1", "assistantMessageID": "msg_a", "ordinal": 0, "delta": "the title"]),
    ])
    #expect(state.activity["s1"]?.promptID == "msg_q")
    #expect(state.activity["s1"]?.prompt == "Fix the cache")
    #expect(state.activity["s1"]?.queuedPrompts.isEmpty == true)
    #expect(state.activity["s1"]?.reasoning == "The key is the title")

    // The ended thought is the whole of it; a call starting puts it away, and
    // a late delta does not bring it back.
    state.apply(ActivityWire.event(from: wire("session.reasoning.ended", ["sessionID": "s1", "assistantMessageID": "msg_a", "ordinal": 0, "text": "The key is the title.\n"]), now: t0)!)
    #expect(state.activity["s1"]?.reasoning == "The key is the title.")
    state.apply(.toolStarted(sessionID: "s1", callID: "c1", name: "read"))
    state.apply(.reasoningStreamed(sessionID: "s1", delta: "late"))
    #expect(state.activity["s1"]?.reasoning == nil)

    // A prompt looked up later brings its words along.
    state.apply(.promptDelivered(sessionID: "s1", messageID: "msg_n", text: "Now the tests"))
    #expect(state.activity["s1"]?.prompt == "Now the tests")
    // One delivered without being heard queued has no words to show.
    state.apply(.promptDelivered(sessionID: "s1", messageID: "msg_x"))
    #expect(state.activity["s1"]?.prompt == nil)
}

@Test func tokenCountsReadAtAGlance() {
    #expect(Formatting.tokens(870) == "870")
    #expect(Formatting.tokens(412_000) == "412k")
    #expect(Formatting.tokens(999_600) == "1M")
    #expect(Formatting.tokens(1_048_576) == "1M")
    #expect(Formatting.tokens(1_500_000) == "1.5M")
}

@Test func anyOtherEventAboutASessionCountsAsHearingFromIt() {
    let event = ActivityWire.event(from: wire("session.tool.input.delta", ["sessionID": "s1", "delta": "{"]), now: t0)
    #expect(event == .heard(sessionID: "s1"))
    #expect(event?.sessionID == "s1")
    // Without a session there is nothing to hear from.
    #expect(ActivityWire.event(from: wire("vcs.status.changed", [:]), now: t0) == nil)
}

@Test func aHeadlineIsTheFirstSentenceWithoutMarkdown() {
    #expect(Formatting.headline(from: "Switched `formatDate` to UTC. Then added a test.") == "switched formatDate to UTC")
    #expect(Formatting.headline(from: "UTC everywhere now\nmore below") == "UTC everywhere now")
    #expect(Formatting.headline(from: "   ") == nil)
    #expect(Formatting.headline(from: String(repeating: "word ", count: 30), limit: 20)?.count == 20)
    #expect(Formatting.list(["a", "b", "c"]) == "a, b and c")
    #expect(Formatting.list(["a"]) == "a")
}

@Test func finishedCallsReadInThePastTense() {
    #expect(Narration(call: ToolCall(id: "c", name: "bash", target: "pnpm test", mark: .succeeded)).pastVerb == "Ran")
    #expect(Narration(call: ToolCall(id: "c", name: "edit", target: "a.swift", mark: .failed)).pastVerb == "Edited")
}

@Test func theNewestWordsOfALongMessageShow() {
    let text = String(repeating: "word ", count: 60) + "end"
    let tail = Formatting.tail(text, limit: 20)
    #expect(tail.hasPrefix("…"))
    #expect(tail.hasSuffix("end"))
    #expect(tail.count <= 21)
    #expect(Formatting.tail("short") == "short")
    #expect(Formatting.duration(6_120) == "1h 42m")
    #expect(Formatting.duration(2_520) == "42m")
}

@Test func lastWordsDrawTheirMarkdownAndFollowNoLink() {
    let text = Formatting.inlineMarkdown("`formatDate` in **src/format.ts**, see [the PR](https://example.com/1)")
    #expect(String(text.characters) == "formatDate in src/format.ts, see the PR")
    #expect(text.runs.allSatisfy { $0.link == nil })
    #expect(text.runs.contains { $0.inlinePresentationIntent == .code })
}

@Test func permissionsReadAsVerbs() {
    #expect(Formatting.permissionVerb("bash") == "run")
    #expect(Formatting.permissionVerb("edit") == "edit")
    #expect(Formatting.permissionVerb("external_directory") == "external directory")
}

@Test func shellBlocksReadAsTheCommandInside() {
    #expect(Narration.command("for i in 1 2 3; do swift test; done") == "swift test")
    #expect(Narration.command("if [ -f x ]; then make build; fi") == "make build")
    #expect(Narration.command("while true; do sleep 5; done") == "sleep 5")
    // A loop over lines, and a message before the work: the work.
    #expect(Narration.command("for f in a b; do\n  printf \"%s\" \"$f\"\ndone\ngit diff --stat | tail -1") == "git diff")
    #expect(Narration.command("echo \"Probando\" && git log --oneline -5") == "git log")
}

@Test func theHoverCardGetsTheCallInFull() {
    let state = state(after: [
        wire("session.tool.called", ["sessionID": "s1", "id": "c1", "name": "bash", "input": ["command": "for f in a b; do\n  swift test\ndone\n"]]),
        wire("session.tool.called", ["sessionID": "s1", "id": "c2", "name": "edit", "input": ["filePath": "/r/app/Sources/App/Views.swift"]]),
    ])
    let calls = state.activity["s1"]?.calls ?? []
    #expect(calls.first?.target == "for f in a b; do")
    #expect(calls.first?.detail == "for f in a b; do\n  swift test\ndone")
    #expect(calls.first.map(Narration.init(call:))?.object == "swift test")
    #expect(calls.last?.target == "Views.swift")
    #expect(Formatting.shortPath(calls.last?.detail ?? "", in: "/r/app") == "Sources/App/Views.swift")
    #expect(Formatting.shortPath("/elsewhere/x.swift", in: "/r/app") == "/elsewhere/x.swift")
}

@Test func aFailedTurnCarriesOpenCodesError() {
    let failed = ActivityWire.event(from: wire("session.execution.failed", ["sessionID": "s1", "error": ["type": "ProviderAuthError", "message": "token expired"]]), now: t0)
    #expect(failed == .executionEnded(sessionID: "s1", outcome: .failed, at: t0, error: "ProviderAuthError: token expired"))
    let bare = ActivityWire.event(from: wire("session.execution.failed", ["sessionID": "s1"]), now: t0)
    #expect(bare == .executionEnded(sessionID: "s1", outcome: .failed, at: t0, error: nil))
}

@Test func aFormReadsAsItsFirstQuestionNotItsHeader() {
    let event = ActivityWire.event(from: wire("form.created", ["form": [
        "id": "f1", "sessionID": "s1", "title": "Questions",
        "fields": [["key": "a", "title": "Prueba", "description": "¿Se vio la tarjeta?"], ["key": "b", "title": "¿Y la otra?"]],
    ]]), now: t0)
    guard case let .formCreated(form) = event else { Issue.record("no form: \(String(describing: event))"); return }
    #expect(form.title == "¿Se vio la tarjeta?")
    #expect(form.moreQuestions == 1)

    let bare = ActivityWire.event(from: wire("form.created", ["form": ["id": "f2", "sessionID": "s1", "title": "Pick one", "fields": [["key": "a"]]]]), now: t0)
    guard case let .formCreated(header) = bare else { Issue.record("no form"); return }
    #expect(header.title == "Pick one")
}

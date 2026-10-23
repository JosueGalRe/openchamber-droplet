import Foundation
import Testing
@testable import Openchamber

@Test func desktopSettingsYieldTheLocalServerAndDirectHostsOnly() throws {
    let settings: [String: Any] = [
        "desktopUiPassword": "not-for-the-droplet",
        "desktopLocalPort": 4097,
        "desktopLocalClientToken": "oc_client_local",
        "desktopHosts": [
            ["id": "h1", "label": "devbox", "url": "http://192.168.1.30:4097/", "apiUrl": "http://10.0.0.5:4097/",
             "clientToken": "oc_client_remote", "requestHeaders": ["CF-Access-Client-Id": "abc"], "relay": relay],
            ["id": "h2", "label": "Relay only", "url": "relay://server", "clientToken": "oc_client_relay", "relay": relay],
            ["id": "h3", "label": "No token", "url": "http://10.0.0.9:4097/"],
            ["id": "h4", "label": "Unknown relay", "url": "relay://other", "clientToken": "oc_client_other"],
        ],
    ]
    let servers = DesktopServers.parse(try JSONSerialization.data(withJSONObject: settings))

    #expect(servers.map(\.id) == [ChamberServer.localID, "h1", "h2"])
    #expect(servers[0].directURLs.map(\.absoluteString) == ["http://127.0.0.1:4097"])
    #expect(servers[0].token == "oc_client_local")
    // Desktop talks to a host's API at `apiUrl` first, then its UI address.
    #expect(servers[1].directURLs.map(\.absoluteString) == ["http://10.0.0.5:4097/", "http://192.168.1.30:4097/"])
    #expect(servers[1].headers == ["CF-Access-Client-Id": "abc"])
    #expect(servers[1].relay?.serverID == "server-id")
    #expect(servers[1].relay?.hostKeyX.count == 32)
    #expect(servers[2].directURLs.isEmpty)
    #expect(servers[2].relay != nil)
}

private var relay: [String: Any] { [
    "relayUrl": "wss://relay.openchamber.dev/ws",
    "serverId": "server-id",
    "hostEncPubJwk": ["kty": "EC", "crv": "P-256", "x": "05NPClQHxhhgK1OW8-nGzH7aAZwKDj67qfiHfpaDKj0", "y": "AMSZL2D9Zl81UQoLaPK4qhWQZ6iXexoerTcdnZdOlXc"],
] }

@Test func unreadableSettingsMeanNoServers() {
    #expect(DesktopServers.parse(Data("not json".utf8)).isEmpty)
    #expect(DesktopServers.load(from: URL(fileURLWithPath: "/nonexistent/settings.json")).isEmpty)
}

@Test func mergingServersKeepsEachOnesPendingRequests() {
    var mac = ActivityState()
    mac.apply(.permissionAsked(PendingPermission(id: "p1", sessionID: "s1", action: "bash", resources: [], directory: nil)))
    var work = ActivityState()
    work.apply(.permissionAsked(PendingPermission(id: "p2", sessionID: "w1", action: "edit", resources: [], directory: nil)))
    // A seed from the work server must not touch the Mac's request.
    work.apply(.seeded(busy: [], permissions: [], forms: [], at: Date()))

    #expect(ActivityState.merged([mac, work]).permissions.map(\.id) == ["p1"])
}

@Test func eventFramesKeepTheCursorEvenWhenTheEventIsIgnored() {
    guard case let .event(event, eventID) = OpenChamberClient.frame(from: #"{"type":"event","eventId":"42","payload":{"type":"session.text.delta","data":{"sessionID":"s1"}}}"#) else {
        Issue.record("expected an event frame")
        return
    }
    #expect(event == nil)
    #expect(eventID == "42")

    guard case let .event(started, _) = OpenChamberClient.frame(from: #"{"type":"event","payload":{"type":"session.execution.started","created":1800000000000,"data":{"sessionID":"s1"}}}"#) else {
        Issue.record("expected an event frame")
        return
    }
    #expect(started == .executionStarted(sessionID: "s1", at: Date(timeIntervalSince1970: 1_800_000_000)))
}

@Test func aReadyFrameSaysWhetherTheReplayWasLost() {
    guard case let .ready(reset) = OpenChamberClient.frame(from: #"{"type":"ready","scope":"global","replayReset":true}"#) else {
        Issue.record("expected a ready frame")
        return
    }
    #expect(reset)
}

@Test func claudeUsageKeepsItsPerModelWindowsAndReadsLikeAgents() throws {
    let body: [String: Any] = [
        "ok": true, "providerName": "Claude", "planLabel": "Max (5x)",
        "usage": [
            "windows": [
                "7d": ["usedPercent": 7, "windowSeconds": 604_800, "resetAt": 1_800_500_000_000],
                "5h": ["usedPercent": 3, "windowSeconds": 18_000, "resetAt": 1_800_015_660_000],
            ],
            "models": ["Fable": ["windows": ["7d": ["usedPercent": 0, "windowSeconds": 604_800]]]],
        ],
    ]
    let quota = try #require(OpenChamberClient.quota(from: body, providerID: "claude"))

    #expect(quota.windows.map(\.id) == [".5h", ".7d", "Fable.7d"])
    #expect(quota.windows.map { Formatting.windowLabel($0, in: quota) } == ["5-hour limit", "Weekly · all models", "Weekly · Fable"])
    #expect(quota.percentLeft == 93)
    #expect(OpenChamberClient.quota(from: ["ok": false], providerID: "claude") == nil)
}

@Test func catalogModelsAreKeyedTheWayASessionRecordsItsModel() {
    let body: [String: Any] = ["location": [:], "data": [
        ["providerID": "claude-code", "id": "claude-opus-5-5[1m]", "modelID": "claude-opus-5-5[1m]", "name": "Opus 5.5",
         "limit": ["context": 1_000_000, "output": 128_000]],
        ["providerID": "openai", "id": "gpt-6-luna-fast", "modelID": "gpt-6-luna", "name": "GPT-6 Luna Fast"],
        ["providerID": "openai", "id": "unnamed", "name": ""],
    ]]
    #expect(OpenChamberClient.models(from: body) == [
        "claude-code/claude-opus-5-5[1m]": CatalogModel(name: "Opus 5.5", context: 1_000_000, output: 128_000),
        "openai/gpt-6-luna-fast": CatalogModel(name: "GPT-6 Luna Fast"),
    ])
    #expect(OpenChamberClient.models(from: nil).isEmpty)
}

@Test func contextFillsAgainstTheWindowLessTheOutputItKeeps() {
    let opus = CatalogModel(name: "Opus 5.5", context: 1_000_000, output: 128_000)
    // Output room is capped at 32k, as in OpenChamber.
    #expect(opus.contextShare(of: 484_000) == 0.5)
    #expect(opus.contextShare(of: 2_000_000) == 1)
    #expect(CatalogModel(name: "Small", context: 100_000).contextShare(of: 34_000) == 0.5)
    #expect(CatalogModel(name: "Unknown").contextShare(of: 10) == nil)
}

@Test func aTurnsDiffSumsItsFiles() {
    let diff = TurnDiff(files: [
        ["file": "a.swift", "additions": 40, "deletions": 2, "status": "modified"],
        ["file": "b.swift", "additions": 2, "deletions": 5, "status": "added"],
    ])
    #expect(diff == TurnDiff(files: 2, additions: 42, deletions: 7, names: ["a.swift", "b.swift"]))
    #expect(TurnDiff(files: []).isEmpty)
}

@Test func copiedErrorsAreTheOnesWithAStackOrADiagnostic() {
    #expect(ErrorText.looksLikeError("TypeError: Cannot read properties of undefined (reading 'id')\n    at serializeUser (src/users/serialize.ts:42:18)"))
    #expect(ErrorText.looksLikeError("Traceback (most recent call last):\n  File \"app.py\", line 3, in <module>\n    main()"))
    #expect(ErrorText.looksLikeError("Sources/App/Views.swift:12:5: error: cannot find 'foo' in scope"))
    #expect(ErrorText.looksLikeError("error[E0308]: mismatched types\n --> src/main.rs:4:18"))
    #expect(ErrorText.looksLikeError("src/a.ts(3,1): error TS2304: Cannot find name 'x'."))
    // Prose that mentions an error, a URL, a short word: none of them.
    #expect(!ErrorText.looksLikeError("I think there was an error: the build took long"))
    #expect(!ErrorText.looksLikeError("https://example.com/errors/42"))
    #expect(!ErrorText.looksLikeError("Error"))
}

@Test func linksActOnlyWithTheToken() {
    #expect(LinkAction.needsToken("new"))
    #expect(LinkAction.needsToken("approve"))
    #expect(LinkAction.needsToken("reply"))
    #expect(LinkAction.needsToken("anything-new"))
    #expect(!LinkAction.needsToken("open"))
    #expect(!LinkAction.needsToken("focus"))
}

@Test func paceMarksAnEvenRateAndWhenTheWindowRunsDry() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let week: Double = 604_800
    // A day into the week with 41% used: ahead of the 14% an even week would be.
    let ahead = QuotaWindow(name: "7d", usedPercent: 41, windowSeconds: week, resetAt: now.addingTimeInterval(week - 86_400))
    let pace = try! #require(ahead.pace(at: now))
    #expect(abs(pace.expected - 100.0 / 7) < 0.01)
    // 59% left at 41% a day lasts about 1.44 days more.
    #expect(abs(pace.runsOut!.timeIntervalSince(now) - 59 * 86_400 / 41) < 1)

    let behind = QuotaWindow(name: "7d", usedPercent: 5, windowSeconds: week, resetAt: now.addingTimeInterval(week - 86_400))
    #expect(behind.pace(at: now)?.runsOut == nil)
    // Too early in the window to say, and no reset to say it against.
    #expect(QuotaWindow(name: "7d", usedPercent: 5, windowSeconds: week, resetAt: now.addingTimeInterval(week - 600)).pace(at: now) == nil)
    #expect(QuotaWindow(name: "7d", usedPercent: 5, windowSeconds: week, resetAt: nil).pace(at: now) == nil)
    #expect(Formatting.runsOut(now.addingTimeInterval(7_800), now: now) == "Runs out in 2h 10m")
    #expect(Formatting.runsOut(now.addingTimeInterval(-5), now: now) == "Ran out")
}

@Test func resetsReadInHoursWithinADayAndAsADateAfter() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    #expect(Formatting.resetText(now.addingTimeInterval(15_660), now: now) == "Resets in 4 hr 21 min")
    #expect(Formatting.resetText(now.addingTimeInterval(1_200), now: now) == "Resets in 20 min")
    #expect(Formatting.resetText(now.addingTimeInterval(-1), now: now) == "Resetting")
    #expect(!Formatting.resetText(now.addingTimeInterval(518_400), now: now).contains("Resets"))
}

@Test func ringsShrinkSoEveryProviderFitsAPairedWidget() {
    let paired = RingLayout(count: 3, width: 224, compact: true)
    #expect(paired.visible == 3)
    #expect(paired.diameter >= 36 && paired.diameter <= 50)

    let solo = RingLayout(count: 3, width: 424, compact: false)
    #expect(solo.visible == 3)
    #expect(solo.diameter == 62)

    // Past the smallest readable ring, the rest are left out instead of shrinking further.
    #expect(RingLayout(count: 8, width: 224, compact: true).visible == 3)
}

@MainActor @Test func providersReadByTheirProductName() {
    #expect(ProviderStyle.displayName("claude-code") == "Claude")
    #expect(ProviderStyle.displayName("anthropic") == "Claude")
    #expect(ProviderStyle.displayName("openai") == "OpenAI")
    #expect(ProviderStyle.displayName("") == "OpenChamber")
}

@Test func copilotsTwinQuotaShowsOnceAndUnlimitedSaysSo() {
    let reset = Date(timeIntervalSince1970: 1_801_000_000)
    let premium = [QuotaWindow(name: "premium_interactions", usedPercent: nil, windowSeconds: nil, resetAt: reset, valueLabel: "Unlimited")]
    let copilot = ProviderQuota(id: "github-copilot", provider: "github-copilot", name: "GitHub Copilot", plan: nil, windows: premium)
    let addon = ProviderQuota(id: "github-copilot-addon", provider: "github-copilot-addon", name: "GitHub Copilot Add-on", plan: nil, windows: premium)
    let claude = ProviderQuota(id: "claude", provider: "claude", name: "Claude", plan: nil, windows: [
        QuotaWindow(name: "5h", usedPercent: 20, windowSeconds: 18_000, resetAt: reset),
    ])

    #expect(ProviderQuota.distinct([claude, copilot, addon]).map(\.id) == ["claude", "github-copilot"])
    #expect(copilot.caption == "Unlimited")
    #expect(copilot.percentLeft == nil)
    #expect(claude.caption == "80% left")
}

@Test func sessionLinksNameTheirHostForDesktopsThatReadIt() {
    #expect(DesktopLinks.session("ses_1", host: "9bc34f85-c5be") == URL(string: "openchamber://session/ses_1?host=9bc34f85-c5be"))
    #expect(DesktopLinks.session("ses_1", host: "local") == URL(string: "openchamber://session/ses_1?host=local"))
    #expect(DesktopLinks.session("ses_1", host: nil) == URL(string: "openchamber://session/ses_1"))
    #expect(DesktopLinks.host("9bc34f85-c5be") == URL(string: "openchamber://host/9bc34f85-c5be"))
    #expect(DesktopLinks.focus == URL(string: "openchamber://focus"))
    #expect(!DesktopLinks.namesHosts(version: "2.5.0"))
    #expect(!DesktopLinks.namesHosts(version: "2.4.12"))
    #expect(DesktopLinks.namesHosts(version: "2.5.1"))
    #expect(DesktopLinks.namesHosts(version: "2.10.0"))
}

@Test func desktopsListeningPortsComeFromLsofNameLines() {
    let output = "p39131\nf31\nn*:57123\nf40\nn127.0.0.1:62510\nf41\nn[::1]:8080\n"
    #expect(DesktopServers.listeningPorts(lsofOutput: output) == [57123, 62510, 8080])
    #expect(DesktopServers.listeningPorts(lsofOutput: "") == [])
}

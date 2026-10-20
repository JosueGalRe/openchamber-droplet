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

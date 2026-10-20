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
             "clientToken": "oc_client_remote", "requestHeaders": ["CF-Access-Client-Id": "abc"]],
            ["id": "h2", "label": "Relay only", "url": "relay://server", "clientToken": "oc_client_relay"],
            ["id": "h3", "label": "No token", "url": "http://10.0.0.9:4097/"],
        ],
    ]
    let servers = DesktopServers.parse(try JSONSerialization.data(withJSONObject: settings))

    #expect(servers.map(\.id) == [ChamberServer.localID, "h1"])
    #expect(servers[0].baseURL.absoluteString == "http://127.0.0.1:4097")
    #expect(servers[0].token == "oc_client_local")
    // Desktop talks to a host's API at `apiUrl` when it has one.
    #expect(servers[1].baseURL.absoluteString == "http://10.0.0.5:4097/")
    #expect(servers[1].headers == ["CF-Access-Client-Id": "abc"])
    #expect(servers[1].baseURL.origin == "http://10.0.0.5:4097")
}

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

import Foundation
import Testing
@testable import Openchamber

private func link(_ payload: [String: Any]) -> String {
    let data = try! JSONSerialization.data(withJSONObject: payload)
    let base64url = data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return "openchamber://connect?v=2&p=\(base64url)"
}

@Test func aPairingLinkYieldsItsIdAndSecret() throws {
    let pairing = try OpenChamberClient.pairingPayload(from: link([
        "v": 2, "pairingId": "pair_abc", "secret": "s3cr3t",
        "expiresAt": ISO8601DateFormatter().string(from: Date().addingTimeInterval(600)),
        "candidates": [["type": "lan", "url": "http://192.168.1.20:4097"]],
    ]))
    #expect(pairing.id == "pair_abc")
    #expect(pairing.secret == "s3cr3t")
}

@Test func expiredOrForeignLinksAreRefused() {
    let expired = link(["pairingId": "pair_abc", "secret": "s", "expiresAt": "2020-01-01T00:00:00.000Z"])
    #expect(throws: OpenChamberError.self) { try OpenChamberClient.pairingPayload(from: expired) }
    #expect(throws: OpenChamberError.badPairingLink) { try OpenChamberClient.pairingPayload(from: "https://example.com/?p=abc") }
    #expect(throws: OpenChamberError.badPairingLink) { try OpenChamberClient.pairingPayload(from: "openchamber://connect?p=not-json") }
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

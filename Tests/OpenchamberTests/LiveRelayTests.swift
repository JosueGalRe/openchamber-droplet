import Foundation
import Testing
@testable import Openchamber

/// Talks to a real server through OpenChamber's relay, with the servers and
/// tokens OpenChamber Desktop has on this Mac. Off unless asked for:
///
///     OPENCHAMBER_LIVE_RELAY=1 swift test --filter liveRelay
@Test(.enabled(if: ProcessInfo.processInfo.environment["OPENCHAMBER_LIVE_RELAY"] == "1"))
func liveRelayReachesARemoteServer() async throws {
    let server = try #require(DesktopServers.load().first { $0.relay != nil }, "no relay host in OpenChamber Desktop's settings")
    let config = try #require(server.relay)

    // Is the relay reachable at all from this process (Little Snitch, network)?
    var components = URLComponents(url: config.url, resolvingAgainstBaseURL: false)!
    components.queryItems = [URLQueryItem(name: "v", value: "1"), URLQueryItem(name: "role", value: "client"), URLQueryItem(name: "serverId", value: config.serverID)]
    let probe = URLSession.shared.webSocketTask(with: components.url!)
    probe.resume()
    let pinged: Bool = await withCheckedContinuation { continuation in
        probe.sendPing { error in
            print("relay socket ping: \(error.map { "\($0)" } ?? "ok")")
            continuation.resume(returning: error == nil)
        }
    }
    probe.cancel(with: .normalClosure, reason: nil)
    try #require(pinged, "the relay WebSocket did not open")

    let tunnel = RelayTunnel(config: config)
    try await tunnel.connect(appVersion: "droplet-live-test")

    let client = OpenChamberClient(server: server, route: .relay(tunnel))
    guard case let .seeded(busy, permissions, forms, _) = try await client.seed() else {
        Issue.record("the seed was not a seed")
        return
    }
    let sessions = try await client.recentSessions(limit: 5)
    print("relay → \(server.label): \(busy.count) busy, \(permissions.count) permissions, \(forms.count) forms, \(sessions.count) recent sessions")
    #expect(!sessions.isEmpty)

    var ready = false
    for try await frame in try await client.events(after: nil) {
        if case .ready = frame { ready = true; break }
    }
    #expect(ready)
    await tunnel.close()
}

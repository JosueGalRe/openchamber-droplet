//
//  OpenChamberClient.swift
//  Openchamber
//
//  The OpenChamber server, as this droplet uses it: a paired-device bearer
//  token for REST, a 60-second URL token for the global event WebSocket, and
//  OpenCode's own `/api/session/...` routes, which OpenChamber proxies as is.
//

import Foundation
import Security

enum OpenChamberError: Error, Equatable, LocalizedError {
    case unauthorized
    case badPairingLink
    case pairingRejected(String)
    case http(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .unauthorized: return "OpenChamber no longer accepts this device. Pair it again."
        case .badPairingLink: return "That is not an OpenChamber pairing link."
        case let .pairingRejected(message): return message
        case let .http(status): return "OpenChamber answered \(status)."
        case .invalidResponse: return "OpenChamber sent something this droplet cannot read."
        }
    }
}

struct QuotaWindow: Equatable, Sendable, Identifiable {
    var id: String { name }
    let name: String
    let usedPercent: Double?
    let windowSeconds: Double?
    let resetAt: Date?
}

struct ProviderQuota: Equatable, Sendable, Identifiable {
    let id: String
    let name: String
    let plan: String?
    /// Shortest window first, the order OpenChamber's Usage page reads.
    let windows: [QuotaWindow]

    /// The window closest to running out.
    var tightest: QuotaWindow? { windows.max { ($0.usedPercent ?? 0) < ($1.usedPercent ?? 0) } }
}

/// One frame of the global event stream, already lifted out of JSON.
enum EventFrame: Sendable {
    /// The server is streaming. `replayReset` means the cursor we sent was
    /// gone, so anything missed has to come from a fresh seed.
    case ready(replayReset: Bool)
    case event(ActivityEvent?, eventID: String?)
}

actor OpenChamberClient {
    nonisolated let baseURL: URL
    private let token: String
    private let session: URLSession

    init(baseURL: URL, token: String) {
        self.baseURL = baseURL
        self.token = token
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    // MARK: Unauthenticated

    /// `GET /health` answers without auth, so this is how the droplet waits
    /// for OpenChamber to start without spending a token on it.
    static func isReachable(_ baseURL: URL) async -> Bool {
        var request = URLRequest(url: baseURL.appending(path: "health"))
        request.timeoutInterval = 3
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return body["status"] as? String == "ok"
    }

    /// Redeems an `openchamber://connect?v=2&p=…` link against `baseURL` and
    /// returns the device's bearer token. The link's own server candidates are
    /// ignored on purpose: Droppy runs on the Mac OpenChamber runs on.
    static func redeem(link: String, baseURL: URL, deviceKey: String, appVersion: String) async throws -> String {
        let pairing = try pairingPayload(from: link)
        var request = URLRequest(url: baseURL.appending(path: "api/client-auth/pairing/redeem"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "pairingId": pairing.id,
            "secret": pairing.secret,
            "clientLabel": "Droppy",
            "clientKind": "desktop",
            "deviceName": Host.current().localizedName ?? "Mac",
            "devicePlatform": "macos",
            "appVersion": appVersion,
            "dedupeKey": deviceKey,
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw OpenChamberError.pairingRejected(body?["error"] as? String ?? "OpenChamber refused the pairing link.")
        }
        guard let token = body?["clientToken"] as? String, token.hasPrefix("oc_client_") else {
            throw OpenChamberError.invalidResponse
        }
        return token
    }

    static func pairingPayload(from link: String) throws -> (id: String, secret: String) {
        guard let components = URLComponents(string: link.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme == "openchamber", components.host == "connect",
              let encoded = components.queryItems?.first(where: { $0.name == "p" })?.value else {
            throw OpenChamberError.badPairingLink
        }
        var base64 = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = payload["pairingId"] as? String,
              let secret = payload["secret"] as? String else {
            throw OpenChamberError.badPairingLink
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let expires = payload["expiresAt"] as? String,
           let date = fractional.date(from: expires) ?? ISO8601DateFormatter().date(from: expires),
           date < Date() {
            throw OpenChamberError.pairingRejected("That pairing link has expired. Create a new one in OpenChamber.")
        }
        return (id, secret)
    }

    // MARK: Activity

    func seed() async throws -> ActivityEvent {
        guard let body = try await json("GET", "api/sessions/status") as? [String: Any] else { throw OpenChamberError.invalidResponse }
        return ActivityWire.seed(from: body, now: Date())
    }

    /// The most recent sessions across every project, for titles and parents.
    func recentSessions(limit: Int = 100) async throws -> [SessionInfo] {
        let body = try await json("GET", "api/session", query: [URLQueryItem(name: "limit", value: String(limit))]) as? [String: Any]
        return (body?["data"] as? [[String: Any]] ?? []).compactMap(ActivityWire.session(from:))
    }

    func session(id: String) async throws -> SessionInfo? {
        let body = try await json("GET", "api/session/\(id.urlPathEncoded)") as? [String: Any]
        return (body?["data"] as? [String: Any]).flatMap(ActivityWire.session(from:))
    }

    /// `decision` is OpenCode's `once`, `always` or `reject`.
    func reply(to permission: PendingPermission, decision: String) async throws {
        _ = try await json(
            "POST",
            "api/session/\(permission.sessionID.urlPathEncoded)/permission/\(permission.id.urlPathEncoded)/reply",
            directory: permission.directory,
            body: ["decision": decision]
        )
    }

    func interrupt(sessionID: String, directory: String?) async throws {
        _ = try await json("POST", "api/session/\(sessionID.urlPathEncoded)/interrupt", directory: directory)
    }

    // MARK: Usage

    func quotaProviderIDs() async throws -> [String] {
        let body = try await json("GET", "api/quota/providers") as? [String: Any]
        return (body?["providers"] as? [Any] ?? []).compactMap { item in
            if let id = item as? String { return id }
            let record = item as? [String: Any]
            return record?["id"] as? String ?? record?["providerId"] as? String
        }
    }

    func quota(providerID: String) async throws -> ProviderQuota? {
        guard let body = try await json("GET", "api/quota/\(providerID.urlPathEncoded)") as? [String: Any],
              body["ok"] as? Bool == true else { return nil }
        let windows = ((body["usage"] as? [String: Any])?["windows"] as? [String: [String: Any]] ?? [:])
            .map { name, window in
                QuotaWindow(
                    name: name,
                    usedPercent: (window["usedPercent"] as? NSNumber)?.doubleValue,
                    windowSeconds: (window["windowSeconds"] as? NSNumber)?.doubleValue,
                    resetAt: ActivityWire.date(fromMilliseconds: window["resetAt"])
                )
            }
            .sorted { ($0.windowSeconds ?? .infinity) < ($1.windowSeconds ?? .infinity) }
        guard !windows.isEmpty else { return nil }
        return ProviderQuota(
            id: providerID,
            name: body["providerName"] as? String ?? providerID,
            plan: body["planLabel"] as? String,
            windows: windows
        )
    }

    // MARK: Event stream

    /// The global event WebSocket. The upgrade does not read the bearer
    /// header, so each connection mints a 60-second URL token first.
    func events(after lastEventID: String?) async throws -> AsyncThrowingStream<EventFrame, Error> {
        guard let minted = try await json("POST", "auth/url-token") as? [String: Any],
              let urlToken = minted["token"] as? String else { throw OpenChamberError.invalidResponse }

        var components = URLComponents(url: baseURL.appending(path: "api/global/event/ws"), resolvingAgainstBaseURL: false)!
        components.scheme = baseURL.scheme == "https" ? "wss" : "ws"
        components.queryItems = [URLQueryItem(name: "oc_url_token", value: urlToken)]
            + (lastEventID.map { [URLQueryItem(name: "lastEventId", value: $0)] } ?? [])

        let task = session.webSocketTask(with: components.url!)
        // A tool's output rides in its success event; the default 1 MB cap
        // would drop the connection on one large read.
        task.maximumMessageSize = 16 * 1024 * 1024
        task.resume()

        return AsyncThrowingStream { continuation in
            let reader = Task {
                do {
                    while !Task.isCancelled {
                        let message = try await task.receive()
                        guard case let .string(text) = message, let frame = Self.frame(from: text) else { continue }
                        continuation.yield(frame)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                reader.cancel()
                task.cancel(with: .goingAway, reason: nil)
            }
        }
    }

    static func frame(from text: String) -> EventFrame? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return nil }
        switch object["type"] as? String {
        case "ready":
            return .ready(replayReset: object["replayReset"] as? Bool ?? false)
        case "event":
            let eventID = object["eventId"] as? String
            let event = (object["payload"] as? [String: Any]).flatMap { ActivityWire.event(from: $0, now: Date()) }
            guard event != nil || eventID != nil else { return nil }
            return .event(event, eventID: eventID)
        default:
            return nil
        }
    }

    // MARK: HTTP

    private func json(
        _ method: String,
        _ path: String,
        query: [URLQueryItem] = [],
        directory: String? = nil,
        body: [String: Any]? = nil
    ) async throws -> Any? {
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let directory {
            // OpenCode scopes a request to a project through this header, and
            // rejects non-ASCII header values unless they are percent-encoded.
            request.setValue(directory.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? directory, forHTTPHeaderField: "x-opencode-directory")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw OpenChamberError.invalidResponse }
        if status == 401 { throw OpenChamberError.unauthorized }
        guard (200..<300).contains(status) else { throw OpenChamberError.http(status) }
        return data.isEmpty ? nil : try JSONSerialization.jsonObject(with: data)
    }
}

// MARK: - Keychain

/// The device token lives in the Keychain, never in the droplet's preferences,
/// which are plain user defaults.
enum TokenStore {
    private static let service = "app.getdroppy.droplet.openchamber"

    static func read(for server: URL) -> String? {
        var item: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: server.absoluteString,
            kSecReturnData: true,
        ] as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func save(_ token: String, for server: URL) -> Bool {
        delete(for: server)
        return SecItemAdd([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: server.absoluteString,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData: Data(token.utf8),
        ] as CFDictionary, nil) == errSecSuccess
    }

    static func delete(for server: URL) {
        SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: server.absoluteString,
        ] as CFDictionary)
    }
}

private extension String {
    var urlPathEncoded: String { addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/"])) ?? self }
}

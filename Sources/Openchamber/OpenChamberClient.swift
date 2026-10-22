//
//  OpenChamberClient.swift
//  Openchamber
//
//  One OpenChamber server, as this droplet uses it: the bearer token
//  OpenChamber Desktop already holds for it, a 60-second URL token for the
//  global event WebSocket, and OpenCode's own `/api/session/...` routes, which
//  OpenChamber proxies as is.
//

import Foundation

enum OpenChamberError: Error, Equatable, LocalizedError {
    case unauthorized
    case http(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .unauthorized: return "OpenChamber rejected the token OpenChamber Desktop has for this server."
        case let .http(status): return "OpenChamber answered \(status)."
        case .invalidResponse: return "OpenChamber sent something this droplet cannot read."
        }
    }
}

/// A server OpenChamber Desktop on this Mac already talks to.
struct ChamberServer: Equatable, Sendable, Identifiable {
    static let localID = "local"

    let id: String
    let label: String
    /// Direct addresses, tried in order: Desktop's API address, then its UI one.
    let directURLs: [URL]
    /// The relay transport, for when no direct address answers.
    let relay: RelayConfig?
    let token: String
    /// Headers OpenChamber Desktop sends to this host, for example an access proxy's.
    let headers: [String: String]

    var isLocal: Bool { id == Self.localID }
}

/// How one connection reaches its server.
enum Route: Sendable {
    case direct(URL)
    case relay(RelayTunnel)

    var description: String {
        switch self {
        case let .direct(url): return url.origin
        case .relay: return "Through OpenChamber's relay"
        }
    }
}

/// OpenChamber Desktop's own list of servers and tokens.
///
/// shortcut: reads Desktop's private settings file, which is fine for one
/// person's Mac and would not pass Store review; a Store build would pair each
/// server instead.
/// The `openchamber://` links OpenChamber Desktop opens.
enum DesktopLinks {
    static let bundleID = "dev.openchamber.desktop"

    /// `openchamber://session/<id>?host=<id>`. Desktop after 2.5.0 opens it on
    /// the instance it names, in place or in that instance's own window
    /// (openchamber/openchamber#5366); `local` is Desktop's own server.
    static func session(_ id: String, host: String?) -> URL? {
        var link = URLComponents()
        link.scheme = "openchamber"
        link.host = "session"
        link.path = "/" + id
        if let host { link.queryItems = [URLQueryItem(name: "host", value: host)] }
        return link.url
    }

    /// `openchamber://host/<id>`: switches Desktop's main window to that instance.
    static func host(_ id: String) -> URL? {
        var link = URLComponents()
        link.scheme = "openchamber"
        link.host = "host"
        link.path = "/" + id
        return link.url
    }

    /// Whether a Desktop of this version reads `?host=`: every release after 2.5.0.
    static func namesHosts(version: String) -> Bool {
        version.compare("2.5.0", options: .numeric) == .orderedDescending
    }
}

enum DesktopServers {
    static var settingsFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/openchamber/settings.json")
    }

    static func load(from file: URL = settingsFile) -> [ChamberServer] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return parse(data)
    }

    /// The file also holds the UI password and other settings: only the
    /// fields a server needs leave this function.
    static func parse(_ data: Data) -> [ChamberServer] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var servers: [ChamberServer] = []

        if let token = root["desktopLocalClientToken"] as? String, !token.isEmpty {
            let port = (root["desktopLocalPort"] as? NSNumber)?.intValue ?? 4097
            servers.append(ChamberServer(
                id: ChamberServer.localID,
                label: "This Mac",
                directURLs: [URL(string: "http://127.0.0.1:\(port)")!],
                relay: nil,
                token: token,
                headers: [:]
            ))
        }

        for host in root["desktopHosts"] as? [[String: Any]] ?? [] {
            guard let id = host["id"] as? String,
                  let token = host["clientToken"] as? String, !token.isEmpty else { continue }
            var direct: [URL] = []
            for address in [host["apiUrl"], host["url"]].compactMap({ $0 as? String }) {
                guard let url = URL(string: address), url.scheme == "http" || url.scheme == "https",
                      !direct.contains(url) else { continue }
                direct.append(url)
            }
            let relay = (host["relay"] as? [String: Any]).flatMap(RelayConfig.init)
            guard !direct.isEmpty || relay != nil else { continue }
            servers.append(ChamberServer(
                id: id,
                label: host["label"] as? String ?? direct.first?.host() ?? id,
                directURLs: direct,
                relay: relay,
                token: token,
                headers: host["requestHeaders"] as? [String: String] ?? [:]
            ))
        }
        return servers
    }
}

struct QuotaWindow: Equatable, Sendable, Identifiable {
    var id: String { "\(model ?? "").\(name)" }
    /// OpenChamber's key for the window: `5h`, `7d`, `extra_usage`, …
    let name: String
    /// Set for a window that limits one model, such as Claude's weekly Fable limit.
    var model: String? = nil
    let usedPercent: Double?
    let windowSeconds: Double?
    let resetAt: Date?
    /// What a window without a percentage shows instead, such as a credit balance.
    var valueLabel: String? = nil
}

struct ProviderQuota: Equatable, Sendable, Identifiable {
    /// Unique across servers.
    let id: String
    /// OpenChamber's provider id, which picks the icon and colour.
    let provider: String
    let name: String
    let plan: String?
    /// The remote server this came from; nil for this Mac.
    var server: String? = nil
    /// Account-wide windows first, shortest first, then each model's.
    let windows: [QuotaWindow]

    /// The window closest to running out.
    var tightest: QuotaWindow? { windows.max { ($0.usedPercent ?? 0) < ($1.usedPercent ?? 0) } }
    /// What is left of the tightest window, the number Agents puts under its ring.
    var percentLeft: Double? {
        windows.compactMap(\.usedPercent).max().map { max(0, 100 - $0) }
    }

    /// What goes under the ring: "93% left", or a plan's own word for it
    /// ("Unlimited") when no window has a percentage.
    var caption: String {
        if let left = percentLeft { return "\(Int(left.rounded()))% left" }
        return windows.compactMap(\.valueLabel).first ?? "–"
    }

    /// One server's providers, without the ones that repeat another's windows
    /// exactly: OpenChamber lists Copilot twice (`github-copilot` and
    /// `github-copilot-addon` read the same quota), and two rings with the
    /// same numbers read as two accounts.
    static func distinct(_ quotas: [ProviderQuota]) -> [ProviderQuota] {
        quotas.reduce(into: []) { kept, quota in
            if !kept.contains(where: { $0.windows == quota.windows }) { kept.append(quota) }
        }
    }
}

/// One frame of the global event stream, already lifted out of JSON.
enum EventFrame: Sendable {
    /// The server is streaming. `replayReset` means the cursor we sent was
    /// gone, so anything missed has to come from a fresh seed.
    case ready(replayReset: Bool)
    case event(ActivityEvent?, eventID: String?)
}

actor OpenChamberClient {
    nonisolated let server: ChamberServer
    nonisolated let route: Route
    private let session: URLSession

    init(server: ChamberServer, route: Route) {
        self.server = server
        self.route = route
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    /// `GET /health` answers without auth, so this is how the droplet waits
    /// for a server to come up without spending a token on it.
    static func isReachable(_ baseURL: URL) async -> Bool {
        var request = URLRequest(url: baseURL.appending(path: "health"))
        request.timeoutInterval = 3
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return body["status"] as? String == "ok"
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
        let body = try await json("GET", "api/quota/\(providerID.urlPathEncoded)") as? [String: Any]
        return body.flatMap { Self.quota(from: $0, providerID: providerID) }
    }

    /// One provider's `GET /api/quota/:id` body, with its per-model windows.
    static func quota(from body: [String: Any], providerID: String) -> ProviderQuota? {
        guard body["ok"] as? Bool == true, let usage = body["usage"] as? [String: Any] else { return nil }
        func windows(_ record: Any?, model: String?) -> [QuotaWindow] {
            ((record as? [String: [String: Any]]) ?? [:])
                .map { name, window in
                    QuotaWindow(
                        name: name,
                        model: model,
                        usedPercent: (window["usedPercent"] as? NSNumber)?.doubleValue,
                        windowSeconds: (window["windowSeconds"] as? NSNumber)?.doubleValue,
                        resetAt: ActivityWire.date(fromMilliseconds: window["resetAt"]),
                        valueLabel: window["valueLabel"] as? String
                    )
                }
                .sorted { ($0.windowSeconds ?? .infinity, $0.name) < ($1.windowSeconds ?? .infinity, $1.name) }
        }
        var all = windows(usage["windows"], model: nil)
        for (model, record) in ((usage["models"] as? [String: [String: Any]]) ?? [:]).sorted(by: { $0.key < $1.key }) {
            all += windows(record["windows"], model: model)
        }
        guard !all.isEmpty else { return nil }
        return ProviderQuota(
            id: providerID,
            provider: providerID,
            name: body["providerName"] as? String ?? providerID,
            plan: body["planLabel"] as? String,
            windows: all
        )
    }

    // MARK: Event stream

    /// The global event WebSocket. The upgrade does not read the bearer
    /// header, so each connection mints a 60-second URL token first.
    func events(after lastEventID: String?) async throws -> AsyncThrowingStream<EventFrame, Error> {
        guard let minted = try await json("POST", "auth/url-token") as? [String: Any],
              let urlToken = minted["token"] as? String else { throw OpenChamberError.invalidResponse }
        let query = [URLQueryItem(name: "oc_url_token", value: urlToken)]
            + (lastEventID.map { [URLQueryItem(name: "lastEventId", value: $0)] } ?? [])

        let baseURL: URL
        switch route {
        case let .relay(tunnel):
            // The host opens the socket on its own loopback, with its own origin.
            var components = URLComponents()
            components.queryItems = query
            let messages = try await tunnel.webSocket(path: "/api/global/event/ws", query: components.percentEncodedQuery ?? "")
            return AsyncThrowingStream { continuation in
                let reader = Task {
                    do {
                        for try await text in messages {
                            if let frame = Self.frame(from: text) { continuation.yield(frame) }
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in reader.cancel() }
            }
        case let .direct(url):
            baseURL = url
        }

        var components = URLComponents(url: baseURL.appending(path: "api/global/event/ws"), resolvingAgainstBaseURL: false)!
        components.scheme = baseURL.scheme == "https" ? "wss" : "ws"
        components.queryItems = query

        // The upgrade is refused without an Origin matching the server's own
        // host (`isRequestOriginAllowed`), and URLSession sends none.
        var request = URLRequest(url: components.url!)
        for (name, value) in server.headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue(baseURL.origin, forHTTPHeaderField: "Origin")
        let task = session.webSocketTask(with: request)
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
        var headers = [
            "Authorization": "Bearer \(server.token)",
            "Accept": "application/json",
        ]
        if let directory {
            // OpenCode scopes a request to a project through this header, and
            // rejects non-ASCII header values unless they are percent-encoded.
            headers["x-opencode-directory"] = directory.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? directory
        }
        let payload = try body.map { try JSONSerialization.data(withJSONObject: $0) }
        if payload != nil { headers["Content-Type"] = "application/json" }

        let status: Int
        let data: Data
        switch route {
        case let .relay(tunnel):
            var components = URLComponents()
            if !query.isEmpty { components.queryItems = query }
            (status, data) = try await tunnel.request(
                method: method, path: "/" + path, query: components.percentEncodedQuery ?? "", headers: headers, body: payload
            )
        case let .direct(baseURL):
            var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
            if !query.isEmpty { components.queryItems = query }
            var request = URLRequest(url: components.url!)
            request.httpMethod = method
            for (name, value) in server.headers.merging(headers, uniquingKeysWith: { $1 }) {
                request.setValue(value, forHTTPHeaderField: name)
            }
            request.httpBody = payload
            let (body, response) = try await session.data(for: request)
            guard let code = (response as? HTTPURLResponse)?.statusCode else { throw OpenChamberError.invalidResponse }
            (status, data) = (code, body)
        }
        if status == 401 { throw OpenChamberError.unauthorized }
        guard (200..<300).contains(status) else { throw OpenChamberError.http(status) }
        return data.isEmpty ? nil : try JSONSerialization.jsonObject(with: data)
    }
}

private extension String {
    var urlPathEncoded: String { addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/"])) ?? self }
}

extension URL {
    /// `http://127.0.0.1:4097`: scheme, host and port, as a browser's Origin header.
    var origin: String {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host()
        components.port = port
        return components.string ?? absoluteString
    }
}

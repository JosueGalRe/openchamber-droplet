//
//  RelayTunnel.swift
//  Openchamber
//
//  The client side of OpenChamber's private relay, for a server this Mac
//  cannot reach directly. A port of packages/ui/src/lib/relay/ in OpenChamber:
//  a WebSocket to the relay, an end-to-end encrypted channel to the host
//  (ECDH P-256, HKDF-SHA-256, AES-256-GCM), and HTTP and WebSocket streams
//  multiplexed inside it. The relay only forwards ciphertext.
//
//  Batching, downstream flow control and gzip are optional in the protocol and
//  left out: this client never advertises them, so the host uses its plain path.
//

import CryptoKit
import Foundation

/// The relay transport OpenChamber Desktop keeps for a host.
struct RelayConfig: Equatable, Sendable {
    let url: URL
    let serverID: String
    /// The host's long-lived encryption key, the channel's trust anchor.
    let hostKeyX: Data
    let hostKeyY: Data

    init?(_ record: [String: Any]) {
        guard let address = record["relayUrl"] as? String, let url = URL(string: address),
              url.scheme == "wss" || url.scheme == "ws",
              let serverID = record["serverId"] as? String,
              let jwk = record["hostEncPubJwk"] as? [String: Any],
              jwk["kty"] as? String == "EC", jwk["crv"] as? String == "P-256",
              let x = (jwk["x"] as? String).flatMap(Data.init(base64URL:)),
              let y = (jwk["y"] as? String).flatMap(Data.init(base64URL:)) else { return nil }
        self.url = url
        self.serverID = serverID
        hostKeyX = x
        hostKeyY = y
    }
}

enum RelayError: Error, Equatable, LocalizedError {
    /// The relay closed the leg, or asked this peer to (`relay-retire`).
    case closed(code: Int, reason: String)
    case handshakeTimeout
    case keepaliveTimeout
    case requestTimeout
    case streamAborted(String)
    case protocolViolation(String)

    var errorDescription: String? {
        switch self {
        case let .closed(code, reason): return "The relay closed the connection (\(code)\(reason.isEmpty ? "" : ": \(reason)"))."
        case .handshakeTimeout: return "The host did not answer through the relay."
        case .keepaliveTimeout: return "The relay connection went quiet."
        case .requestTimeout: return "A request through the relay timed out."
        case let .streamAborted(reason): return "The host aborted a relayed request: \(reason)."
        case let .protocolViolation(detail): return "The relay channel broke: \(detail)."
        }
    }

    /// The relay replaced this leg with another from the same device. Retrying
    /// at once would take the leg back and drop the other side in turn.
    var isDuplicateClient: Bool {
        if case .closed(4002, _) = self { return true }
        return false
    }
}

// MARK: - Layer 2: encryption

enum RelayCrypto {
    static let hkdfInfo = Data("openchamber-relay-v1".utf8)
    static let frameVersion: UInt8 = 1

    /// Both peers derive the same two keys: ECDH, then HKDF-SHA-256 salted with
    /// the client's handshake nonce, split into client-to-host and host-to-client.
    static func sessionKeys(
        own: P256.KeyAgreement.PrivateKey,
        peer: P256.KeyAgreement.PublicKey,
        nonce: Data
    ) throws -> (clientToHost: SymmetricKey, hostToClient: SymmetricKey) {
        let shared = try own.sharedSecretFromKeyAgreement(with: peer)
        let material = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: nonce, sharedInfo: hkdfInfo, outputByteCount: 64)
        let bytes = material.withUnsafeBytes { Data($0) }
        return (SymmetricKey(data: bytes.prefix(32)), SymmetricKey(data: bytes.suffix(32)))
    }

    static func publicKey(x: Data, y: Data) throws -> P256.KeyAgreement.PublicKey {
        try P256.KeyAgreement.PublicKey(rawRepresentation: x + y)
    }

    static func jwk(_ key: P256.KeyAgreement.PublicKey) -> [String: String] {
        let raw = key.rawRepresentation
        return ["kty": "EC", "crv": "P-256", "x": raw.prefix(32).base64URL, "y": raw.suffix(32).base64URL]
    }
}

/// Seals outbound frames: `[version][4-byte random prefix + 8-byte counter][ciphertext][tag]`.
struct FrameSealer {
    let key: SymmetricKey
    let prefix: Data
    private(set) var counter: UInt64 = 0

    init(key: SymmetricKey, prefix: Data = Data((0..<4).map { _ in UInt8.random(in: 0...255) })) {
        self.key = key
        self.prefix = prefix
    }

    mutating func seal(_ plaintext: Data) throws -> Data {
        counter += 1
        let iv = prefix + withUnsafeBytes(of: counter.bigEndian) { Data($0) }
        let box = try AES.GCM.seal(plaintext, using: key, nonce: AES.GCM.Nonce(data: iv))
        return Data([RelayCrypto.frameVersion]) + iv + box.ciphertext + box.tag
    }
}

/// Opens inbound frames, refusing any counter that does not increase: the
/// relay keeps order, so a repeat or a step back means tampering.
struct FrameOpener {
    let key: SymmetricKey
    private(set) var lastCounter: UInt64 = 0

    init(key: SymmetricKey) { self.key = key }

    mutating func open(_ frame: Data) throws -> Data {
        let bytes = [UInt8](frame)
        guard bytes.count >= 1 + 12 + 16 else { throw RelayError.protocolViolation("encrypted frame too short") }
        guard bytes[0] == RelayCrypto.frameVersion else { throw RelayError.protocolViolation("unknown frame version") }
        let iv = Data(bytes[1..<13])
        let counter = bytes[5..<13].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        guard counter > lastCounter else { throw RelayError.protocolViolation("frame counter went backwards") }
        let box = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: iv),
            ciphertext: Data(bytes[13..<(bytes.count - 16)]),
            tag: Data(bytes[(bytes.count - 16)...])
        )
        let plaintext = try AES.GCM.open(box, using: key)
        lastCounter = counter
        return plaintext
    }
}

// MARK: - Layer 3: tunnel frames

enum TunnelFrameType: UInt8 {
    case httpRequest = 1, httpBody, httpResponse, streamEnd, streamAbort
    case wsOpen, wsOpened, wsText, wsBinary, wsClose
    case ping, pong, deliveryAck
}

struct TunnelFrame: Equatable {
    static let fragmentFlag: UInt8 = 0x80
    /// 64 KiB per encrypted plaintext, less the header and the batch envelope reserve.
    static let maxPayload = 64 * 1024 - 5 - 5

    let type: TunnelFrameType
    let stream: UInt32
    let payload: Data
    /// More fragments of the same WebSocket message follow.
    var hasMore = false

    var encoded: Data {
        var header = Data([hasMore ? type.rawValue | Self.fragmentFlag : type.rawValue])
        header.append(contentsOf: withUnsafeBytes(of: stream.bigEndian) { Array($0) })
        return header + payload
    }

    init(_ type: TunnelFrameType, stream: UInt32, payload: Data = Data(), hasMore: Bool = false) {
        self.type = type
        self.stream = stream
        self.payload = payload
        self.hasMore = hasMore
    }

    init(decoding data: Data) throws {
        let bytes = [UInt8](data)
        guard bytes.count >= 5 else { throw RelayError.protocolViolation("tunnel frame too short") }
        guard let type = TunnelFrameType(rawValue: bytes[0] & ~Self.fragmentFlag) else {
            throw RelayError.protocolViolation("unknown tunnel frame type \(bytes[0] & ~Self.fragmentFlag)")
        }
        self.type = type
        hasMore = bytes[0] & Self.fragmentFlag != 0
        stream = bytes[1..<5].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        payload = Data(bytes[5...])
    }

    /// One payload as frames of at most ``maxPayload`` bytes; an empty payload is one empty frame.
    static func chunks(of payload: Data) -> [Data] {
        guard !payload.isEmpty else { return [Data()] }
        return stride(from: 0, to: payload.count, by: maxPayload).map {
            payload.subdata(in: payload.index(payload.startIndex, offsetBy: $0)..<payload.index(payload.startIndex, offsetBy: min($0 + maxPayload, payload.count)))
        }
    }
}

// MARK: - The tunnel

actor RelayTunnel {
    nonisolated let config: RelayConfig
    private let session: URLSession
    private var socket: URLSessionWebSocketTask?
    private var sealer: FrameSealer?
    private var opener: FrameOpener?
    private var nextStream: UInt32 = 1
    private var requests: [UInt32: PendingRequest] = [:]
    private var sockets: [UInt32: PendingSocket] = [:]
    private var reader: Task<Void, Never>?
    private var keepalive: Task<Void, Never>?
    private var lastReceivedAt = Date()
    private(set) var failure: Error?

    private struct PendingRequest {
        let continuation: CheckedContinuation<(status: Int, body: Data), Error>
        var status: Int?
        var body = Data()
    }

    private struct PendingSocket {
        let continuation: AsyncThrowingStream<String, Error>.Continuation
        var fragments = Data()
    }

    init(config: RelayConfig) {
        self.config = config
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    /// Dials the relay and runs the handshake. Throws if the host does not
    /// answer within 30 seconds or answers with anything but `ready`.
    func connect(appVersion: String) async throws {
        var components = URLComponents(url: config.url, resolvingAgainstBaseURL: false)!
        components.queryItems = (components.queryItems ?? []) + [
            URLQueryItem(name: "v", value: "1"),
            URLQueryItem(name: "role", value: "client"),
            URLQueryItem(name: "serverId", value: config.serverID),
            URLQueryItem(name: "appId", value: "openchamber"),
            URLQueryItem(name: "appVersion", value: appVersion),
            URLQueryItem(name: "platform", value: "desktop"),
        ]
        let socket = session.webSocketTask(with: components.url!)
        // Ciphertext frames are at most 64 KiB plus the header and tag.
        socket.maximumMessageSize = 1024 * 1024
        self.socket = socket
        socket.resume()

        let ephemeral = P256.KeyAgreement.PrivateKey()
        let nonce = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let hello = try String(decoding: JSONSerialization.data(withJSONObject: [
            "t": "hello",
            "v": 1,
            "clientPubJwk": RelayCrypto.jwk(ephemeral.publicKey),
            "nonce": nonce.base64URL,
        ]), as: UTF8.self)

        // The host may miss the first hello while its data leg comes up, so it
        // is repeated every second until `ready`, as OpenChamber's client does.
        let helloLoop = Task {
            while !Task.isCancelled {
                socket.send(.string(hello)) { _ in }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        let deadline = Task {
            try? await Task.sleep(for: .seconds(30))
            if !Task.isCancelled { socket.cancel(with: .goingAway, reason: nil) }
        }
        defer {
            helloLoop.cancel()
            deadline.cancel()
        }

        let started = Date()
        while true {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await socket.receive()
            } catch {
                if Date().timeIntervalSince(started) >= 29 { throw RelayError.handshakeTimeout }
                throw Self.closeError(of: socket) ?? error
            }
            guard case let .string(text) = message else {
                throw RelayError.protocolViolation("encrypted frame before the handshake finished")
            }
            if let retire = Self.retire(from: text) { throw retire }
            guard let reply = Self.json(text), reply["t"] as? String == "ready", reply["v"] as? Int == 1 else { continue }
            break
        }

        let keys = try RelayCrypto.sessionKeys(
            own: ephemeral,
            peer: RelayCrypto.publicKey(x: config.hostKeyX, y: config.hostKeyY),
            nonce: nonce
        )
        sealer = FrameSealer(key: keys.clientToHost)
        opener = FrameOpener(key: keys.hostToClient)
        lastReceivedAt = Date()
        reader = Task { await self.readLoop() }
        keepalive = Task { await self.keepaliveLoop() }
    }

    func close() {
        fail(with: RelayError.closed(code: 1000, reason: "closed"))
    }

    // MARK: Streams

    /// One HTTP exchange through the tunnel. Bodies are small JSON here, so the
    /// response is collected whole.
    func request(method: String, path: String, query: String, headers: [String: String], body: Data?) async throws -> (status: Int, body: Data) {
        if let failure { throw failure }
        let stream = allocateStream()
        let timeout = Task {
            try? await Task.sleep(for: .seconds(15))
            if !Task.isCancelled { self.finishRequest(stream, with: .failure(RelayError.requestTimeout)) }
        }
        defer { timeout.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            requests[stream] = PendingRequest(continuation: continuation)
            let head: [String: Any] = [
                "method": method,
                "path": path,
                "query": query,
                "headers": Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) }),
                "hasBody": body != nil,
            ]
            send(TunnelFrame(.httpRequest, stream: stream, payload: (try? JSONSerialization.data(withJSONObject: head)) ?? Data()))
            if let body {
                for chunk in TunnelFrame.chunks(of: body) { send(TunnelFrame(.httpBody, stream: stream, payload: chunk)) }
            }
            send(TunnelFrame(.streamEnd, stream: stream))
        }
    }

    /// A WebSocket on the host, as a stream of its text messages. Ending the
    /// stream on this side closes the socket on the host.
    func webSocket(path: String, query: String) throws -> AsyncThrowingStream<String, Error> {
        if let failure { throw failure }
        let stream = allocateStream()
        let (messages, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        sockets[stream] = PendingSocket(continuation: continuation)
        continuation.onTermination = { _ in
            Task { await self.closeSocket(stream) }
        }
        let open = (try? JSONSerialization.data(withJSONObject: ["path": path, "query": query])) ?? Data()
        send(TunnelFrame(.wsOpen, stream: stream, payload: open))
        return messages
    }

    private func closeSocket(_ stream: UInt32) {
        guard sockets.removeValue(forKey: stream) != nil else { return }
        let close = (try? JSONSerialization.data(withJSONObject: ["code": 1000, "reason": ""])) ?? Data()
        send(TunnelFrame(.wsClose, stream: stream, payload: close))
    }

    private func allocateStream() -> UInt32 {
        // Client-initiated streams are odd, starting at 1.
        defer { nextStream &+= 2 }
        return nextStream
    }

    // MARK: Wire

    /// Seals and hands one frame to the socket. Synchronous on purpose: the
    /// counter has to reach the wire in the order it was sealed.
    private func send(_ frame: TunnelFrame) {
        guard failure == nil, let socket, var sealer else { return }
        do {
            let sealed = try sealer.seal(frame.encoded)
            self.sealer = sealer
            socket.send(.data(sealed)) { error in
                if let error { Task { await self.fail(with: error) } }
            }
        } catch {
            fail(with: error)
        }
    }

    private func readLoop() async {
        guard let socket else { return }
        do {
            while failure == nil {
                switch try await socket.receive() {
                case let .string(text):
                    // A repeated `ready` answers a repeated hello; anything else
                    // in plaintext after the handshake is a broken channel.
                    if let retire = Self.retire(from: text) { throw retire }
                    if Self.json(text)?["t"] as? String == "ready" { continue }
                    throw RelayError.protocolViolation("plaintext after the handshake")
                case let .data(data):
                    guard var opener else { return }
                    let plaintext = try opener.open(data)
                    self.opener = opener
                    lastReceivedAt = Date()
                    try handle(TunnelFrame(decoding: plaintext))
                @unknown default:
                    continue
                }
            }
        } catch {
            fail(with: Self.closeError(of: socket) ?? error)
        }
    }

    /// Pings stream 0 after 30 quiet seconds and gives up 15 seconds later,
    /// OpenChamber's own cadence. Any received frame counts as liveness.
    private func keepaliveLoop() async {
        while failure == nil, !Task.isCancelled {
            try? await Task.sleep(for: .seconds(30))
            guard failure == nil, Date().timeIntervalSince(lastReceivedAt) >= 30 else { continue }
            let pinged = Date()
            send(TunnelFrame(.ping, stream: 0))
            try? await Task.sleep(for: .seconds(15))
            if failure == nil, lastReceivedAt < pinged { fail(with: RelayError.keepaliveTimeout) }
        }
    }

    private func handle(_ frame: TunnelFrame) throws {
        switch frame.type {
        case .ping:
            send(TunnelFrame(.pong, stream: frame.stream))
        case .pong:
            break
        case .httpResponse:
            let head = try JSONSerialization.jsonObject(with: frame.payload) as? [String: Any]
            requests[frame.stream]?.status = head?["status"] as? Int
        case .httpBody:
            requests[frame.stream]?.body.append(frame.payload)
        case .streamEnd:
            guard let request = requests[frame.stream] else { return }
            finishRequest(frame.stream, with: .success((request.status ?? 502, request.body)))
        case .streamAbort:
            let reason = (try? JSONSerialization.jsonObject(with: frame.payload) as? [String: Any])?["reason"] as? String ?? "aborted"
            finishRequest(frame.stream, with: .failure(RelayError.streamAborted(reason)))
            sockets.removeValue(forKey: frame.stream)?.continuation.finish(throwing: RelayError.streamAborted(reason))
        case .wsOpened:
            break
        case .wsText:
            guard var socket = sockets[frame.stream] else { return }
            socket.fragments.append(frame.payload)
            if frame.hasMore {
                guard socket.fragments.count <= 16 * 1024 * 1024 else { throw RelayError.protocolViolation("message too large") }
                sockets[frame.stream] = socket
                return
            }
            sockets[frame.stream]?.fragments = Data()
            socket.continuation.yield(String(decoding: socket.fragments, as: UTF8.self))
        case .wsClose:
            sockets.removeValue(forKey: frame.stream)?.continuation.finish()
        case .wsBinary, .httpRequest, .wsOpen, .deliveryAck:
            // Never sent to a client that negotiated neither binary sockets nor flow control.
            throw RelayError.protocolViolation("unexpected \(frame.type) frame")
        }
    }

    private func finishRequest(_ stream: UInt32, with result: Result<(status: Int, body: Data), Error>) {
        requests.removeValue(forKey: stream)?.continuation.resume(with: result)
    }

    /// Ends the channel: every open request and socket fails with `error`.
    private func fail(with error: Error) {
        guard failure == nil else { return }
        failure = error
        reader?.cancel()
        keepalive?.cancel()
        for stream in Array(requests.keys) { finishRequest(stream, with: .failure(error)) }
        for (_, socket) in sockets { socket.continuation.finish(throwing: error) }
        sockets = [:]
        socket?.cancel(with: .normalClosure, reason: nil)
    }

    // MARK: Helpers

    private static func json(_ text: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }

    /// `{"type":"relay-retire","code":…}`: the relay asking this peer to close.
    static func retire(from text: String) -> RelayError? {
        guard let object = json(text), object["type"] as? String == "relay-retire", let code = object["code"] as? Int else { return nil }
        return .closed(code: code, reason: object["reason"] as? String ?? "")
    }

    private static func closeError(of socket: URLSessionWebSocketTask) -> RelayError? {
        let code = socket.closeCode.rawValue
        guard code != URLSessionWebSocketTask.CloseCode.invalid.rawValue else { return nil }
        let reason = socket.closeReason.map { String(decoding: $0, as: UTF8.self) } ?? ""
        return .closed(code: code, reason: reason)
    }
}

extension Data {
    init?(base64URL text: String) {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }

    var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

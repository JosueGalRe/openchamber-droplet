import CryptoKit
import Foundation
import Testing
@testable import Openchamber

/// Generated with OpenChamber's own host-side relay code
/// (packages/web/server/lib/relay/e2ee.js and tunnel-codec.js), so these
/// tests fail if the Swift port drifts from the wire format by one byte.
private enum Vectors {
    static let clientD = "GxHej5KGuFBT4iJSI-vIknshOSY8d6IAGb6JdtoQWtA"
    static let hostX = "05NPClQHxhhgK1OW8-nGzH7aAZwKDj67qfiHfpaDKj0"
    static let hostY = "AMSZL2D9Zl81UQoLaPK4qhWQZ6iXexoerTcdnZdOlXc"
    static let nonce = "YUdNaurIgn9jKktMPiVfBw"
    static let responseFrame = "03000000017b22737461747573223a3230302c2268656164657273223a7b22636f6e74656e742d74797065223a226170706c69636174696f6e2f6a736f6e227d7d"
    static let hostFrame = "010ebec5c200000000000000019116925ebbfcdb0047704b29a0fec52fcefec491a490a50757ffa17b7b03586c067ee7037e20064af354dd0c625d55fe86a48679e4f95d722ebae6ebf1db8e1795c3f1fdb875a05934c049ac3fd41295a4"
    static let clientFrame = "015c7622880000000000000001ac7569a113e0325941b72d6b343a0724534610ee8f4c76f6461a4e3031dd"
    static let fragmentFrame = "88010203047b2274797065223a227265616479227d"
}

private func bytes(_ hex: String) -> Data {
    Data(stride(from: 0, to: hex.count, by: 2).map {
        let start = hex.index(hex.startIndex, offsetBy: $0)
        return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
    })
}

private func vectorKeys() throws -> (clientToHost: SymmetricKey, hostToClient: SymmetricKey) {
    let client = try P256.KeyAgreement.PrivateKey(rawRepresentation: Data(base64URL: Vectors.clientD)!)
    let host = try RelayCrypto.publicKey(x: Data(base64URL: Vectors.hostX)!, y: Data(base64URL: Vectors.hostY)!)
    return try RelayCrypto.sessionKeys(own: client, peer: host, nonce: Data(base64URL: Vectors.nonce)!)
}

@Test func theClientDerivesTheKeysOpenChambersHostDerives() throws {
    let keys = try vectorKeys()

    var fromHost = FrameOpener(key: keys.hostToClient)
    #expect(try fromHost.open(bytes(Vectors.hostFrame)) == bytes(Vectors.responseFrame))

    // The host's client-to-host key opens what the client sealed with its own.
    var toHost = FrameOpener(key: keys.clientToHost)
    #expect(try toHost.open(bytes(Vectors.clientFrame)) == Data("client to host".utf8))
}

@Test func sealedFramesOpenAndNeverReplay() throws {
    let key = try vectorKeys().clientToHost
    var sealer = FrameSealer(key: key)
    var opener = FrameOpener(key: key)
    let first = try sealer.seal(Data("one".utf8))
    let second = try sealer.seal(Data("two".utf8))

    #expect(first.count == 1 + 12 + 3 + 16)
    #expect(try opener.open(first) == Data("one".utf8))
    #expect(try opener.open(second) == Data("two".utf8))
    #expect(throws: RelayError.self) { try opener.open(first) }
}

@Test func tunnelFramesMatchTheHostCodec() throws {
    let fragment = try TunnelFrame(decoding: bytes(Vectors.fragmentFrame))
    #expect(fragment == TunnelFrame(.wsText, stream: 0x0102_0304, payload: Data(#"{"type":"ready"}"#.utf8), hasMore: true))
    #expect(fragment.encoded == bytes(Vectors.fragmentFrame))

    let response = try TunnelFrame(decoding: bytes(Vectors.responseFrame))
    #expect(response.type == .httpResponse)
    #expect(response.stream == 1)

    #expect(throws: RelayError.self) { try TunnelFrame(decoding: Data([0x7f, 0, 0, 0, 1])) }
}

@Test func largePayloadsSplitAtTheFrameBudget() {
    let payload = Data(repeating: 7, count: TunnelFrame.maxPayload * 2 + 10)
    #expect(TunnelFrame.chunks(of: payload).map(\.count) == [TunnelFrame.maxPayload, TunnelFrame.maxPayload, 10])
    #expect(TunnelFrame.chunks(of: Data()).map(\.count) == [0])
}

@Test func aRetireFrameIsARelayClose() {
    let retire = RelayTunnel.retire(from: #"{"type":"relay-retire","code":4002,"reason":"replaced"}"#)
    #expect(retire == .closed(code: 4002, reason: "replaced"))
    #expect(retire?.isDuplicateClient == true)
    #expect(RelayTunnel.retire(from: #"{"t":"ready","v":1}"#) == nil)
}

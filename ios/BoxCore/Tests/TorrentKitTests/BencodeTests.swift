import XCTest
@testable import TorrentKit

final class BencodeTests: XCTestCase {
    func testRoundTrip() throws {
        let v: BValue = .dict(["b": .int(-3), "a": .list([.str("x"), .int(0)])])
        let enc = BEncoder.encode(v)
        XCTAssertEqual(String(decoding: enc, as: UTF8.self), "d1:al1:xi0ee1:bi-3ee")
        XCTAssertEqual(try BDecoder.decode(enc), v)
    }

    func testMagnet() throws {
        let m = try MagnetLink("magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&dn=Hello+World&tr=udp%3A%2F%2Ft.example%3A80%2Fannounce&x.pe=10.0.0.1:6881")
        XCTAssertEqual(m.infoHash.hexString, "0123456789abcdef0123456789abcdef01234567")
        XCTAssertEqual(m.displayName, "Hello World")
        XCTAssertEqual(m.trackers, ["udp://t.example:80/announce"])
        XCTAssertEqual(m.peers, [PeerAddress(host: "10.0.0.1", port: 6881)])
        let b32 = try MagnetLink("magnet:?xt=urn:btih:AERUKZ4JVPG66AJDIVTYTK6N54ASGRLH")
        XCTAssertEqual(b32.infoHash.hexString, "0123456789abcdef0123456789abcdef01234567")
    }

    func testBitfield() {
        var b = Bitfield(count: 10)
        b[0] = true; b[9] = true
        XCTAssertEqual(b.bytes, [0x80, 0x40])
        XCTAssertEqual(b.setCount, 2)
        let c = Bitfield(count: 10, data: Data([0xff, 0xff]))
        XCTAssertEqual(c.setCount, 10)
    }

    func testParseRange() {
        XCTAssertEqual(StreamHandlerTestHooks.parseRange("bytes=0-99", length: 1000), 0...99)
        XCTAssertEqual(StreamHandlerTestHooks.parseRange("bytes=-100", length: 1000), 900...999)
        XCTAssertEqual(StreamHandlerTestHooks.parseRange("bytes=900-", length: 1000), 900...999)
        XCTAssertEqual(StreamHandlerTestHooks.parseRange("bytes=-100", length: 50), 0...49)
        XCTAssertNil(StreamHandlerTestHooks.parseRange("bytes=-100", length: 0))
        XCTAssertNil(StreamHandlerTestHooks.parseRange("bytes=0-", length: 0))
        XCTAssertNil(StreamHandlerTestHooks.parseRange("bytes=2000-", length: 1000))
    }
}

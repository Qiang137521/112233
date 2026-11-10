import Foundation
import NIOCore
import NIOPosix
import NIOConcurrencyHelpers

/// Shared event loop group for all sockets of the engine.
enum Net {
    static let group: MultiThreadedEventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 2)

    static func resolve(host: String, port: Int) async throws -> SocketAddress {
        // getaddrinfo is blocking, keep it off the cooperative pool.
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                do { cont.resume(returning: try SocketAddress.makeAddressResolvingHost(host, port: port)) }
                catch { cont.resume(throwing: error) }
            }
        }
    }
}

struct TimeoutError: Error {}

// MARK: - UDP request/response endpoint

/// A UDP socket that matches responses to outstanding requests by a key
/// (the transaction id), used by UDP trackers (BEP 15) and the DHT (BEP 5).
final class UDPEndpoint: @unchecked Sendable {
    typealias KeyExtractor = @Sendable ([UInt8]) -> Data?

    private let channel: Channel
    private let keyOf: KeyExtractor
    private let lock = NIOLock()
    private var pending: [Data: CheckedContinuation<([UInt8], SocketAddress), Error>] = [:]

    private init(channel: Channel, keyOf: @escaping KeyExtractor) {
        self.channel = channel
        self.keyOf = keyOf
    }

    static func open(keyOf: @escaping KeyExtractor) async throws -> UDPEndpoint {
        let box = NIOLockedValueBox<UDPEndpoint?>(nil)
        let channel = try await DatagramBootstrap(group: Net.group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { ch in
                ch.pipeline.addHandler(InboundDatagramHandler { env in
                    box.withLockedValue { $0 }?.receive(env)
                })
            }
            .bind(host: "0.0.0.0", port: 0).get()
        let ep = UDPEndpoint(channel: channel, keyOf: keyOf)
        box.withLockedValue { $0 = ep }
        return ep
    }

    private func receive(_ env: AddressedEnvelope<ByteBuffer>) {
        var buf = env.data
        guard let bytes = buf.readBytes(length: buf.readableBytes), let key = keyOf(bytes) else { return }
        let cont = lock.withLock { pending.removeValue(forKey: key) }
        cont?.resume(returning: (bytes, env.remoteAddress))
    }

    func request(_ payload: [UInt8], key: Data, to address: SocketAddress,
                 timeout: TimeAmount) async throws -> ([UInt8], SocketAddress) {
        try await withCheckedThrowingContinuation { cont in
            lock.withLock { pending[key] = cont }
            var buf = channel.allocator.buffer(capacity: payload.count)
            buf.writeBytes(payload)
            channel.writeAndFlush(AddressedEnvelope(remoteAddress: address, data: buf)).whenFailure { [weak self] err in
                self?.fail(key: key, error: err)
            }
            channel.eventLoop.scheduleTask(in: timeout) { [weak self] in
                self?.fail(key: key, error: TimeoutError())
            }
        }
    }

    private func fail(key: Data, error: Error) {
        let cont = lock.withLock { pending.removeValue(forKey: key) }
        cont?.resume(throwing: error)
    }

    func close() {
        channel.close(promise: nil)
        let all = lock.withLock { () -> [CheckedContinuation<([UInt8], SocketAddress), Error>] in
            let v = Array(pending.values); pending.removeAll(); return v
        }
        for c in all { c.resume(throwing: CancellationError()) }
    }
}

private final class InboundDatagramHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>
    let onReceive: (AddressedEnvelope<ByteBuffer>) -> Void
    init(_ onReceive: @escaping (AddressedEnvelope<ByteBuffer>) -> Void) { self.onReceive = onReceive }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        onReceive(unwrapInboundIn(data))
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        // ICMP port unreachable etc. are reported here; the request will time out.
    }
}

// MARK: - Peer wire framing

enum PeerFrame {
    case handshake(reserved: [UInt8], infoHash: Data, peerId: Data)
    case keepAlive
    case message(id: UInt8, payload: [UInt8])
}

/// Decodes the 68-byte handshake followed by length-prefixed messages.
struct PeerFrameDecoder: ByteToMessageDecoder {
    typealias InboundOut = PeerFrame
    private var handshakeDone = false
    static let maxMessage = 4 * 1024 * 1024

    mutating func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        if !handshakeDone {
            guard buffer.readableBytes >= 68 else { return .needMoreData }
            guard let bytes = buffer.readBytes(length: 68) else { return .needMoreData }
            guard bytes[0] == 19, Array(bytes[1..<20]) == Array("BitTorrent protocol".utf8) else {
                throw PeerError.protocolViolation("bad handshake")
            }
            handshakeDone = true
            context.fireChannelRead(wrapInboundOut(.handshake(reserved: Array(bytes[20..<28]),
                                                              infoHash: Data(bytes[28..<48]),
                                                              peerId: Data(bytes[48..<68]))))
            return .continue
        }
        guard let len = buffer.getInteger(at: buffer.readerIndex, as: UInt32.self) else { return .needMoreData }
        guard len <= PeerFrameDecoder.maxMessage else { throw PeerError.protocolViolation("message too large") }
        guard buffer.readableBytes >= 4 + Int(len) else { return .needMoreData }
        buffer.moveReaderIndex(forwardBy: 4)
        if len == 0 {
            context.fireChannelRead(wrapInboundOut(.keepAlive))
            return .continue
        }
        let id: UInt8 = buffer.readInteger()!
        let payload = buffer.readBytes(length: Int(len) - 1) ?? []
        context.fireChannelRead(wrapInboundOut(.message(id: id, payload: payload)))
        return .continue
    }

    mutating func decodeLast(context: ChannelHandlerContext, buffer: inout ByteBuffer, seenEOF: Bool) throws -> DecodingState {
        .needMoreData
    }
}

enum PeerError: Error {
    case protocolViolation(String)
    case closed
}

/// Bridges channel reads into an AsyncThrowingStream.
private final class FrameBridge: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = PeerFrame
    let continuation: AsyncThrowingStream<PeerFrame, Error>.Continuation
    init(_ c: AsyncThrowingStream<PeerFrame, Error>.Continuation) { continuation = c }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        continuation.yield(unwrapInboundIn(data))
    }
    func channelInactive(context: ChannelHandlerContext) {
        continuation.finish()
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        continuation.finish(throwing: error)
        context.close(promise: nil)
    }
}

/// One TCP connection to a peer. Writes are thread-safe and fire-and-forget.
final class PeerConnection: @unchecked Sendable {
    let address: PeerAddress
    let frames: AsyncThrowingStream<PeerFrame, Error>
    private let channel: Channel

    private init(address: PeerAddress, channel: Channel, frames: AsyncThrowingStream<PeerFrame, Error>) {
        self.address = address
        self.channel = channel
        self.frames = frames
    }

    static func connect(to address: PeerAddress, timeout: TimeAmount = .seconds(8)) async throws -> PeerConnection {
        var cont: AsyncThrowingStream<PeerFrame, Error>.Continuation!
        let stream = AsyncThrowingStream<PeerFrame, Error>(bufferingPolicy: .unbounded) { cont = $0 }
        let c = cont!
        let channel = try await ClientBootstrap(group: Net.group)
            .connectTimeout(timeout)
            .channelInitializer { ch in
                ch.eventLoop.makeCompletedFuture {
                    try ch.pipeline.syncOperations.addHandlers([ByteToMessageHandler(PeerFrameDecoder()), FrameBridge(c)])
                }
            }
            .connect(host: address.host, port: address.port).get()
        return PeerConnection(address: address, channel: channel, frames: stream)
    }

    func send(_ bytes: [UInt8]) {
        var buf = channel.allocator.buffer(capacity: bytes.count)
        buf.writeBytes(bytes)
        channel.writeAndFlush(buf, promise: nil)
    }

    /// Bytes waiting in the outbound buffer are not tracked; writability is a good-enough backpressure hint.
    var isWritable: Bool { channel.isWritable }

    func close() { channel.close(promise: nil) }
}

// MARK: - Wire message builders

enum Wire {
    static let choke: UInt8 = 0, unchoke: UInt8 = 1, interested: UInt8 = 2, notInterested: UInt8 = 3
    static let have: UInt8 = 4, bitfield: UInt8 = 5, request: UInt8 = 6, piece: UInt8 = 7, cancel: UInt8 = 8
    static let port: UInt8 = 9, haveAll: UInt8 = 14, haveNone: UInt8 = 15, reject: UInt8 = 16, extended: UInt8 = 20

    static func handshake(infoHash: Data, peerId: Data) -> [UInt8] {
        var out: [UInt8] = [19]
        out += Array("BitTorrent protocol".utf8)
        var reserved = [UInt8](repeating: 0, count: 8)
        reserved[5] |= 0x10 // BEP 10 extension protocol
        out += reserved
        out += Array(infoHash)
        out += Array(peerId)
        return out
    }

    static func message(_ id: UInt8, _ payload: [UInt8] = []) -> [UInt8] {
        var out = u32(UInt32(payload.count + 1))
        out.append(id)
        out += payload
        return out
    }

    static func request(index: Int, begin: Int, length: Int, cancel: Bool = false) -> [UInt8] {
        message(cancel ? Wire.cancel : Wire.request, u32(UInt32(index)) + u32(UInt32(begin)) + u32(UInt32(length)))
    }

    static func extended(_ extId: UInt8, _ dict: BValue, trailing: Data = Data()) -> [UInt8] {
        message(Wire.extended, [extId] + Array(BEncoder.encode(dict)) + Array(trailing))
    }

    static func u32(_ v: UInt32) -> [UInt8] {
        [UInt8(v >> 24 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)]
    }

    static func readU32(_ b: [UInt8], _ at: Int) -> Int {
        guard at + 4 <= b.count else { return 0 }
        return Int(b[at]) << 24 | Int(b[at + 1]) << 16 | Int(b[at + 2]) << 8 | Int(b[at + 3])
    }
}

func randomBytes(_ n: Int) -> [UInt8] {
    (0..<n).map { _ in UInt8.random(in: 0...255) }
}

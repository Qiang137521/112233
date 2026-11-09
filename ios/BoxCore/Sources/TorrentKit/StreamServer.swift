import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1

/// A tiny HTTP server on 127.0.0.1 that serves torrent files with Range support,
/// waiting for pieces as the player asks for them ("play while downloading").
final class StreamServer: @unchecked Sendable {
    private weak var engine: TorrentEngine?
    private var channel: Channel?
    private(set) var port: Int = 0

    init(engine: TorrentEngine) {
        self.engine = engine
    }

    func start() async throws {
        let engineRef = engine
        let bootstrap = ServerBootstrap(group: Net.group)
            .serverChannelOption(ChannelOptions.backlog, value: 64)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.tcpOption(.tcp_nodelay), value: 1)
            .childChannelInitializer { ch in
                ch.pipeline.configureHTTPServerPipeline(withErrorHandling: true).flatMap {
                    ch.pipeline.addHandler(StreamHandler(engine: engineRef))
                }
            }
        let ch = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        channel = ch
        port = ch.localAddress?.port ?? 0
    }

    func stop() { channel?.close(promise: nil) }
}

private final class StreamHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    weak var engine: TorrentEngine?
    private var head: HTTPRequestHead?
    private var task: Task<Void, Never>?

    init(engine: TorrentEngine?) { self.engine = engine }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let h): head = h
        case .body: break
        case .end:
            guard let h = head, task == nil else { return }
            let channel = context.channel
            let engine = engine
            task = Task { await StreamHandler.serve(h, channel: channel, engine: engine) }
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        task?.cancel()
        context.fireChannelInactive()
    }

    static func mimeType(for name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "mp4", "m4v": return "video/mp4"
        case "mov": return "video/quicktime"
        case "mkv": return "video/x-matroska"
        case "webm": return "video/webm"
        case "avi": return "video/x-msvideo"
        case "ts", "m2ts": return "video/mp2t"
        case "mp3": return "audio/mpeg"
        case "m4a", "aac": return "audio/mp4"
        case "flac": return "audio/flac"
        case "wav": return "audio/wav"
        default: return "application/octet-stream"
        }
    }

    private static func respond(_ channel: Channel, status: HTTPResponseStatus) {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Length", value: "0")
        headers.add(name: "Connection", value: "close")
        channel.write(HTTPServerResponsePart.head(HTTPResponseHead(version: .http1_1, status: status, headers: headers)), promise: nil)
        channel.writeAndFlush(HTTPServerResponsePart.end(nil)).whenComplete { _ in channel.close(promise: nil) }
    }

    /// Parses "bytes=a-b", "bytes=a-" and "bytes=-n".
    static func parseRange(_ header: String?, length: Int64) -> ClosedRange<Int64>? {
        // An empty file has no satisfiable byte range (and 0...-1 would trap).
        guard length > 0, let header, header.hasPrefix("bytes=") else { return nil }
        let spec = header.dropFirst(6).split(separator: ",").first.map(String.init) ?? ""
        let parts = spec.split(separator: "-", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2 else { return nil }
        if parts[0].isEmpty, let n = Int64(parts[1]), n > 0 {
            return max(0, length - n)...(length - 1)
        }
        guard let start = Int64(parts[0]), start < length else { return nil }
        let end = Int64(parts[1]).map { min($0, length - 1) } ?? (length - 1)
        guard end >= start else { return nil }
        return start...end
    }

    static func serve(_ head: HTTPRequestHead, channel: Channel, engine: TorrentEngine?) async {
        let comps = head.uri.split(separator: "?").first?.split(separator: "/").map(String.init) ?? []
        guard comps.count >= 2, let engine, let fileIndex = Int(comps[1]),
              let session = await engine.session(comps[0]), let entry = await session.fileInfo(fileIndex) else {
            respond(channel, status: .notFound); return
        }
        let length = entry.length
        var status: HTTPResponseStatus = .ok
        var range: ClosedRange<Int64> = 0...max(length - 1, 0)
        if let r = parseRange(head.headers.first(name: "Range"), length: length) {
            range = r
            status = .partialContent
        } else if head.headers.first(name: "Range") != nil && length > 0 {
            respond(channel, status: .rangeNotSatisfiable); return
        }

        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: mimeType(for: entry.name))
        headers.add(name: "Accept-Ranges", value: "bytes")
        headers.add(name: "Connection", value: "close")
        let bodyLength = length == 0 ? 0 : range.upperBound - range.lowerBound + 1
        headers.add(name: "Content-Length", value: "\(bodyLength)")
        if status == .partialContent {
            headers.add(name: "Content-Range", value: "bytes \(range.lowerBound)-\(range.upperBound)/\(length)")
        }
        do {
            try await channel.writeAndFlush(HTTPServerResponsePart.head(HTTPResponseHead(version: .http1_1, status: status, headers: headers))).get()
            if head.method != .HEAD && bodyLength > 0 {
                let streamId = UUID()
                defer { Task { await session.endStream(streamId) } }
                var offset = range.lowerBound
                while offset <= range.upperBound {
                    try Task.checkCancellation()
                    let want = Int(min(256 * 1024, range.upperBound - offset + 1))
                    let data = try await session.readForStream(file: fileIndex, offset: offset, maxLength: want, stream: streamId)
                    if data.isEmpty { break }
                    var buf = channel.allocator.buffer(capacity: data.count)
                    buf.writeBytes(data)
                    try await channel.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(buf))).get()
                    offset += Int64(data.count)
                }
            }
            try await channel.writeAndFlush(HTTPServerResponsePart.end(nil)).get()
        } catch {}
        channel.close(promise: nil)
    }
}

/// Exposes pure helpers of the private HTTP handler to unit tests.
enum StreamHandlerTestHooks {
    static func parseRange(_ header: String?, length: Int64) -> ClosedRange<Int64>? {
        StreamHandler.parseRange(header, length: length)
    }
}

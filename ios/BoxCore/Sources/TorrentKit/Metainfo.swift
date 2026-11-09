import Foundation
import Crypto

public enum TorrentError: Error, LocalizedError {
    case invalidTorrent(String)
    case invalidMagnet
    case notFound
    case cancelled
    case io(String)

    public var errorDescription: String? {
        switch self {
        case .invalidTorrent(let s): return "无效的种子文件: \(s)"
        case .invalidMagnet: return "无效的磁力链接"
        case .notFound: return "未找到任务"
        case .cancelled: return "已取消"
        case .io(let s): return "读写错误: \(s)"
        }
    }
}

public struct TorrentFileEntry: Sendable, Codable, Hashable {
    public let path: [String]
    public let length: Int64
    /// Offset of the file inside the torrent's contiguous byte space.
    public let offset: Int64

    public var name: String { path.last ?? "" }
    public var relativePath: String { path.joined(separator: "/") }
}

/// The parsed `info` dictionary of a torrent (BEP 3, v1).
public struct TorrentInfo: Sendable {
    public let infoHash: Data
    public let name: String
    public let pieceLength: Int
    public let pieceHashes: [Data]
    public let files: [TorrentFileEntry]
    public let totalLength: Int64
    /// True when the torrent describes a directory (multi-file mode).
    public let isMultiFile: Bool
    /// The raw bencoded info dictionary (used for metadata exchange and to persist magnets).
    public let infoDictData: Data

    public var pieceCount: Int { pieceHashes.count }
    public var infoHashHex: String { infoHash.hexString }

    public func length(ofPiece index: Int) -> Int {
        if index == pieceCount - 1 {
            let rem = Int(totalLength - Int64(pieceLength) * Int64(pieceCount - 1))
            return rem
        }
        return pieceLength
    }

    public init(infoDict data: Data) throws {
        let value: BValue
        do { value = try BDecoder.decode(data) } catch { throw TorrentError.invalidTorrent("\(error)") }
        guard case .dict = value else { throw TorrentError.invalidTorrent("info is not a dictionary") }
        self.infoDictData = data
        self.infoHash = Data(Insecure.SHA1.hash(data: data))

        let rawName = value["name.utf-8"]?.string ?? value["name"]?.string ?? "torrent"
        let name = TorrentInfo.sanitize(rawName)
        self.name = name.isEmpty ? "torrent" : name

        guard let pl = value["piece length"]?.int, pl > 0, pl <= 256 * 1024 * 1024 else {
            throw TorrentError.invalidTorrent("piece length")
        }
        self.pieceLength = Int(pl)

        guard let pieces = value["pieces"]?.data, pieces.count % 20 == 0, !pieces.isEmpty else {
            throw TorrentError.invalidTorrent("pieces")
        }
        var hashes: [Data] = []
        hashes.reserveCapacity(pieces.count / 20)
        var i = pieces.startIndex
        while i < pieces.endIndex {
            hashes.append(Data(pieces[i..<(i + 20)]))
            i += 20
        }
        self.pieceHashes = hashes

        var entries: [TorrentFileEntry] = []
        var offset: Int64 = 0
        if let files = value["files"]?.list {
            isMultiFile = true
            for f in files {
                guard let len = f["length"]?.int, len >= 0 else { throw TorrentError.invalidTorrent("file length") }
                let comps = (f["path.utf-8"]?.list ?? f["path"]?.list ?? []).compactMap { $0.string }
                    .map(TorrentInfo.sanitize).filter { !$0.isEmpty }
                guard !comps.isEmpty else { throw TorrentError.invalidTorrent("file path") }
                // BEP 47 padding files are kept so that offsets stay correct; they are hidden in the UI.
                entries.append(TorrentFileEntry(path: comps, length: len, offset: offset))
                offset += len
            }
        } else if let len = value["length"]?.int, len >= 0 {
            isMultiFile = false
            entries.append(TorrentFileEntry(path: [self.name], length: len, offset: 0))
            offset = len
        } else {
            throw TorrentError.invalidTorrent("no files")
        }
        self.files = entries
        self.totalLength = offset

        let expectedPieces = Int((offset + pl - 1) / pl)
        guard expectedPieces == hashes.count else {
            throw TorrentError.invalidTorrent("piece count mismatch (\(expectedPieces) vs \(hashes.count))")
        }
    }

    /// Removes characters that would let a torrent escape the download directory.
    static func sanitize(_ s: String) -> String {
        var r = s.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: "\0", with: "")
        if r == "." || r == ".." { r = "_" }
        return r.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Index range of pieces touched by a file.
    public func pieceRange(forFile index: Int) -> ClosedRange<Int>? {
        let f = files[index]
        guard f.length > 0 else { return nil }
        let first = Int(f.offset / Int64(pieceLength))
        let last = Int((f.offset + f.length - 1) / Int64(pieceLength))
        return first...last
    }

    /// Whether the file is a BEP 47 padding file.
    public func isPadding(_ index: Int) -> Bool {
        let n = files[index].name
        return n.hasPrefix(".pad") || files[index].path.first == ".pad" || n.hasPrefix("_____padding_file")
    }
}

/// A parsed `.torrent` file.
public struct TorrentMetafile: Sendable {
    public let info: TorrentInfo
    public let trackers: [String]

    public init(data: Data) throws {
        var decoder = BDecoder(data)
        let root: BValue
        do { root = try decoder.next() } catch { throw TorrentError.invalidTorrent("\(error)") }
        guard let range = decoder.infoRange else { throw TorrentError.invalidTorrent("missing info") }
        let infoData = data.subdata(in: (data.startIndex + range.lowerBound)..<(data.startIndex + range.upperBound))
        self.info = try TorrentInfo(infoDict: infoData)

        var trackers: [String] = []
        if let tiers = root["announce-list"]?.list {
            for tier in tiers {
                for t in tier.list ?? [] { if let s = t.string { trackers.append(s) } }
            }
        }
        if let a = root["announce"]?.string { trackers.insert(a, at: 0) }
        var seen = Set<String>()
        self.trackers = trackers.filter { seen.insert($0).inserted }
    }

    /// Builds a minimal .torrent file around a raw info dictionary (used to persist magnets).
    public static func build(infoDict: Data, trackers: [String]) -> Data {
        var out = Data()
        out.append(UInt8(ascii: "d"))
        if let first = trackers.first {
            out.append(BEncoder.encode(.str("announce")))
            out.append(BEncoder.encode(.str(first)))
            out.append(BEncoder.encode(.str("announce-list")))
            out.append(BEncoder.encode(.list(trackers.map { .list([.str($0)]) })))
        }
        out.append(BEncoder.encode(.str("info")))
        out.append(infoDict)
        out.append(UInt8(ascii: "e"))
        return out
    }
}

public struct MagnetLink: Sendable {
    public let infoHash: Data
    public let displayName: String?
    public let trackers: [String]
    public let peers: [PeerAddress]

    public init(_ string: String) throws {
        let s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.lowercased().hasPrefix("magnet:"), let q = s.firstIndex(of: "?") else {
            // A bare 40-char hex hash is accepted too.
            if let h = Data(hexString: s), h.count == 20 {
                infoHash = h; displayName = nil; trackers = []; peers = []
                return
            }
            throw TorrentError.invalidMagnet
        }
        var hash: Data?
        var dn: String?
        var tr: [String] = []
        var pe: [PeerAddress] = []
        // Parsed by hand: URLComponents rejects many real-world magnets with unescaped characters.
        for pair in s[s.index(after: q)...].split(separator: "&") {
            guard let eq = pair.firstIndex(of: "=") else { continue }
            let rawKey = String(pair[..<eq])
            let rawValue = String(pair[pair.index(after: eq)...])
            let value = (rawValue.replacingOccurrences(of: "+", with: " ").removingPercentEncoding) ?? rawValue
            // Keys can be numbered ("tr.1") per some clients.
            let key = rawKey.lowercased().split(separator: ".").prefix(rawKey.lowercased().hasPrefix("x.") ? 2 : 1)
                .joined(separator: ".")
            switch key {
            case "xt":
                let lower = value.lowercased()
                if lower.hasPrefix("urn:btih:") {
                    let h = String(value.dropFirst(9))
                    if h.count == 40 { hash = Data(hexString: h) } else if h.count == 32 { hash = Base32.decode(h) }
                }
            case "dn": dn = value
            case "tr": tr.append(value)
            case "x.pe": if let p = PeerAddress(string: value) { pe.append(p) }
            default: break
            }
        }
        guard let h = hash, h.count == 20 else { throw TorrentError.invalidMagnet }
        infoHash = h
        displayName = dn
        trackers = tr
        peers = pe
    }
}

public struct PeerAddress: Hashable, Sendable, CustomStringConvertible {
    public let host: String
    public let port: Int

    public init(host: String, port: Int) {
        self.host = host
        self.port = port
    }

    /// Parses "host:port" or "[v6]:port".
    public init?(string: String) {
        if string.hasPrefix("["), let close = string.firstIndex(of: "]") {
            let host = String(string[string.index(after: string.startIndex)..<close])
            let rest = string[string.index(after: close)...]
            guard rest.hasPrefix(":"), let p = Int(rest.dropFirst()), p > 0, p < 65536 else { return nil }
            self.init(host: host, port: p)
        } else {
            guard let colon = string.lastIndex(of: ":"), let p = Int(string[string.index(after: colon)...]),
                  p > 0, p < 65536 else { return nil }
            self.init(host: String(string[..<colon]), port: p)
        }
    }

    public var description: String { host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)" }

    static func parseCompact(_ data: Data) -> [PeerAddress] {
        let b = [UInt8](data)
        var out: [PeerAddress] = []
        var i = 0
        while i + 6 <= b.count {
            let host = "\(b[i]).\(b[i + 1]).\(b[i + 2]).\(b[i + 3])"
            let port = Int(b[i + 4]) << 8 | Int(b[i + 5])
            if port > 0 { out.append(PeerAddress(host: host, port: port)) }
            i += 6
        }
        return out
    }

    static func parseCompact6(_ data: Data) -> [PeerAddress] {
        let b = [UInt8](data)
        var out: [PeerAddress] = []
        var i = 0
        while i + 18 <= b.count {
            var groups: [String] = []
            for g in 0..<8 { groups.append(String(Int(b[i + 2 * g]) << 8 | Int(b[i + 2 * g + 1]), radix: 16)) }
            let port = Int(b[i + 16]) << 8 | Int(b[i + 17])
            if port > 0 { out.append(PeerAddress(host: groups.joined(separator: ":"), port: port)) }
            i += 18
        }
        return out
    }
}

enum Base32 {
    static func decode(_ s: String) -> Data? {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var bits = 0
        var value = 0
        var out = Data()
        for ch in s.uppercased() {
            if ch == "=" { break }
            guard let idx = alphabet.firstIndex(of: ch) else { return nil }
            value = (value << 5) | idx
            bits += 5
            if bits >= 8 {
                out.append(UInt8((value >> (bits - 8)) & 0xff))
                bits -= 8
            }
        }
        return out
    }
}

extension Data {
    public var hexString: String { map { String(format: "%02x", $0) }.joined() }

    public init?(hexString: String) {
        let chars = Array(hexString.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var out = Data(capacity: chars.count / 2)
        func nib(_ c: UInt8) -> UInt8? {
            switch c {
            case 48...57: return c - 48
            case 65...70: return c - 55
            case 97...102: return c - 87
            default: return nil
            }
        }
        var i = 0
        while i < chars.count {
            guard let hi = nib(chars[i]), let lo = nib(chars[i + 1]) else { return nil }
            out.append(hi << 4 | lo)
            i += 2
        }
        self = out
    }
}

/// A fixed-size set of piece indices in BitTorrent wire format (MSB first).
public struct Bitfield: Sendable, Equatable {
    public private(set) var bytes: [UInt8]
    public let count: Int
    public private(set) var setCount: Int = 0

    public init(count: Int) {
        self.count = count
        self.bytes = [UInt8](repeating: 0, count: (count + 7) / 8)
    }

    public init(count: Int, data: Data) {
        self.init(count: count)
        let src = [UInt8](data)
        for i in 0..<Swift.min(src.count, bytes.count) { bytes[i] = src[i] }
        // Clear spare bits at the end.
        if count % 8 != 0, !bytes.isEmpty {
            bytes[bytes.count - 1] &= UInt8(truncatingIfNeeded: 0xff << (8 - count % 8))
        }
        setCount = bytes.reduce(0) { $0 + $1.nonzeroBitCount }
    }

    public subscript(i: Int) -> Bool {
        get { i >= 0 && i < count && bytes[i >> 3] & (0x80 >> UInt8(i & 7)) != 0 }
        set {
            guard i >= 0 && i < count else { return }
            let mask = UInt8(0x80) >> UInt8(i & 7)
            let was = bytes[i >> 3] & mask != 0
            if newValue && !was { bytes[i >> 3] |= mask; setCount += 1 }
            if !newValue && was { bytes[i >> 3] &= ~mask; setCount -= 1 }
        }
    }

    public var isComplete: Bool { setCount == count }
    public var data: Data { Data(bytes) }

    public mutating func setAll() {
        for i in 0..<count { self[i] = true }
    }
}

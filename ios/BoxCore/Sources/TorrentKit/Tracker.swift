import Foundation
import NIOCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct AnnounceRequest: Sendable {
    var infoHash: Data
    var peerId: Data
    var port: Int
    var uploaded: Int64
    var downloaded: Int64
    var left: Int64
    var event: Event

    enum Event: Int32, Sendable { case none = 0, completed = 1, started = 2, stopped = 3
        var name: String? {
            switch self { case .none: return nil; case .completed: return "completed"
            case .started: return "started"; case .stopped: return "stopped" }
        }
    }
}

struct AnnounceResponse: Sendable {
    var interval: Int
    var peers: [PeerAddress]
    var seeders: Int?
    var leechers: Int?
}

/// Default public trackers appended to every task to help magnets without trackers.
public let defaultPublicTrackers = [
    "udp://tracker.opentrackr.org:1337/announce",
    "udp://open.stealth.si:80/announce",
    "udp://tracker.torrent.eu.org:451/announce",
    "udp://exodus.desync.com:6969/announce",
    "udp://open.demonii.com:1337/announce",
    "udp://tracker.openbittorrent.com:6969/announce",
    "https://tracker.tamersunion.org:443/announce",
]

enum TrackerClient {
    static func announce(url: String, _ req: AnnounceRequest) async throws -> AnnounceResponse {
        let lower = url.lowercased()
        if lower.hasPrefix("udp://") { return try await udpAnnounce(url: url, req) }
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") { return try await httpAnnounce(url: url, req) }
        throw TorrentError.io("unsupported tracker \(url)")
    }

    // MARK: HTTP (BEP 3 / BEP 23)

    static func urlEncode(_ data: Data) -> String {
        var s = ""
        for b in data {
            let c = Character(UnicodeScalar(b))
            if (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5a) || (b >= 0x61 && b <= 0x7a) || "-._~".contains(c) {
                s.append(c)
            } else {
                s += String(format: "%%%02X", b)
            }
        }
        return s
    }

    static func httpAnnounce(url: String, _ req: AnnounceRequest) async throws -> AnnounceResponse {
        var q = "info_hash=\(urlEncode(req.infoHash))&peer_id=\(urlEncode(req.peerId))&port=\(req.port)"
        q += "&uploaded=\(req.uploaded)&downloaded=\(req.downloaded)&left=\(req.left)&compact=1&numwant=200"
        if let e = req.event.name { q += "&event=\(e)" }
        let full = url + (url.contains("?") ? "&" : "?") + q
        guard let u = URL(string: full) else { throw TorrentError.io("bad tracker url") }
        var request = URLRequest(url: u, timeoutInterval: 20)
        request.setValue("TorrentBox/1.0", forHTTPHeaderField: "User-Agent")
        let data: Data = try await withCheckedThrowingContinuation { cont in
            URLSession.shared.dataTask(with: request) { data, _, error in
                if let error { cont.resume(throwing: error) } else { cont.resume(returning: data ?? Data()) }
            }.resume()
        }
        let v = try BDecoder.decode(data)
        if let reason = v["failure reason"]?.string { throw TorrentError.io("tracker: \(reason)") }
        var peers: [PeerAddress] = []
        if let compact = v["peers"]?.data {
            peers = PeerAddress.parseCompact(compact)
        } else if let list = v["peers"]?.list {
            for p in list {
                if let ip = p["ip"]?.string, let port = p["port"]?.int { peers.append(PeerAddress(host: ip, port: Int(port))) }
            }
        }
        if let p6 = v["peers6"]?.data { peers += PeerAddress.parseCompact6(p6) }
        return AnnounceResponse(interval: Int(v["interval"]?.int ?? 1800), peers: peers,
                                seeders: v["complete"]?.int.map(Int.init), leechers: v["incomplete"]?.int.map(Int.init))
    }

    // MARK: UDP (BEP 15)

    static func udpAnnounce(url: String, _ req: AnnounceRequest) async throws -> AnnounceResponse {
        guard let comps = URLComponents(string: url), let host = comps.host, let port = comps.port else {
            throw TorrentError.io("bad udp tracker url")
        }
        let address = try await Net.resolve(host: host, port: port)
        let ep = try await UDPEndpoint.open { bytes in bytes.count >= 8 ? Data(bytes[4..<8]) : nil }
        defer { ep.close() }

        func tid() -> [UInt8] { randomBytes(4) }

        // Connect
        var connectionId: [UInt8] = []
        var attempt = 0
        while connectionId.isEmpty {
            let t = tid()
            var pkt: [UInt8] = [0x00, 0x00, 0x04, 0x17, 0x27, 0x10, 0x19, 0x80] // protocol id 0x41727101980
            pkt += Wire.u32(0) + t
            do {
                let (resp, _) = try await ep.request(pkt, key: Data(t), to: address, timeout: .seconds(Int64(5 << attempt)))
                guard resp.count >= 16, Wire.readU32(resp, 0) == 0 else { throw TorrentError.io("udp connect failed") }
                connectionId = Array(resp[8..<16])
            } catch is TimeoutError {
                attempt += 1
                if attempt >= 3 { throw TorrentError.io("udp tracker timeout") }
            }
        }

        // Announce
        let t = tid()
        var pkt = connectionId + Wire.u32(1) + t
        pkt += Array(req.infoHash) + Array(req.peerId)
        pkt += u64(req.downloaded) + u64(req.left) + u64(req.uploaded)
        pkt += Wire.u32(UInt32(req.event.rawValue)) + Wire.u32(0) + randomBytes(4) + Wire.u32(UInt32(bitPattern: -1))
        pkt += [UInt8(req.port >> 8 & 0xff), UInt8(req.port & 0xff)]
        let (resp, _) = try await ep.request(pkt, key: Data(t), to: address, timeout: .seconds(10))
        let action = Wire.readU32(resp, 0)
        if action == 3 {
            throw TorrentError.io("tracker: " + (String(bytes: resp.dropFirst(8), encoding: .utf8) ?? "error"))
        }
        guard action == 1, resp.count >= 20 else { throw TorrentError.io("udp announce failed") }
        let peers = PeerAddress.parseCompact(Data(resp[20...]))
        return AnnounceResponse(interval: Wire.readU32(resp, 8), peers: peers,
                                seeders: Wire.readU32(resp, 16), leechers: Wire.readU32(resp, 12))
    }

    private static func u64(_ v: Int64) -> [UInt8] {
        let u = UInt64(bitPattern: v)
        return (0..<8).map { UInt8(u >> (56 - 8 * UInt64($0)) & 0xff) }
    }
}

import Foundation
import NIOCore

/// A minimal Mainline DHT (BEP 5) client that can look up peers for an info hash.
/// It only issues queries (no routing table is served), which is enough for magnets
/// that carry no trackers.
actor DHTClient {
    static let bootstrapNodes: [(String, Int)] = [
        ("router.bittorrent.com", 6881),
        ("router.utorrent.com", 6881),
        ("dht.transmissionbt.com", 6881),
        ("dht.libtorrent.org", 25401),
    ]

    private let nodeId = Data(randomBytes(20))
    private var endpoint: UDPEndpoint?
    /// Nodes that answered recently; reused to speed up later lookups.
    private var goodNodes: [Data: SocketAddress] = [:]
    private var nextTid: UInt16 = 0

    static let shared = DHTClient()

    private func ensureEndpoint() async throws -> UDPEndpoint {
        if let e = endpoint { return e }
        let e = try await UDPEndpoint.open { bytes in
            guard let v = try? BDecoder.decode(Data(bytes)), let t = v["t"]?.data else { return nil }
            return t
        }
        endpoint = e
        return e
    }

    private func newTid() -> Data {
        nextTid &+= 1
        return Data([UInt8(nextTid >> 8), UInt8(nextTid & 0xff)])
    }

    private struct Node: Hashable { let id: Data; let address: SocketAddress
        func hash(into h: inout Hasher) { h.combine(id) }
        static func == (a: Node, b: Node) -> Bool { a.id == b.id }
    }

    private static func distance(_ a: Data, _ b: Data) -> [UInt8] {
        zip(a, b).map { $0 ^ $1 }
    }

    /// Runs an iterative get_peers lookup and reports peers as they are found.
    func lookup(infoHash: Data, maxQueries: Int = 300,
                onPeers: @escaping @Sendable ([PeerAddress]) async -> Void) async {
        guard let ep = try? await ensureEndpoint() else { return }

        var candidates: [Node] = goodNodes.map { Node(id: $0.key, address: $0.value) }
        if candidates.count < 8 {
            for (host, port) in DHTClient.bootstrapNodes {
                if let addr = try? await Net.resolve(host: host, port: port) {
                    candidates.append(Node(id: Data(randomBytes(20)), address: addr))
                }
            }
        }
        var queried = Set<String>()
        var found = Set<PeerAddress>()
        var queries = 0
        let alpha = 8

        while queries < maxQueries, !Task.isCancelled {
            candidates.sort { DHTClient.distance($0.id, infoHash).lexicographicallyPrecedes(DHTClient.distance($1.id, infoHash)) }
            if candidates.count > 500 { candidates.removeLast(candidates.count - 500) }
            let batch = Array(candidates.filter { !queried.contains("\($0.address)") }.prefix(alpha))
            if batch.isEmpty { break }
            for n in batch { queried.insert("\(n.address)") }
            queries += batch.count

            let myId = nodeId
            let results: [(Node, BValue?)] = await withTaskGroup(of: (Node, BValue?).self) { group in
                for n in batch {
                    let tid = newTid()
                    let q: BValue = .dict([
                        "t": .bytes(tid), "y": .str("q"), "q": .str("get_peers"),
                        "a": .dict(["id": .bytes(myId), "info_hash": .bytes(infoHash)]),
                    ])
                    let pkt = Array(BEncoder.encode(q))
                    group.addTask {
                        guard let (resp, _) = try? await ep.request(pkt, key: tid, to: n.address, timeout: .seconds(4)),
                              let v = try? BDecoder.decode(Data(resp)) else { return (n, nil) }
                        return (n, v)
                    }
                }
                var out: [(Node, BValue?)] = []
                for await r in group { out.append(r) }
                return out
            }

            var newPeers: [PeerAddress] = []
            for (node, resp) in results {
                guard let r = resp?["r"] else { continue }
                if let id = r["id"]?.data, id.count == 20 { goodNodes[id] = node.address }
                for v in r["values"]?.list ?? [] {
                    if let d = v.data { for p in PeerAddress.parseCompact(d) where found.insert(p).inserted { newPeers.append(p) } }
                }
                if let nodes = r["nodes"]?.data {
                    let b = [UInt8](nodes)
                    var i = 0
                    while i + 26 <= b.count {
                        let id = Data(b[i..<(i + 20)])
                        let host = "\(b[i + 20]).\(b[i + 21]).\(b[i + 22]).\(b[i + 23])"
                        let port = Int(b[i + 24]) << 8 | Int(b[i + 25])
                        if port > 0, let addr = try? SocketAddress(ipAddress: host, port: port) {
                            candidates.append(Node(id: id, address: addr))
                        }
                        i += 26
                    }
                }
            }
            if !newPeers.isEmpty { await onPeers(newPeers) }
            if goodNodes.count > 300 { goodNodes = Dictionary(uniqueKeysWithValues: goodNodes.prefix(200).map { ($0.key, $0.value) }) }
        }
    }
}

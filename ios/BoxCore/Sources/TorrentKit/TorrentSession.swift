import Foundation
import Crypto

public enum TorrentState: String, Codable, Sendable {
    case metadata, checking, downloading, paused, finished, error
}

public struct TorrentStatus: Sendable, Identifiable, Equatable {
    public let id: String
    public let name: String
    public let state: TorrentState
    public let hasMetadata: Bool
    /// Progress of the selected files, 0...1.
    public let progress: Double
    public let selectedBytes: Int64
    public let completedBytes: Int64
    public let downloadRate: Double
    public let connectedPeers: Int
    public let knownPeers: Int
    public let errorMessage: String?
    public let addedDate: Date
    public let sequential: Bool

    public var eta: TimeInterval? {
        guard downloadRate > 1, selectedBytes > completedBytes else { return nil }
        return Double(selectedBytes - completedBytes) / downloadRate
    }
}

public struct TorrentFileStatus: Sendable, Identifiable, Equatable {
    public let id: Int
    public let path: String
    public let name: String
    public let length: Int64
    public let completedBytes: Int64
    public let selected: Bool
    public let isPadding: Bool
    public var progress: Double { length > 0 ? Double(completedBytes) / Double(length) : 1 }
    public var isComplete: Bool { completedBytes >= length }
}

struct ResumeData: Codable {
    var infoHashHex: String
    var name: String
    var trackers: [String]
    var have: Data?
    var selected: [Bool]?
    var paused: Bool
    var sequential: Bool
    var addedDate: Date
    var peers: [String]?
}

private struct BlockKey: Hashable { let piece: Int; let begin: Int }

private final class Peer {
    let conn: PeerConnection
    let address: PeerAddress
    var handshaken = false
    var peerChoking = true
    var amInterested = false
    var bitfield: Bitfield?
    var rawBitfield: Data?
    var pendingHaves: [Int] = []
    var outstanding = Set<BlockKey>()
    var maxOutstanding = 16
    var extIds: [String: UInt8] = [:]
    var metadataSize: Int?
    var metadataRejected = false
    var connectedAt = Date()
    var lastMessage = Date()
    var lastPiece: Date?
    var bytesThisTick = 0
    var closed = false

    init(conn: PeerConnection) {
        self.conn = conn
        self.address = conn.address
    }

    func has(_ piece: Int) -> Bool { bitfield?[piece] ?? false }
}

private struct PieceProgress {
    let length: Int
    var buffer: Data
    /// 0 = missing, 1 = requested, 2 = received
    var blockState: [UInt8]
    var requestedAt: [Double]
    var owner: [ObjectIdentifier?]
    var duplicated: [Bool]
    var received = 0

    init(length: Int) {
        self.length = length
        let n = (length + TorrentSession.blockSize - 1) / TorrentSession.blockSize
        buffer = Data(count: length)
        blockState = [UInt8](repeating: 0, count: n)
        requestedAt = [Double](repeating: 0, count: n)
        owner = [ObjectIdentifier?](repeating: nil, count: n)
        duplicated = [Bool](repeating: false, count: n)
    }

    func blockLength(_ b: Int) -> Int {
        min(TorrentSession.blockSize, length - b * TorrentSession.blockSize)
    }

    mutating func reset() {
        for i in 0..<blockState.count { blockState[i] = 0; owner[i] = nil; duplicated[i] = false }
        received = 0
    }
}

/// One torrent: peers, piece picking, verification and storage.
actor TorrentSession {
    static let blockSize = 16 * 1024
    static let maxPeers = 50
    static let maxConnecting = 16
    static let ourMetadataExtId: UInt8 = 1

    nonisolated let infoHash: Data
    nonisolated let id: String
    let peerId: Data
    let downloadDirectory: URL
    let stateDirectory: URL

    private(set) var name: String
    private(set) var trackers: [String]
    private(set) var info: TorrentInfo?
    private var storage: TorrentStorage?
    private var have = Bitfield(count: 0)
    private var selected: [Bool] = []
    private var wanted = Bitfield(count: 0)
    private var availability: [Int] = []
    private var inProgress: [Int: PieceProgress] = [:]

    private(set) var paused = false
    private(set) var sequential = false
    private var state: TorrentState = .metadata
    private var errorMessage: String?
    private let addedDate: Date

    private var peers: [ObjectIdentifier: Peer] = [:]
    private var known = Set<PeerAddress>()
    private var candidates: [PeerAddress] = []
    private var connecting = Set<PeerAddress>()
    private var failedAt: [PeerAddress: Date] = [:]
    private var failCount: [PeerAddress: Int] = [:]
    private var peerTasks: [PeerAddress: Task<Void, Never>] = [:]

    private var metadataSize: Int?
    private var metadataPieces: [Int: Data] = [:]
    private var metadataRequestedAt: [Int: Date] = [:]

    private var bytesThisTick = 0
    private var rateHistory: [Int] = []
    private var downloadRate: Double = 0
    private var resumeDirty = false
    private var lastResumeSave = Date()

    private var streamFocus: [UUID: Int] = [:]
    private var waiters: [Int: [CheckedContinuation<Void, Error>]] = [:]

    private var tasks: [Task<Void, Never>] = []

    init(infoHash: Data, name: String, trackers: [String], downloadDirectory: URL, stateDirectory: URL,
         addedDate: Date = Date()) {
        self.infoHash = infoHash
        self.id = infoHash.hexString
        self.name = name
        self.trackers = trackers
        self.downloadDirectory = downloadDirectory
        self.stateDirectory = stateDirectory
        self.addedDate = addedDate
        self.peerId = Data(Array("-TB0100-".utf8) + randomBytes(12))
    }

    // MARK: - Lifecycle

    func configure(info: TorrentInfo?, resume: ResumeData?, extraPeers: [PeerAddress]) {
        if let info { applyInfo(info, resume: resume, persist: false) }
        if let r = resume {
            paused = r.paused
            sequential = r.sequential
            for p in r.peers ?? [] { if let a = PeerAddress(string: p) { addPeers([a]) } }
        }
        addPeers(extraPeers)
    }

    func start() {
        guard tasks.isEmpty else { return }
        paused = false
        errorMessage = nil
        state = info == nil ? .metadata : (have.isComplete || wantedComplete ? .finished : .downloading)
        if state == .finished { return }
        resumeDirty = true

        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await self?.tick()
            }
        })
        let allTrackers = trackers + defaultPublicTrackers.filter { !trackers.contains($0) }
        for url in allTrackers {
            tasks.append(Task { [weak self] in await self?.trackerLoop(url: url) })
        }
        tasks.append(Task { [weak self] in await self?.dhtLoop() })
    }

    func stop(pause: Bool) {
        for t in tasks { t.cancel() }
        tasks.removeAll()
        for t in peerTasks.values { t.cancel() }
        peerTasks.removeAll()
        for p in peers.values { p.closed = true; p.conn.close() }
        peers.removeAll()
        connecting.removeAll()
        for (i, var pp) in inProgress { pp.reset(); inProgress[i] = pp }
        downloadRate = 0
        rateHistory.removeAll()
        if pause {
            paused = true
            if state != .finished { state = .paused }
        }
        let ws = waiters
        waiters.removeAll()
        for list in ws.values { for c in list { c.resume(throwing: TorrentError.cancelled) } }
        storage?.closeAll()
        saveResume()
    }

    func setSequential(_ on: Bool) {
        sequential = on
        resumeDirty = true
    }

    func setSelection(_ sel: [Bool]) {
        guard let info, sel.count == info.files.count else { return }
        selected = sel
        recomputeWanted()
        resumeDirty = true
        saveResume()
        if wantedComplete {
            if state == .downloading { finish() }
        } else if state == .finished && !paused {
            state = .downloading
            if tasks.isEmpty { start() }
        }
    }

    private var wantedComplete: Bool {
        guard info != nil else { return false }
        for i in 0..<wanted.count where wanted[i] && !have[i] { return false }
        return true
    }

    private func recomputeWanted() {
        guard let info else { return }
        var w = Bitfield(count: info.pieceCount)
        for (i, s) in selected.enumerated() where s {
            if let r = info.pieceRange(forFile: i) { for p in r { w[p] = true } }
        }
        wanted = w
    }

    private func applyInfo(_ newInfo: TorrentInfo, resume: ResumeData?, persist: Bool) {
        info = newInfo
        name = newInfo.name
        storage = TorrentStorage(info: newInfo, downloadDirectory: downloadDirectory)
        have = Bitfield(count: newInfo.pieceCount)
        if let h = resume?.have { have = Bitfield(count: newInfo.pieceCount, data: h) }
        if let s = resume?.selected, s.count == newInfo.files.count {
            selected = s
        } else {
            selected = newInfo.files.indices.map { !newInfo.isPadding($0) }
        }
        availability = [Int](repeating: 0, count: newInfo.pieceCount)
        recomputeWanted()
        dropPiecesOfMissingFiles()
        if persist {
            let data = TorrentMetafile.build(infoDict: newInfo.infoDictData, trackers: trackers)
            try? data.write(to: stateDirectory.appendingPathComponent("\(id).torrent"))
            resumeDirty = true
            saveResume()
        }
        // Peers that connected before metadata was known.
        for p in peers.values {
            if let raw = p.rawBitfield { setBitfield(p, Bitfield(count: newInfo.pieceCount, data: raw)) }
            else if p.bitfield == nil { p.bitfield = Bitfield(count: newInfo.pieceCount) }
            for h in p.pendingHaves { markHave(p, h) }
            p.pendingHaves.removeAll()
            p.rawBitfield = nil
            updateInterest(p)
        }
    }

    /// If the user deleted downloaded files, forget their pieces so they get downloaded again.
    private func dropPiecesOfMissingFiles() {
        guard let info, let storage else { return }
        let fm = FileManager.default
        for i in info.files.indices where !info.isPadding(i) && info.files[i].length > 0 {
            guard let r = info.pieceRange(forFile: i) else { continue }
            if r.contains(where: { have[$0] }) && !fm.fileExists(atPath: storage.url(forFile: i).path) {
                for p in r { have[p] = false }
            }
        }
    }

    /// Re-verifies all data on disk (used when adding a torrent whose files already exist).
    func recheck() async {
        guard let info, let storage else { return }
        let wasRunning = !tasks.isEmpty
        if wasRunning { stop(pause: false) }
        state = .checking
        var h = Bitfield(count: info.pieceCount)
        for i in 0..<info.pieceCount {
            if let d = try? storage.readPiece(i), Data(Insecure.SHA1.hash(data: d)) == info.pieceHashes[i] { h[i] = true }
            if i % 16 == 0 { await Task.yield() }
        }
        have = h
        storage.closeAll()
        resumeDirty = true
        saveResume()
        state = wantedComplete ? .finished : (paused ? .paused : .downloading)
        if wasRunning || !paused { start() }
    }

    // MARK: - Status

    func status() -> TorrentStatus {
        var total: Int64 = 0, done: Int64 = 0
        if let info {
            for p in 0..<info.pieceCount where wanted[p] {
                let len = Int64(info.length(ofPiece: p))
                total += len
                if have[p] { done += len }
            }
        }
        let progress = total > 0 ? Double(done) / Double(total) : (state == .finished ? 1 : 0)
        return TorrentStatus(id: id, name: name, state: state, hasMetadata: info != nil, progress: progress,
                             selectedBytes: total, completedBytes: done, downloadRate: downloadRate,
                             connectedPeers: peers.values.filter { $0.handshaken }.count,
                             knownPeers: known.count, errorMessage: errorMessage, addedDate: addedDate,
                             sequential: sequential)
    }

    func fileStatuses() -> [TorrentFileStatus] {
        guard let info else { return [] }
        var completed = [Int64](repeating: 0, count: info.files.count)
        let pl = Int64(info.pieceLength)
        for (i, f) in info.files.enumerated() where f.length > 0 {
            guard let r = info.pieceRange(forFile: i) else { continue }
            for p in r where have[p] {
                let ps = Int64(p) * pl, pe = ps + Int64(info.length(ofPiece: p))
                completed[i] += min(pe, f.offset + f.length) - max(ps, f.offset)
            }
        }
        return info.files.enumerated().map { i, f in
            TorrentFileStatus(id: i, path: f.relativePath, name: f.name, length: f.length,
                              completedBytes: f.length == 0 ? 0 : completed[i],
                              selected: i < selected.count ? selected[i] : true, isPadding: info.isPadding(i))
        }
    }

    func fileURL(_ index: Int) -> URL? {
        guard let info, index < info.files.count else { return nil }
        return storage?.url(forFile: index)
    }

    var contentURL: URL? { storage?.contentURL }

    func fileInfo(_ index: Int) -> TorrentFileEntry? {
        guard let info, index < info.files.count else { return nil }
        return info.files[index]
    }

    func isFileComplete(_ index: Int) -> Bool {
        guard let info, let r = info.pieceRange(forFile: index) else { return info != nil }
        return r.allSatisfy { have[$0] }
    }

    // MARK: - Persistence

    func resumeData() -> ResumeData {
        ResumeData(infoHashHex: id, name: name, trackers: trackers, have: info == nil ? nil : have.data,
                   selected: info == nil ? nil : selected, paused: paused, sequential: sequential,
                   addedDate: addedDate, peers: Array(peers.values.prefix(30).map { $0.address.description }))
    }

    func markDirty() { resumeDirty = true }

    func saveResume() {
        guard resumeDirty else { return }
        resumeDirty = false
        lastResumeSave = Date()
        if let data = try? JSONEncoder().encode(resumeData()) {
            try? data.write(to: stateDirectory.appendingPathComponent("\(id).json"), options: .atomic)
        }
    }

    func addTrackers(_ list: [String]) {
        let new = list.filter { !trackers.contains($0) }
        guard !new.isEmpty else { return }
        trackers += new
        resumeDirty = true
        if !tasks.isEmpty { for u in new { tasks.append(Task { [weak self] in await self?.trackerLoop(url: u) }) } }
    }

    // MARK: - Peer discovery

    func addPeers(_ list: [PeerAddress]) {
        for p in list where known.insert(p).inserted { candidates.append(p) }
        if candidates.count > 2000 { candidates.removeFirst(candidates.count - 2000) }
    }

    private func trackerLoop(url: String) async {
        var event: AnnounceRequest.Event = .started
        var failures = 0
        while !Task.isCancelled {
            let left = remainingBytes()
            let req = AnnounceRequest(infoHash: infoHash, peerId: peerId, port: 6881, uploaded: 0,
                                      downloaded: 0, left: left, event: event)
            var wait: UInt64
            do {
                let resp = try await TrackerClient.announce(url: url, req)
                addPeers(resp.peers)
                event = .none
                failures = 0
                // Re-announce sooner while we still need peers.
                let needPeers = peers.count < 10
                wait = UInt64(needPeers ? min(max(resp.interval, 60), 300) : min(max(resp.interval, 120), 1800))
            } catch {
                failures += 1
                if failures > 6 { return }
                wait = UInt64(min(30 << failures, 1800))
            }
            try? await Task.sleep(nanoseconds: wait * 1_000_000_000)
        }
    }

    private func dhtLoop() async {
        while !Task.isCancelled {
            if peers.count < 30 || info == nil {
                let me = self
                await DHTClient.shared.lookup(infoHash: infoHash) { found in
                    await me.addPeers(found)
                }
            }
            try? await Task.sleep(nanoseconds: (info == nil ? 60 : 300) * 1_000_000_000)
        }
    }

    private func remainingBytes() -> Int64 {
        guard let info else { return 1 << 30 }
        var left: Int64 = 0
        for p in 0..<info.pieceCount where wanted[p] && !have[p] { left += Int64(info.length(ofPiece: p)) }
        return left
    }

    // MARK: - Periodic work

    private func tick() {
        // Rates
        rateHistory.append(bytesThisTick)
        bytesThisTick = 0
        if rateHistory.count > 5 { rateHistory.removeFirst() }
        downloadRate = Double(rateHistory.reduce(0, +)) / Double(max(rateHistory.count, 1))

        let now = Date()
        let nowT = now.timeIntervalSince1970

        // Adapt pipeline depth and drop dead peers.
        for p in Array(peers.values) {
            // ~2 seconds of data in flight, at least 8 blocks.
            p.maxOutstanding = max(8, min(128, (p.bytesThisTick / TorrentSession.blockSize) * 2 + 8))
            p.bytesThisTick = 0
            let idle = now.timeIntervalSince(p.lastMessage)
            let uselessFor = now.timeIntervalSince(p.lastPiece ?? p.connectedAt)
            if idle > 150 || (!candidates.isEmpty && peers.count >= TorrentSession.maxPeers - 5 && uselessFor > 90) {
                disconnect(p)
            }
        }

        // Re-request blocks that timed out.
        var refill = false
        for (index, var pp) in inProgress {
            var changed = false
            for b in 0..<pp.blockState.count where pp.blockState[b] == 1 && nowT - pp.requestedAt[b] > 30 {
                if let o = pp.owner[b] { peers[o]?.outstanding.remove(BlockKey(piece: index, begin: b * TorrentSession.blockSize)) }
                pp.blockState[b] = 0
                pp.owner[b] = nil
                pp.duplicated[b] = false
                changed = true
            }
            if changed { inProgress[index] = pp; refill = true }
        }
        for (i, t) in metadataRequestedAt where now.timeIntervalSince(t) > 20 { metadataRequestedAt[i] = nil }
        if info == nil { for p in peers.values { requestMetadata(p) } }
        if refill { for p in peers.values { fillRequests(p) } }

        connectMore()

        if resumeDirty && now.timeIntervalSince(lastResumeSave) > 15 { saveResume() }
    }

    private func connectMore() {
        guard !paused, state != .finished else { return }
        let now = Date()
        var skipped: [PeerAddress] = []
        while peers.count + connecting.count < TorrentSession.maxPeers,
              connecting.count < TorrentSession.maxConnecting, !candidates.isEmpty {
            let addr = candidates.removeFirst()
            if let f = failedAt[addr], now.timeIntervalSince(f) < 120 { skipped.append(addr); continue }
            connecting.insert(addr)
            peerTasks[addr] = Task { [weak self] in await self?.runPeer(addr) }
        }
        candidates.append(contentsOf: skipped)
    }

    // MARK: - Peer connections

    private func runPeer(_ addr: PeerAddress) async {
        let conn: PeerConnection
        do {
            conn = try await PeerConnection.connect(to: addr)
        } catch {
            connecting.remove(addr)
            peerTasks[addr] = nil
            noteFailure(addr)
            return
        }
        connecting.remove(addr)
        guard !Task.isCancelled, !paused, state != .finished else { conn.close(); return }
        let peer = Peer(conn: conn)
        peers[ObjectIdentifier(peer)] = peer
        conn.send(Wire.handshake(infoHash: infoHash, peerId: peerId))
        do {
            for try await frame in conn.frames {
                if peer.closed { break }
                try handle(frame, from: peer)
            }
        } catch {}
        let lived = Date().timeIntervalSince(peer.connectedAt)
        peerGone(peer)
        peerTasks[addr] = nil
        if lived < 30 { noteFailure(addr) } else { failCount[addr] = nil; failedAt[addr] = Date(); candidates.append(addr) }
    }

    /// Retries a peer a few times with back-off before forgetting it.
    private func noteFailure(_ addr: PeerAddress) {
        let n = (failCount[addr] ?? 0) + 1
        failCount[addr] = n
        failedAt[addr] = Date()
        if n < 3 { candidates.append(addr) }
    }

    private func disconnect(_ p: Peer) {
        p.closed = true
        p.conn.close()
        peerGone(p)
    }

    private func peerGone(_ p: Peer) {
        guard peers.removeValue(forKey: ObjectIdentifier(p)) != nil else { return }
        p.closed = true
        p.conn.close()
        releaseRequests(of: p)
        if let bf = p.bitfield, availability.count == bf.count {
            for i in 0..<bf.count where bf[i] { availability[i] -= 1 }
        }
    }

    private func releaseRequests(of p: Peer) {
        let me = ObjectIdentifier(p)
        for key in p.outstanding {
            guard var pp = inProgress[key.piece] else { continue }
            let b = key.begin / TorrentSession.blockSize
            if pp.blockState[b] == 1 && pp.owner[b] == me {
                pp.blockState[b] = 0
                pp.owner[b] = nil
                pp.duplicated[b] = false
                inProgress[key.piece] = pp
            }
        }
        p.outstanding.removeAll()
    }

    private func handle(_ frame: PeerFrame, from p: Peer) throws {
        p.lastMessage = Date()
        switch frame {
        case .keepAlive:
            return
        case .handshake(let reserved, let hash, let remoteId):
            guard hash == infoHash, remoteId != peerId else { throw PeerError.protocolViolation("wrong torrent") }
            p.handshaken = true
            if reserved[5] & 0x10 != 0 {
                var hs: [String: BValue] = [
                    "m": .dict(["ut_metadata": .int(Int64(TorrentSession.ourMetadataExtId))]),
                    "v": .str("TorrentBox 1.0"),
                    "reqq": .int(250),
                ]
                if let info { hs["metadata_size"] = .int(Int64(info.infoDictData.count)) }
                p.conn.send(Wire.extended(0, .dict(hs)))
            }
            if let info {
                p.bitfield = Bitfield(count: info.pieceCount)
                if have.setCount > 0 { p.conn.send(Wire.message(Wire.bitfield, Array(have.data))) }
            }
        case .message(let id, let payload):
            guard p.handshaken else { throw PeerError.protocolViolation("message before handshake") }
            try handleMessage(id, payload, from: p)
        }
    }

    private func handleMessage(_ id: UInt8, _ payload: [UInt8], from p: Peer) throws {
        switch id {
        case Wire.choke:
            p.peerChoking = true
            releaseRequests(of: p)
        case Wire.unchoke:
            p.peerChoking = false
            fillRequests(p)
        case Wire.have:
            let idx = Wire.readU32(payload, 0)
            if info != nil { markHave(p, idx); updateInterest(p); fillRequests(p) } else { p.pendingHaves.append(idx) }
        case Wire.bitfield:
            if let info {
                setBitfield(p, Bitfield(count: info.pieceCount, data: Data(payload)))
                updateInterest(p)
                fillRequests(p)
            } else {
                p.rawBitfield = Data(payload)
            }
        case Wire.piece:
            guard payload.count >= 8 else { throw PeerError.protocolViolation("short piece") }
            onBlock(p, index: Wire.readU32(payload, 0), begin: Wire.readU32(payload, 4), block: payload[8...])
        case Wire.extended:
            guard let ext = payload.first else { return }
            try handleExtended(ext, Data(payload.dropFirst()), from: p)
        default:
            break // request/cancel/port/interested are ignored: this client only downloads.
        }
    }

    private func setBitfield(_ p: Peer, _ bf: Bitfield) {
        if let old = p.bitfield { for i in 0..<old.count where old[i] { availability[i] -= 1 } }
        p.bitfield = bf
        for i in 0..<bf.count where bf[i] { availability[i] += 1 }
    }

    private func markHave(_ p: Peer, _ idx: Int) {
        guard let info, idx >= 0, idx < info.pieceCount else { return }
        if p.bitfield == nil { p.bitfield = Bitfield(count: info.pieceCount) }
        if p.bitfield![idx] == false {
            p.bitfield![idx] = true
            availability[idx] += 1
        }
    }

    private func updateInterest(_ p: Peer) {
        guard let bf = p.bitfield else { return }
        var interesting = false
        for i in 0..<bf.count where bf[i] && wanted[i] && !have[i] { interesting = true; break }
        if interesting != p.amInterested {
            p.amInterested = interesting
            p.conn.send(Wire.message(interesting ? Wire.interested : Wire.notInterested))
        }
    }

    // MARK: - Metadata exchange (BEP 9)

    private func handleExtended(_ ext: UInt8, _ body: Data, from p: Peer) throws {
        if ext == 0 {
            guard let v = try? BDecoder.decode(body) else { return }
            if let m = v["m"]?.dict {
                for (k, val) in m { if let i = val.int, i > 0, i < 256 { p.extIds[k] = UInt8(i) } else { p.extIds[k] = nil } }
            }
            if let s = v["metadata_size"]?.int, s > 0, s < 32 * 1024 * 1024 { p.metadataSize = Int(s) }
            if info == nil { requestMetadata(p) }
            return
        }
        guard ext == TorrentSession.ourMetadataExtId else { return }
        guard let (dict, used) = try? BDecoder.decodePrefix(body), let type = dict["msg_type"]?.int,
              let piece = dict["piece"]?.int.map(Int.init) else { return }
        switch type {
        case 0: // request
            guard let theirId = p.extIds["ut_metadata"] else { return }
            if let info, piece >= 0, piece * 16384 < info.infoDictData.count {
                let start = piece * 16384
                let end = min(start + 16384, info.infoDictData.count)
                let chunk = info.infoDictData.subdata(in: start..<end)
                p.conn.send(Wire.extended(theirId, .dict(["msg_type": .int(1), "piece": .int(Int64(piece)),
                                                          "total_size": .int(Int64(info.infoDictData.count))]), trailing: chunk))
            } else {
                p.conn.send(Wire.extended(theirId, .dict(["msg_type": .int(2), "piece": .int(Int64(piece))])))
            }
        case 1: // data
            guard info == nil, let size = metadataSize else { return }
            let chunk = body.subdata(in: (body.startIndex + used)..<body.endIndex)
            let pieces = (size + 16383) / 16384
            guard piece >= 0, piece < pieces else { return }
            metadataPieces[piece] = chunk
            metadataRequestedAt[piece] = nil
            if metadataPieces.count == pieces { assembleMetadata(size: size, pieces: pieces) } else { requestMetadata(p) }
        case 2: // reject
            p.metadataRejected = true
            metadataRequestedAt[piece] = nil
        default:
            break
        }
    }

    private func requestMetadata(_ p: Peer) {
        guard info == nil, !p.metadataRejected, let ut = p.extIds["ut_metadata"] else { return }
        if metadataSize == nil { metadataSize = p.metadataSize }
        guard let size = metadataSize, p.metadataSize == nil || p.metadataSize == size else { return }
        let pieces = (size + 16383) / 16384
        var sent = 0
        for i in 0..<pieces where metadataPieces[i] == nil && metadataRequestedAt[i] == nil {
            metadataRequestedAt[i] = Date()
            p.conn.send(Wire.extended(ut, .dict(["msg_type": .int(0), "piece": .int(Int64(i))])))
            sent += 1
            if sent >= 4 { break }
        }
    }

    private func assembleMetadata(size: Int, pieces: Int) {
        var data = Data(capacity: size)
        for i in 0..<pieces { data.append(metadataPieces[i]!) }
        metadataPieces.removeAll()
        metadataRequestedAt.removeAll()
        guard data.count == size, Data(Insecure.SHA1.hash(data: data)) == infoHash,
              let newInfo = try? TorrentInfo(infoDict: data) else {
            metadataSize = nil // bad data; start over with another peer
            return
        }
        applyInfo(newInfo, resume: nil, persist: true)
        state = .downloading
        let fm = FileManager.default
        if fm.fileExists(atPath: storage!.contentURL.path) {
            Task { await self.recheck() }
        } else {
            for p in peers.values { fillRequests(p) }
        }
    }

    // MARK: - Piece picking

    private func fillRequests(_ p: Peer) {
        guard info != nil, !paused, !p.peerChoking, !p.closed, p.amInterested, p.bitfield != nil else { return }
        let me = ObjectIdentifier(p)
        let now = Date().timeIntervalSince1970
        while p.outstanding.count < p.maxOutstanding {
            guard let (piece, block, dup) = pickBlock(for: p) else { break }
            guard var pp = inProgress[piece] else { break }
            let begin = block * TorrentSession.blockSize
            if dup { pp.duplicated[block] = true } else {
                pp.blockState[block] = 1
                pp.owner[block] = me
                pp.requestedAt[block] = now
            }
            inProgress[piece] = pp
            p.outstanding.insert(BlockKey(piece: piece, begin: begin))
            p.conn.send(Wire.request(index: piece, begin: begin, length: pp.blockLength(block)))
        }
    }

    private func priorityPieces() -> [Int] {
        guard let info, !streamFocus.isEmpty else { return [] }
        var out: [Int] = []
        // Window of ~8 MiB after each playback position.
        let window = max(4, (8 * 1024 * 1024) / info.pieceLength)
        for f in Set(streamFocus.values).sorted() {
            for p in f..<min(f + window, info.pieceCount) { out.append(p) }
        }
        return out
    }

    private func pickBlock(for p: Peer) -> (Int, Int, Bool)? {
        guard let info else { return nil }
        let focus = priorityPieces()
        let focusSet = Set(focus)
        // 1. Continue pieces already in progress (stream window first).
        let ordered = inProgress.keys.sorted { a, b in
            let fa = focusSet.contains(a), fb = focusSet.contains(b)
            return fa != fb ? fa : a < b
        }
        for idx in ordered where p.has(idx) {
            if let b = inProgress[idx]!.blockState.firstIndex(of: 0) { return (idx, b, false) }
        }
        // 2. Start a new piece.
        if let idx = choosePiece(for: p, focus: focus) {
            inProgress[idx] = PieceProgress(length: info.length(ofPiece: idx))
            return (idx, 0, false)
        }
        // 3. End game: duplicate slow requests held by other peers.
        let me = ObjectIdentifier(p)
        for idx in ordered where p.has(idx) {
            let pp = inProgress[idx]!
            for b in 0..<pp.blockState.count where pp.blockState[b] == 1 && pp.owner[b] != me && !pp.duplicated[b]
                && !p.outstanding.contains(BlockKey(piece: idx, begin: b * TorrentSession.blockSize)) {
                return (idx, b, true)
            }
        }
        return nil
    }

    private func choosePiece(for p: Peer, focus: [Int]) -> Int? {
        guard let info else { return nil }
        func eligible(_ i: Int) -> Bool { !have[i] && inProgress[i] == nil && p.has(i) }
        for i in focus where eligible(i) && (wanted[i] || !streamFocus.isEmpty) { return i }
        let n = info.pieceCount
        if sequential || !streamFocus.isEmpty {
            for i in 0..<n where wanted[i] && eligible(i) { return i }
            return nil
        }
        // Rarest first, random tie-break.
        var best: Int?
        var bestAvail = Int.max
        let start = Int.random(in: 0..<n)
        for k in 0..<n {
            let i = (start + k) % n
            guard wanted[i] && eligible(i) else { continue }
            if availability[i] < bestAvail { best = i; bestAvail = availability[i] }
        }
        return best
    }

    private func onBlock(_ p: Peer, index: Int, begin: Int, block: ArraySlice<UInt8>) {
        let key = BlockKey(piece: index, begin: begin)
        p.outstanding.remove(key)
        p.lastPiece = Date()
        p.bytesThisTick += block.count
        bytesThisTick += block.count
        guard let info, index >= 0, index < info.pieceCount, begin % TorrentSession.blockSize == 0,
              var pp = inProgress[index] else { fillRequests(p); return }
        let b = begin / TorrentSession.blockSize
        guard b < pp.blockState.count, pp.blockState[b] != 2, block.count == pp.blockLength(b) else {
            fillRequests(p); return
        }
        pp.buffer.replaceSubrange(begin..<(begin + block.count), with: block)
        pp.blockState[b] = 2
        pp.received += 1
        inProgress[index] = pp

        // Cancel duplicate requests in end game.
        if pp.duplicated[b] {
            for other in peers.values where other !== p && other.outstanding.contains(key) {
                other.outstanding.remove(key)
                other.conn.send(Wire.request(index: index, begin: begin, length: block.count, cancel: true))
            }
        }

        if pp.received == pp.blockState.count {
            inProgress[index] = nil
            if Data(Insecure.SHA1.hash(data: pp.buffer)) == info.pieceHashes[index] {
                pieceCompleted(index, data: pp.buffer)
            } else {
                // Corrupt piece: drop it, it will be picked again.
                errorMessage = nil
            }
        }
        fillRequests(p)
    }

    private func pieceCompleted(_ index: Int, data: Data) {
        do {
            try storage?.write(piece: index, data: data)
        } catch {
            errorMessage = "\(error.localizedDescription)"
            state = .error
            stop(pause: true)
            state = .error
            return
        }
        have[index] = true
        resumeDirty = true
        let msg = Wire.message(Wire.have, Wire.u32(UInt32(index)))
        for p in peers.values { p.conn.send(msg) }
        if let ws = waiters.removeValue(forKey: index) { for c in ws { c.resume() } }
        if wantedComplete { finish() }
    }

    private func finish() {
        storage?.truncateToFinalSizes(selected: selected)
        state = .finished
        let trackersCopy = trackers
        let req = AnnounceRequest(infoHash: infoHash, peerId: peerId, port: 6881, uploaded: 0, downloaded: 0,
                                  left: 0, event: .completed)
        Task.detached { for t in trackersCopy.prefix(5) { _ = try? await TrackerClient.announce(url: t, req) } }
        for t in tasks { t.cancel() }
        tasks.removeAll()
        for t in peerTasks.values { t.cancel() }
        peerTasks.removeAll()
        for p in peers.values { p.closed = true; p.conn.close() }
        peers.removeAll()
        connecting.removeAll()
        storage?.closeAll()
        downloadRate = 0
        resumeDirty = true
        saveResume()
    }

    // MARK: - Streaming support

    /// Reads up to `maxLength` bytes of a file at `offset`, waiting for the data to be downloaded.
    func readForStream(file index: Int, offset: Int64, maxLength: Int, stream: UUID) async throws -> Data {
        guard let info, let storage, index < info.files.count else { throw TorrentError.notFound }
        let f = info.files[index]
        guard offset < f.length else { return Data() }
        if !selected[index] {
            selected[index] = true
            recomputeWanted()
            resumeDirty = true
        }
        let abs = f.offset + offset
        let piece = Int(abs / Int64(info.pieceLength))
        if streamFocus[stream] != piece {
            streamFocus[stream] = piece
            if state == .finished && !have[piece] { state = .downloading }
            if tasks.isEmpty && !paused { start() }
            for p in peers.values { fillRequests(p) }
        }
        if !have[piece] {
            if paused { throw TorrentError.cancelled }
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                waiters[piece, default: []].append(c)
            }
        }
        let pieceEnd = Int64(piece + 1) * Int64(info.pieceLength)
        let len = Int(min(Int64(maxLength), pieceEnd - abs, f.offset + f.length - abs))
        return try storage.read(offset: abs, length: len)
    }

    func endStream(_ stream: UUID) {
        streamFocus[stream] = nil
    }
}

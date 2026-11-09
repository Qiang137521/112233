import Foundation

/// Owns all torrent sessions, persists them and serves files to media players.
public actor TorrentEngine {
    public let downloadDirectory: URL
    public let stateDirectory: URL
    private var sessions: [String: TorrentSession] = [:]
    private var order: [String] = []
    private var server: StreamServer?

    public init(downloadDirectory: URL, stateDirectory: URL) {
        self.downloadDirectory = downloadDirectory
        self.stateDirectory = stateDirectory
        try? FileManager.default.createDirectory(at: downloadDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
    }

    /// Restores torrents saved by a previous run.
    public func loadSaved() async {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: stateDirectory, includingPropertiesForKeys: nil) else { return }
        var restored: [(Date, TorrentSession, Bool)] = []
        for url in items where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let resume = try? JSONDecoder().decode(ResumeData.self, from: data),
                  let hash = Data(hexString: resume.infoHashHex), hash.count == 20,
                  sessions[resume.infoHashHex] == nil else { continue }
            var info: TorrentInfo?
            if let t = try? Data(contentsOf: stateDirectory.appendingPathComponent("\(resume.infoHashHex).torrent")) {
                info = try? TorrentMetafile(data: t).info
            }
            let s = TorrentSession(infoHash: hash, name: resume.name, trackers: resume.trackers,
                                   downloadDirectory: downloadDirectory, stateDirectory: stateDirectory,
                                   addedDate: resume.addedDate)
            await s.configure(info: info, resume: resume, extraPeers: [])
            sessions[s.id] = s
            restored.append((resume.addedDate, s, resume.paused))
        }
        restored.sort { $0.0 > $1.0 }
        order = restored.map { $0.1.id } + order.filter { id in !restored.contains { $0.1.id == id } }
        for (_, s, paused) in restored where !paused { await s.start() }
    }

    // MARK: - Adding

    @discardableResult
    public func add(torrentData: Data) async throws -> String {
        let meta = try TorrentMetafile(data: torrentData)
        if let existing = sessions[meta.info.infoHashHex] {
            await existing.addTrackers(meta.trackers)
            return existing.id
        }
        let s = TorrentSession(infoHash: meta.info.infoHash, name: meta.info.name, trackers: meta.trackers,
                               downloadDirectory: downloadDirectory, stateDirectory: stateDirectory)
        try torrentData.write(to: stateDirectory.appendingPathComponent("\(s.id).torrent"))
        await s.configure(info: meta.info, resume: nil, extraPeers: [])
        await register(s)
        if FileManager.default.fileExists(atPath: downloadDirectory.appendingPathComponent(meta.info.name).path) {
            Task { await s.recheck() }
        } else {
            await s.start()
        }
        return s.id
    }

    @discardableResult
    public func add(magnet: String) async throws -> String {
        let m = try MagnetLink(magnet)
        if let existing = sessions[m.infoHash.hexString] {
            await existing.addTrackers(m.trackers)
            await existing.addPeers(m.peers)
            return existing.id
        }
        let s = TorrentSession(infoHash: m.infoHash, name: m.displayName ?? m.infoHash.hexString, trackers: m.trackers,
                               downloadDirectory: downloadDirectory, stateDirectory: stateDirectory)
        await s.configure(info: nil, resume: nil, extraPeers: m.peers)
        await register(s)
        await s.start()
        return s.id
    }

    /// Adds a peer manually (useful for LAN transfers and testing).
    public func addPeer(_ id: String, _ address: PeerAddress) async {
        await sessions[id]?.addPeers([address])
    }

    private func register(_ s: TorrentSession) async {
        sessions[s.id] = s
        order.insert(s.id, at: 0)
        await s.saveResumeForced()
    }

    // MARK: - Control

    public func pause(_ id: String) async { await sessions[id]?.stop(pause: true) }

    public func resume(_ id: String) async { await sessions[id]?.start() }

    public func pauseAll() async { for s in sessions.values { await s.stop(pause: true) } }

    /// Stops networking but keeps the paused flag (used when the app goes to background).
    public func suspendAll() async { for s in sessions.values { await s.stop(pause: false) } }

    public func resumeActive() async {
        for s in sessions.values where !(await s.paused) { await s.start() }
    }

    public func remove(_ id: String, deleteFiles: Bool) async {
        guard let s = sessions.removeValue(forKey: id) else { return }
        order.removeAll { $0 == id }
        await s.stop(pause: true)
        let content = await s.contentURL
        let fm = FileManager.default
        try? fm.removeItem(at: stateDirectory.appendingPathComponent("\(id).json"))
        try? fm.removeItem(at: stateDirectory.appendingPathComponent("\(id).torrent"))
        if deleteFiles, let content { try? fm.removeItem(at: content) }
    }

    public func setSelection(_ id: String, selected: [Bool]) async {
        await sessions[id]?.setSelection(selected)
    }

    public func setSequential(_ id: String, _ on: Bool) async {
        await sessions[id]?.setSequential(on)
    }

    public func recheck(_ id: String) async {
        await sessions[id]?.recheck()
    }

    // MARK: - Queries

    public func statuses() async -> [TorrentStatus] {
        var out: [TorrentStatus] = []
        for id in order { if let s = sessions[id] { out.append(await s.status()) } }
        return out
    }

    public func status(_ id: String) async -> TorrentStatus? { await sessions[id]?.status() }

    public func files(_ id: String) async -> [TorrentFileStatus] { await sessions[id]?.fileStatuses() ?? [] }

    public func fileURL(_ id: String, file: Int) async -> URL? { await sessions[id]?.fileURL(file) }

    public func contentURL(_ id: String) async -> URL? { await sessions[id]?.contentURL }

    public func isFileComplete(_ id: String, file: Int) async -> Bool { await sessions[id]?.isFileComplete(file) ?? false }

    /// Saves resume data of all torrents (call when the app goes to background).
    public func saveAll() async { for s in sessions.values { await s.saveResumeForced() } }

    // MARK: - Streaming

    /// A URL that media players can open while the file is still downloading.
    /// Completed files are returned as plain file URLs.
    public func playbackURL(_ id: String, file: Int) async throws -> URL {
        guard let s = sessions[id], let entry = await s.fileInfo(file) else { throw TorrentError.notFound }
        if await s.isFileComplete(file), let u = await s.fileURL(file),
           FileManager.default.fileExists(atPath: u.path) {
            return u
        }
        if server == nil {
            let srv = StreamServer(engine: self)
            try await srv.start()
            server = srv
        }
        let encodedName = entry.name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "file"
        return URL(string: "http://127.0.0.1:\(server!.port)/\(id)/\(file)/\(encodedName)")!
    }

    func session(_ id: String) -> TorrentSession? { sessions[id] }
}

extension TorrentSession {
    func saveResumeForced() {
        markDirty()
        saveResume()
    }
}

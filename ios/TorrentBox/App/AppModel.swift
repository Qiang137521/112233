import SwiftUI
import AVKit
import UIKit
import TorrentKit
import ArchiveKit

struct PlayerItem: Identifiable {
    let id = UUID()
    let url: URL
    let title: String
}

@MainActor
final class AppModel: ObservableObject {
    let documents: URL
    let downloads: URL
    let engine: TorrentEngine

    @Published var torrents: [TorrentStatus] = []
    @Published var vlcItem: PlayerItem?
    @Published var message: String?
    @Published var selectedTab = 0

    private var pollTask: Task<Void, Never>?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var suspended = false
    private let keepAlive = KeepAlivePlayer()

    init() {
        let fm = FileManager.default
        documents = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        downloads = documents.appendingPathComponent("Downloads", isDirectory: true)
        let state = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Torrents", isDirectory: true)
        engine = TorrentEngine(downloadDirectory: downloads, stateDirectory: state)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        let engine = self.engine
        Task {
            await engine.loadSaved()
            await self.refresh()
        }
        startPolling()
    }

    // MARK: - Torrents

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    func refresh() async {
        let s = await engine.statuses()
        if s != torrents { torrents = s }
    }

    /// Accepts one or more magnet links / info hashes separated by new lines.
    func addMagnets(_ text: String) {
        let lines = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        let links = lines.filter { $0.lowercased().hasPrefix("magnet:") || ($0.count == 40 && Data(hexString: $0) != nil) }
        guard !links.isEmpty else { message = "没有找到有效的磁力链接"; return }
        Task {
            for l in links {
                do { try await engine.add(magnet: l) } catch { message = error.localizedDescription }
            }
            await refresh()
            selectedTab = 0
        }
    }

    func addTorrentFile(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            Task {
                do { try await engine.add(torrentData: data) } catch { message = error.localizedDescription }
                await refresh()
                selectedTab = 0
            }
        } catch {
            message = "无法读取种子文件: \(error.localizedDescription)"
        }
    }

    func togglePause(_ t: TorrentStatus) {
        Task {
            if t.state == .paused || t.state == .error { await engine.resume(t.id) } else { await engine.pause(t.id) }
            await refresh()
        }
    }

    func remove(_ id: String, deleteFiles: Bool) {
        Task {
            await engine.remove(id, deleteFiles: deleteFiles)
            await refresh()
        }
    }

    func pauseAll() { Task { await engine.pauseAll(); await refresh() } }

    func resumeAll() {
        Task {
            for t in torrents where t.state == .paused { await engine.resume(t.id) }
            await refresh()
        }
    }

    // MARK: - Opening files from other apps

    func handleOpenURL(_ url: URL) {
        if url.scheme?.lowercased() == "magnet" {
            addMagnets(url.absoluteString)
            return
        }
        guard url.isFileURL else { return }
        if url.pathExtension.lowercased() == "torrent" {
            addTorrentFile(url)
            return
        }
        // Any other file: copy it into Documents/导入 and act on it.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let inbox = documents.appendingPathComponent("导入", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
            let dest = ArchiveExtractor.uniqueDestination(inbox.appendingPathComponent(url.lastPathComponent))
            try FileManager.default.copyItem(at: url, to: dest)
            if FileKind(url: dest) == .video || FileKind(url: dest) == .audio {
                play(fileURL: dest)
            } else {
                selectedTab = 1
                message = "已导入到「文件 › 导入」: \(dest.lastPathComponent)"
            }
        } catch {
            message = "导入失败: \(error.localizedDescription)"
        }
    }

    // MARK: - Playback

    static let avPlayerExtensions: Set<String> = ["mp4", "m4v", "mov", "mp3", "m4a", "aac", "wav", "caf", "aiff", "m3u8"]

    func play(fileURL url: URL, forceVLC: Bool = false) {
        play(url: url, title: url.lastPathComponent, forceVLC: forceVLC)
    }

    func play(url: URL, title: String, forceVLC: Bool = false) {
        let ext = (title as NSString).pathExtension.lowercased()
        let alwaysVLC = UserDefaults.standard.bool(forKey: "alwaysVLC")
        if forceVLC || alwaysVLC || !AppModel.avPlayerExtensions.contains(ext) {
            vlcItem = PlayerItem(url: url, title: title)
        } else {
            presentAVPlayer(url: url)
        }
    }

    func playTorrentFile(id: String, file: TorrentFileStatus, forceVLC: Bool = false) {
        Task {
            do {
                let url = try await engine.playbackURL(id, file: file.id)
                play(url: url, title: file.name, forceVLC: forceVLC)
            } catch {
                message = "无法播放: \(error.localizedDescription)"
            }
        }
    }

    private func presentAVPlayer(url: URL) {
        guard let root = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow })?.rootViewController else { return }
        var top = root
        while let p = top.presentedViewController { top = p }
        let player = AVPlayer(url: url)
        let vc = AVPlayerViewController()
        vc.player = player
        vc.allowsPictureInPicturePlayback = true
        vc.modalPresentationStyle = .fullScreen
        top.present(vc, animated: true) { player.play() }
    }

    // MARK: - Background handling

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .background:
            Task { await engine.saveAll() }
            let downloading = torrents.contains { $0.state == .downloading || $0.state == .metadata }
            if downloading && UserDefaults.standard.bool(forKey: "keepAlive") {
                keepAlive.start()
                return
            }
            // iOS gives us roughly 30 seconds; then stop networking cleanly.
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "torrent") { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    await self.engine.suspendAll()
                    self.suspended = true
                    self.endBackgroundTask()
                }
            }
        case .active:
            keepAlive.stop()
            endBackgroundTask()
            if suspended {
                suspended = false
                Task { await engine.resumeActive() }
            }
        default:
            break
        }
    }

    private func endBackgroundTask() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }
}

/// Plays silence so iOS keeps the app (and downloads) running in the background.
/// Optional, off by default, and meant for sideloaded builds.
final class KeepAlivePlayer {
    private var player: AVAudioPlayer?

    func start() {
        guard player == nil else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        guard let p = try? AVAudioPlayer(data: KeepAlivePlayer.silentWAV()) else { return }
        p.numberOfLoops = -1
        p.volume = 0
        p.play()
        player = p
    }

    func stop() {
        player?.stop()
        player = nil
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
    }

    static func silentWAV(seconds: Int = 1, rate: Int = 8000) -> Data {
        let samples = seconds * rate
        var d = Data()
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: Int) { var x = UInt16(v).littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + samples * 2)
        d.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(samples * 2)
        d.append(Data(count: samples * 2))
        return d
    }
}

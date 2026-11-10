import SwiftUI
import UIKit
import VLCKitSPM

/// Wraps VLCMediaPlayer for SwiftUI. Plays almost any container/codec (MKV, AVI, RMVB, FLAC, …)
/// and also the local HTTP stream used for play-while-downloading.
final class VLCController: NSObject, ObservableObject, VLCMediaPlayerDelegate {
    let player = VLCMediaPlayer()
    let url: URL

    @Published var isPlaying = false
    @Published var isBuffering = true
    @Published var position: Float = 0
    @Published var timeText = "00:00"
    @Published var remainingText = "--:--"
    @Published var errorText: String?
    @Published var rate: Float = 1
    var isSeeking = false

    init(url: URL) {
        self.url = url
        super.init()
        let media = VLCMedia(url: url)
        // Bigger cache for the local stream: pieces may arrive in bursts.
        media.addOption(url.isFileURL ? ":file-caching=500" : ":network-caching=3000")
        player.media = media
        player.delegate = self
    }

    func attach(_ view: UIView) { player.drawable = view }

    func start() {
        player.play()
        if url.isFileURL { addSiblingSubtitles() }
    }

    func stop() {
        player.stop()
        player.delegate = nil
    }

    func togglePlay() {
        if player.isPlaying { player.pause() } else { player.play() }
    }

    func seek(to value: Float) { player.position = value }
    func jump(_ seconds: Int32) {
        if seconds > 0 { player.jumpForward(seconds) } else { player.jumpBackward(-seconds) }
    }

    func setRate(_ r: Float) {
        player.rate = r
        rate = r
    }

    struct Track: Hashable { let id: Int32; let name: String }

    var audioTracks: [Track] { tracks(player.audioTrackIndexes, player.audioTrackNames) }
    var subtitleTracks: [Track] { tracks(player.videoSubTitlesIndexes, player.videoSubTitlesNames) }

    private func tracks(_ idx: [Any]?, _ names: [Any]?) -> [Track] {
        zip(idx ?? [], names ?? []).compactMap { i, n in
            guard let i = i as? NSNumber else { return nil }
            return Track(id: i.int32Value, name: (n as? String) ?? "轨道 \(i)")
        }
    }

    /// Loads "movie.srt"/"movie.chs.ass"… next to a local "movie.mkv".
    private func addSiblingSubtitles() {
        let dir = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent.lowercased()
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for f in files where ["srt", "ass", "ssa", "vtt", "sub"].contains(f.pathExtension.lowercased())
            && f.lastPathComponent.lowercased().hasPrefix(base) {
            player.addPlaybackSlave(f, type: .subtitle, enforce: false)
        }
    }

    // MARK: VLCMediaPlayerDelegate

    func mediaPlayerStateChanged(_ aNotification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let state = self.player.state
            self.isPlaying = self.player.isPlaying
            self.isBuffering = state == .opening || state == .buffering && !self.player.isPlaying
            if state == .error { self.errorText = "无法播放此文件" }
        }
    }

    func mediaPlayerTimeChanged(_ aNotification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isBuffering = false
            self.isPlaying = self.player.isPlaying
            if !self.isSeeking { self.position = self.player.position }
            self.timeText = self.player.time.stringValue ?? "00:00"
            self.remainingText = self.player.remainingTime?.stringValue ?? "--:--"
        }
    }
}

private struct VLCVideoView: UIViewRepresentable {
    let controller: VLCController

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .black
        controller.attach(v)
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

struct VLCPlayerScreen: View {
    let item: PlayerItem
    @Environment(\.dismiss) private var dismiss
    @StateObject private var controller: VLCController
    @State private var showControls = true
    @State private var hideTask: Task<Void, Never>?

    init(item: PlayerItem) {
        self.item = item
        _controller = StateObject(wrappedValue: VLCController(url: item.url))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VLCVideoView(controller: controller)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { withAnimation { showControls.toggle() }; scheduleHide() }

            if controller.isBuffering && controller.errorText == nil {
                VStack(spacing: 8) {
                    ProgressView().tint(.white).controlSize(.large)
                    Text(item.url.isFileURL ? "加载中…" : "缓冲中（边下边播）…").font(.caption).foregroundStyle(.white.opacity(0.8))
                }
            }
            if let err = controller.errorText {
                Text(err).foregroundStyle(.white).padding().background(.black.opacity(0.6), in: Capsule())
            }
            if showControls { controls.transition(.opacity) }
        }
        .statusBarHidden(!showControls)
        .persistentSystemOverlays(showControls ? .automatic : .hidden)
        .onAppear {
            controller.start()
            scheduleHide()
        }
        .onDisappear {
            hideTask?.cancel()
            controller.stop()
        }
    }

    private var controls: some View {
        VStack {
            HStack(spacing: 16) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.title3.weight(.semibold)).padding(10)
                }
                Text(item.title).font(.subheadline).lineLimit(1)
                Spacer()
                Menu {
                    let audio = controller.audioTracks
                    if !audio.isEmpty {
                        Section("音轨") {
                            ForEach(audio, id: \.self) { t in
                                Button {
                                    controller.player.currentAudioTrackIndex = t.id
                                } label: {
                                    if controller.player.currentAudioTrackIndex == t.id { Label(t.name, systemImage: "checkmark") } else { Text(t.name) }
                                }
                            }
                        }
                    }
                    let subs = controller.subtitleTracks
                    if !subs.isEmpty {
                        Section("字幕") {
                            ForEach(subs, id: \.self) { t in
                                Button {
                                    controller.player.currentVideoSubTitleIndex = t.id
                                } label: {
                                    if controller.player.currentVideoSubTitleIndex == t.id { Label(t.name, systemImage: "checkmark") } else { Text(t.name) }
                                }
                            }
                        }
                    }
                    Section("倍速") {
                        ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { r in
                            Button {
                                controller.setRate(Float(r))
                            } label: {
                                if abs(controller.rate - Float(r)) < 0.01 { Label("\(r, specifier: "%g")x", systemImage: "checkmark") }
                                else { Text("\(r, specifier: "%g")x") }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.title3).padding(10)
                }
            }
            .padding(.horizontal)

            Spacer()

            HStack(spacing: 48) {
                Button { controller.jump(-10); scheduleHide() } label: { Image(systemName: "gobackward.10") }
                Button { controller.togglePlay(); scheduleHide() } label: {
                    Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 44))
                }
                Button { controller.jump(10); scheduleHide() } label: { Image(systemName: "goforward.10") }
            }
            .font(.system(size: 30))

            Spacer()

            HStack(spacing: 10) {
                Text(controller.timeText).monospacedDigit()
                Slider(value: $controller.position, in: 0...1) { editing in
                    controller.isSeeking = editing
                    if !editing { controller.seek(to: controller.position) }
                    scheduleHide()
                }
                Text(controller.remainingText).monospacedDigit()
            }
            .font(.caption)
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
        .foregroundStyle(.white)
        .background(
            LinearGradient(colors: [.black.opacity(0.6), .clear, .clear, .black.opacity(0.6)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        )
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !Task.isCancelled && controller.isPlaying { withAnimation { showControls = false } }
        }
    }
}

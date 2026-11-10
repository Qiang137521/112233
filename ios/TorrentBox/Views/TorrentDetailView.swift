import SwiftUI
import TorrentKit

struct TorrentDetailView: View {
    let torrentId: String
    @EnvironmentObject var model: AppModel
    @State private var files: [TorrentFileStatus] = []
    @State private var contentURL: URL?
    @State private var showHidden = false

    private var status: TorrentStatus? { model.torrents.first { $0.id == torrentId } }

    var body: some View {
        List {
            if let s = status {
                Section {
                    TorrentRow(status: s)
                    HStack {
                        Button {
                            model.togglePause(s)
                        } label: {
                            Label(s.state == .paused || s.state == .error ? "开始" : "暂停",
                                  systemImage: s.state == .paused || s.state == .error ? "play.fill" : "pause.fill")
                        }
                        .buttonStyle(.bordered)
                        .disabled(s.state == .finished)
                        Spacer()
                        Button {
                            Task { await model.engine.recheck(torrentId) }
                        } label: {
                            Label("重新校验", systemImage: "checkmark.shield")
                        }
                        .buttonStyle(.bordered)
                        .disabled(!s.hasMetadata)
                    }
                    Toggle(isOn: Binding(get: { s.sequential }, set: { on in
                        Task { await model.engine.setSequential(torrentId, on); await model.refresh() }
                    })) {
                        VStack(alignment: .leading) {
                            Text("顺序下载")
                            Text("按文件顺序下载，适合边下边播").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let contentURL, s.hasMetadata {
                        NavigationLink {
                            FileBrowserView(directory: contentURL.hasDirectoryPath ? contentURL : contentURL.deletingLastPathComponent(),
                                            title: s.name)
                        } label: {
                            Label("在文件中查看", systemImage: "folder")
                        }
                    }
                }
            }

            if status?.hasMetadata == false {
                Section {
                    HStack {
                        ProgressView()
                        Text("正在从网络获取种子信息，请稍候…").foregroundStyle(.secondary)
                    }
                }
            }

            if !files.isEmpty {
                Section {
                    ForEach(visibleFiles) { f in
                        fileRow(f)
                    }
                } header: {
                    HStack {
                        Text("文件 (\(visibleFiles.count))")
                        Spacer()
                        Button("全选") { setAll(true) }
                        Button("全不选") { setAll(false) }
                    }
                    .textCase(nil)
                } footer: {
                    Text("勾选需要下载的文件。点击视频/音频即可边下边播。")
                }
            }
        }
        .navigationTitle(status?.name ?? "任务")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            while !Task.isCancelled {
                let f = await model.engine.files(torrentId)
                if f != files { files = f }
                if contentURL == nil { contentURL = await model.engine.contentURL(torrentId) }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private var visibleFiles: [TorrentFileStatus] { files.filter { !$0.isPadding } }

    @ViewBuilder
    private func fileRow(_ f: TorrentFileStatus) -> some View {
        let kind = FileKind(name: f.name)
        HStack(spacing: 12) {
            Button {
                toggle(f)
            } label: {
                Image(systemName: f.selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(f.selected ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)

            Image(systemName: kind.symbol)
                .foregroundStyle(.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(f.path).font(.subheadline).lineLimit(2)
                HStack {
                    Text(Fmt.bytes(f.length))
                    if f.selected && !f.isComplete {
                        Text(String(format: "%.1f%%", f.progress * 100))
                    } else if f.isComplete {
                        Text("已完成").foregroundStyle(.green)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if f.selected && !f.isComplete {
                    ProgressView(value: f.progress).controlSize(.mini)
                }
            }
            Spacer(minLength: 0)
            if kind.isPlayable {
                Button {
                    model.playTorrentFile(id: torrentId, file: f)
                } label: {
                    Image(systemName: "play.circle.fill").font(.title2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }
        }
        .contextMenu {
            if kind.isPlayable {
                Button { model.playTorrentFile(id: torrentId, file: f) } label: { Label("播放", systemImage: "play") }
                Button { model.playTorrentFile(id: torrentId, file: f, forceVLC: true) } label: {
                    Label("用 VLC 播放", systemImage: "play.rectangle")
                }
            }
            Button { toggle(f) } label: {
                Label(f.selected ? "不下载" : "下载", systemImage: f.selected ? "xmark.circle" : "arrow.down.circle")
            }
        }
    }

    private func toggle(_ f: TorrentFileStatus) {
        var sel = files.map(\.selected)
        sel[f.id].toggle()
        apply(sel)
    }

    private func setAll(_ on: Bool) {
        apply(files.map { $0.isPadding ? false : on })
    }

    private func apply(_ sel: [Bool]) {
        Task {
            await model.engine.setSelection(torrentId, selected: sel)
            files = await model.engine.files(torrentId)
            await model.refresh()
        }
    }
}

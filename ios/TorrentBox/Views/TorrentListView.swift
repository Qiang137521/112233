import SwiftUI
import UniformTypeIdentifiers
import TorrentKit

struct TorrentListView: View {
    @EnvironmentObject var model: AppModel
    @State private var showAdd = false
    @State private var showImporter = false
    @State private var pendingDelete: TorrentStatus?

    var body: some View {
        NavigationStack {
            List {
                ForEach(model.torrents) { t in
                    NavigationLink(value: t.id) {
                        TorrentRow(status: t)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { pendingDelete = t } label: { Label("删除", systemImage: "trash") }
                        Button { model.togglePause(t) } label: {
                            t.state == .paused ? Label("开始", systemImage: "play.fill") : Label("暂停", systemImage: "pause.fill")
                        }
                        .tint(.orange)
                    }
                    .contextMenu {
                        Button { model.togglePause(t) } label: {
                            t.state == .paused ? Label("开始", systemImage: "play.fill") : Label("暂停", systemImage: "pause.fill")
                        }
                        Button { UIPasteboard.general.string = "magnet:?xt=urn:btih:\(t.id)" } label: {
                            Label("复制磁力链接", systemImage: "link")
                        }
                        Button(role: .destructive) { pendingDelete = t } label: { Label("删除", systemImage: "trash") }
                    }
                }
            }
            .overlay {
                if model.torrents.isEmpty {
                    ContentUnavailableView {
                        Label("没有下载任务", systemImage: "arrow.down.circle")
                    } description: {
                        Text("点击右上角 + 粘贴磁力链接或导入 .torrent 种子文件")
                    } actions: {
                        Button("添加任务") { showAdd = true }.buttonStyle(.borderedProminent)
                    }
                }
            }
            .navigationTitle("下载")
            .navigationDestination(for: String.self) { id in
                TorrentDetailView(torrentId: id)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { showAdd = true } label: { Label("磁力链接", systemImage: "link") }
                        Button { showImporter = true } label: { Label("种子文件", systemImage: "doc.badge.plus") }
                        Divider()
                        Button { model.resumeAll() } label: { Label("全部开始", systemImage: "play") }
                        Button { model.pauseAll() } label: { Label("全部暂停", systemImage: "pause") }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showAdd) {
                AddMagnetView()
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [UTType.torrent, .data],
                          allowsMultipleSelection: true) { result in
                if case .success(let urls) = result {
                    for u in urls { model.addTorrentFile(u) }
                }
            }
            .confirmationDialog("删除任务「\(pendingDelete?.name ?? "")」", isPresented: Binding(
                get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
                if let t = pendingDelete {
                    Button("仅删除任务") { model.remove(t.id, deleteFiles: false) }
                    Button("删除任务和文件", role: .destructive) { model.remove(t.id, deleteFiles: true) }
                }
                Button("取消", role: .cancel) {}
            }
        }
    }
}

extension UTType {
    static let torrent = UTType(importedAs: "org.bittorrent.torrent", conformingTo: .data)
}

struct TorrentRow: View {
    let status: TorrentStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(status.name)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
            ProgressView(value: status.progress)
                .tint(tint)
            HStack(spacing: 8) {
                Label(stateText, systemImage: stateIcon)
                    .foregroundStyle(tint)
                Spacer()
                if status.hasMetadata {
                    Text("\(Fmt.bytes(status.completedBytes)) / \(Fmt.bytes(status.selectedBytes))")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if status.state == .downloading || status.state == .metadata {
                HStack(spacing: 12) {
                    Label(Fmt.rate(status.downloadRate), systemImage: "arrow.down")
                    Label("\(status.connectedPeers)/\(status.knownPeers)", systemImage: "person.2")
                    Spacer()
                    if status.hasMetadata { Text("剩余 \(Fmt.duration(status.eta))") }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var stateText: String {
        switch status.state {
        case .metadata: return "获取种子信息…"
        case .checking: return "校验中…"
        case .downloading: return String(format: "下载中 %.1f%%", status.progress * 100)
        case .paused: return String(format: "已暂停 %.1f%%", status.progress * 100)
        case .finished: return "已完成"
        case .error: return "错误: \(status.errorMessage ?? "")"
        }
    }

    private var stateIcon: String {
        switch status.state {
        case .metadata: return "magnifyingglass"
        case .checking: return "checkmark.shield"
        case .downloading: return "arrow.down.circle"
        case .paused: return "pause.circle"
        case .finished: return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle"
        }
    }

    private var tint: Color {
        switch status.state {
        case .finished: return .green
        case .paused: return .gray
        case .error: return .red
        default: return .accentColor
        }
    }
}

struct AddMagnetView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .frame(minHeight: 140)
                        .font(.footnote.monospaced())
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("磁力链接（每行一个）")
                } footer: {
                    Text("支持 magnet:?xt=urn:btih:… 链接或 40 位信息哈希。")
                }
                Section {
                    // PasteButton does not trigger the iOS paste permission prompt.
                    PasteButton(payloadType: String.self) { strings in
                        let joined = strings.joined(separator: "\n")
                        DispatchQueue.main.async { text = joined }
                    }
                }
            }
            .navigationTitle("添加磁力链接")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加") {
                        model.addMagnets(text)
                        dismiss()
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

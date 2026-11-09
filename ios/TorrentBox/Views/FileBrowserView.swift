import SwiftUI
import QuickLook
import UniformTypeIdentifiers
import ArchiveKit

struct FileItem: Identifiable, Hashable {
    var id: URL { url }
    let url: URL
    let isDirectory: Bool
    let size: Int64
    let modified: Date
    var name: String { url.lastPathComponent }
    var kind: FileKind { FileKind(url: url, isDirectory: isDirectory) }
}

@MainActor
final class ExtractionState: ObservableObject {
    @Published var running = false
    @Published var fraction: Double = 0
    @Published var currentName = ""
    var progress = ExtractProgress()
}

struct FileBrowserView: View {
    let directory: URL
    let title: String

    @EnvironmentObject var model: AppModel
    @State private var items: [FileItem] = []
    @State private var preview: URL?
    @State private var showImporter = false
    @State private var pendingDelete: FileItem?
    @State private var passwordTarget: FileItem?
    @State private var password = ""
    @State private var renameTarget: FileItem?
    @State private var newName = ""
    @StateObject private var extraction = ExtractionState()

    var body: some View {
        List {
            ForEach(items) { item in
                row(item)
            }
        }
        .overlay {
            if items.isEmpty {
                ContentUnavailableView("空文件夹", systemImage: "folder",
                                       description: Text("下载的文件会出现在 Downloads 中，也可以从「文件」App 拷入。"))
            }
        }
        .overlay {
            if extraction.running { extractionOverlay }
        }
        .navigationTitle(title)
        .navigationDestination(for: FileItem.self) { item in
            FileBrowserView(directory: item.url, title: item.name)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showImporter = true } label: { Image(systemName: "square.and.arrow.down") }
            }
        }
        .refreshable { reload() }
        .onAppear { reload() }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { importFiles(urls) }
        }
        .quickLookPreview($preview)
        .confirmationDialog("删除「\(pendingDelete?.name ?? "")」？", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let p = pendingDelete { try? FileManager.default.removeItem(at: p.url); reload() }
            }
            Button("取消", role: .cancel) {}
        }
        .alert("输入解压密码", isPresented: Binding(get: { passwordTarget != nil }, set: { if !$0 { passwordTarget = nil } })) {
            SecureField("密码", text: $password)
            Button("解压") {
                if let t = passwordTarget { extract(t, password: password) }
                password = ""
            }
            Button("取消", role: .cancel) { password = "" }
        } message: {
            Text(passwordTarget?.name ?? "")
        }
        .alert("重命名", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
            TextField("名称", text: $newName)
            Button("确定") { rename() }
            Button("取消", role: .cancel) {}
        }
    }

    @ViewBuilder
    private func row(_ item: FileItem) -> some View {
        let content = HStack(spacing: 12) {
            Image(systemName: item.kind.symbol)
                .font(.title3)
                .foregroundStyle(item.isDirectory ? Color.accentColor : .secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).lineLimit(2)
                Text(item.isDirectory
                     ? item.modified.formatted(date: .abbreviated, time: .shortened)
                     : "\(Fmt.bytes(item.size)) · \(item.modified.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        Group {
            if item.isDirectory {
                NavigationLink(value: item) { content }
            } else {
                Button { open(item) } label: { content.contentShape(Rectangle()) }
                    .buttonStyle(.plain)
            }
        }
        .swipeActions {
            Button(role: .destructive) { pendingDelete = item } label: { Label("删除", systemImage: "trash") }
        }
        .contextMenu {
            if item.kind.isPlayable {
                Button { model.play(fileURL: item.url) } label: { Label("播放", systemImage: "play") }
                Button { model.play(fileURL: item.url, forceVLC: true) } label: { Label("用 VLC 播放", systemImage: "play.rectangle") }
            }
            if item.kind == .archive {
                Button { extract(item, password: nil) } label: { Label("解压到此处", systemImage: "archivebox") }
                Button { passwordTarget = item } label: { Label("输入密码解压", systemImage: "key") }
            }
            if !item.isDirectory {
                Button { preview = item.url } label: { Label("预览", systemImage: "eye") }
            }
            ShareLink(item: item.url) { Label("分享 / 存储到…", systemImage: "square.and.arrow.up") }
            Button { newName = item.name; renameTarget = item } label: { Label("重命名", systemImage: "pencil") }
            Button(role: .destructive) { pendingDelete = item } label: { Label("删除", systemImage: "trash") }
        }
    }

    private var extractionOverlay: some View {
        VStack(spacing: 12) {
            Text("正在解压…").font(.headline)
            ProgressView(value: extraction.fraction)
            Text(extraction.currentName).font(.caption).lineLimit(1).foregroundStyle(.secondary)
            Button("取消", role: .cancel) { extraction.progress.cancel() }
        }
        .padding(20)
        .frame(maxWidth: 320)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .shadow(radius: 20)
    }

    // MARK: - Actions

    private func reload() {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let urls = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys,
                                                 options: [.skipsHiddenFiles])) ?? []
        items = urls.compactMap { u in
            let v = try? u.resourceValues(forKeys: Set(keys))
            return FileItem(url: u, isDirectory: v?.isDirectory ?? false, size: Int64(v?.fileSize ?? 0),
                            modified: v?.contentModificationDate ?? .distantPast)
        }
        .sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    private func open(_ item: FileItem) {
        switch item.kind {
        case .video, .audio: model.play(fileURL: item.url)
        case .archive: extract(item, password: nil)
        case .torrent: model.addTorrentFile(item.url)
        default: preview = item.url
        }
    }

    private func extract(_ item: FileItem, password: String?) {
        guard !extraction.running else { return }
        let progress = ExtractProgress()
        extraction.progress = progress
        extraction.fraction = 0
        extraction.currentName = item.name
        extraction.running = true
        let dest = directory
        let deleteAfter = UserDefaults.standard.bool(forKey: "deleteAfterExtract")
        let job = Task.detached(priority: .userInitiated) { () -> Result<URL, Error> in
            do { return .success(try ArchiveExtractor.extract(item.url, to: dest, password: password, progress: progress)) }
            catch { return .failure(error) }
        }
        Task {
            while extraction.running {
                extraction.fraction = progress.fraction
                extraction.currentName = progress.currentName
                try? await Task.sleep(nanoseconds: 150_000_000)
                if job.isCancelled { break }
                if progress.fraction >= 1 { break }
            }
        }
        Task {
            let result = await job.value
            extraction.running = false
            switch result {
            case .success(let out):
                if deleteAfter { try? FileManager.default.removeItem(at: item.url) }
                model.message = "已解压到「\(out.lastPathComponent)」"
            case .failure(let error as ArchiveExtractError):
                switch error {
                case .needsPassword: passwordTarget = item
                case .wrongPassword: model.message = "密码错误"; passwordTarget = item
                case .cancelled: break
                default: model.message = error.localizedDescription
                }
            case .failure(let error):
                model.message = error.localizedDescription
            }
            reload()
        }
    }

    private func importFiles(_ urls: [URL]) {
        let fm = FileManager.default
        for u in urls {
            let scoped = u.startAccessingSecurityScopedResource()
            defer { if scoped { u.stopAccessingSecurityScopedResource() } }
            let dest = ArchiveExtractor.uniqueDestination(directory.appendingPathComponent(u.lastPathComponent))
            do { try fm.copyItem(at: u, to: dest) } catch { model.message = "导入失败: \(error.localizedDescription)" }
        }
        reload()
    }

    private func rename() {
        guard let t = renameTarget else { return }
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "_")
        guard !name.isEmpty, name != t.name else { return }
        do {
            try FileManager.default.moveItem(at: t.url, to: t.url.deletingLastPathComponent().appendingPathComponent(name))
        } catch {
            model.message = "重命名失败: \(error.localizedDescription)"
        }
        reload()
    }
}

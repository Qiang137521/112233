import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("alwaysVLC") private var alwaysVLC = false
    @AppStorage("keepAlive") private var keepAlive = false
    @AppStorage("deleteAfterExtract") private var deleteAfterExtract = false
    @State private var usage: Int64 = 0
    @State private var free: Int64 = 0

    var body: some View {
        NavigationStack {
            Form {
                Section("播放") {
                    Toggle("总是使用 VLC 播放器", isOn: $alwaysVLC)
                    Text("默认情况下 MP4/MOV/MP3 使用系统播放器（支持画中画、AirPlay），其它格式（MKV、AVI、RMVB、FLAC 等）使用 VLC。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("下载") {
                    Toggle("后台继续下载", isOn: $keepAlive)
                    Text("iOS 会在切到后台约 30 秒后暂停网络。开启后通过播放静音音频让下载在后台继续，会增加耗电。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("全部开始") { model.resumeAll() }
                    Button("全部暂停") { model.pauseAll() }
                }
                Section("解压") {
                    Toggle("解压成功后删除压缩包", isOn: $deleteAfterExtract)
                    Text("支持 ZIP、RAR（含加密、分卷）、7Z（含加密）、TAR、GZ、BZ2、XZ。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("存储") {
                    LabeledContent("已下载文件", value: Fmt.bytes(usage))
                    LabeledContent("设备可用空间", value: Fmt.bytes(free))
                    Text("所有文件保存在本 App 的「文稿」目录，可在系统「文件」App › 我的 iPhone › TorrentBox 中访问。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("关于") {
                    LabeledContent("版本", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                    Text("请仅下载你有权获取的内容。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("设置")
            .task { computeUsage() }
        }
    }

    private func computeUsage() {
        let fm = FileManager.default
        var total: Int64 = 0
        if let e = fm.enumerator(at: model.documents, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) {
            for case let u as URL in e {
                total += Int64((try? u.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
            }
        }
        usage = total
        if let v = try? model.documents.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let cap = v.volumeAvailableCapacityForImportantUsage {
            free = cap
        }
    }
}

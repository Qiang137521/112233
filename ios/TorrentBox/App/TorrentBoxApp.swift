import SwiftUI

@main
struct TorrentBoxApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .onOpenURL { model.handleOpenURL($0) }
        }
        .onChange(of: scenePhase) { _, phase in
            model.scenePhaseChanged(phase)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        TabView(selection: $model.selectedTab) {
            TorrentListView()
                .tabItem { Label("下载", systemImage: "arrow.down.circle") }
                .tag(0)
            NavigationStack {
                FileBrowserView(directory: model.documents, title: "文件")
            }
            .tabItem { Label("文件", systemImage: "folder") }
            .tag(1)
            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
                .tag(2)
        }
        .fullScreenCover(item: $model.vlcItem) { item in
            VLCPlayerScreen(item: item)
        }
        .alert("提示", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(model.message ?? "")
        }
    }
}

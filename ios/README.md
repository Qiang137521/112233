# TorrentBox — iOS 下载 / 解压 / 播放一体 App

一个 SwiftUI 编写的 iOS App（iOS 17+，iPhone / iPad），三个核心功能：

| 功能 | 说明 |
| --- | --- |
| **BT 下载** | 支持磁力链接和 `.torrent` 种子；Tracker（HTTP/UDP）+ DHT 找节点；可选择要下载的文件；断点续传；顺序下载 |
| **边下边播** | 内置本地 HTTP 流媒体服务器（支持 Range），播放器拖到哪就优先下载哪段 |
| **解压** | ZIP、RAR（含密码、分卷）、7Z（含密码、BCJ 过滤器）、TAR、GZ、BZ2、XZ、tar.gz/xz/bz2；中文 Windows ZIP 文件名（GBK）不乱码 |
| **播放** | MP4/MOV/MP3 默认使用系统播放器（画中画、AirPlay）；MKV/AVI/RMVB/FLAC 等使用 VLC（音轨/字幕切换、倍速、自动加载同名字幕） |
| **文件管理** | 浏览、预览、分享、重命名、删除；文件同时出现在系统「文件」App 里 |

其它：可从 Safari 直接打开 `magnet:` 链接；可在其它 App 里「用 TorrentBox 打开」种子、压缩包、视频。

## 目录结构

```
ios/
├── project.yml              XcodeGen 工程描述（生成 TorrentBox.xcodeproj）
├── TorrentBox/              App（SwiftUI）
│   ├── App/                 入口、AppModel（状态 & 后台处理）
│   ├── Views/               下载列表、任务详情、文件浏览、设置
│   ├── Player/              VLC 播放器界面
│   └── Support/             文件类型、格式化
└── BoxCore/                 Swift Package（与 UI 无关，可在 Linux/macOS 上测试）
    ├── Sources/TorrentKit/  纯 Swift 实现的 BitTorrent 引擎（基于 SwiftNIO）
    ├── Sources/ArchiveKit/  解压（ZIPFoundation / Unrar / PLzmaSDK / SWCompression）
    ├── Sources/boxcli/      命令行测试工具
    └── Scripts/e2e_test.sh  与 libtorrent 做互通的端到端测试
```

BT 引擎实现了：BEP 3（基础协议）、BEP 9/10（磁力链接元数据交换）、BEP 5（DHT 查找节点）、BEP 15（UDP Tracker）、
BEP 23（紧凑节点列表）、BEP 47（填充文件），稀有优先 / 顺序 / 流媒体窗口三种选块策略，以及 End-game 模式。

## 构建与安装

### 方式一：GitHub Actions 自动打包（不需要 Mac）

推送代码后，`.github/workflows/ios.yml` 会在 macOS 机器上编译并产出 **未签名 IPA**
（Actions 页面 → 对应运行 → Artifacts → `TorrentBox-unsigned-ipa`）。
用以下任一工具签名安装：AltStore / SideStore、Sideloadly、爱思助手、TrollStore（支持的系统版本）。

### 方式二：本地 Xcode

```bash
brew install xcodegen
cd ios
xcodegen generate
open TorrentBox.xcodeproj
```

在 Xcode 里选择你的开发者账号（Signing & Capabilities → Team），连接 iPhone 后运行即可。
免费 Apple ID 也可以，签名有效期 7 天。

### 测试核心库（macOS 或 Linux）

```bash
cd ios/BoxCore
swift test
pip install libtorrent && ./Scripts/e2e_test.sh   # 与 libtorrent 互通测试
swift run boxcli download "magnet:?xt=urn:btih:..." ./out
swift run boxcli extract some.rar ./out [密码]
```

## 已知限制

- **后台下载**：iOS 会在 App 切到后台约 30 秒后暂停网络。设置里可开启「后台继续下载」（播放静音音频保活），
  会增加耗电，且不适合上架 App Store。
- 只下载不做种（不接受入站连接、不上传），对大部分公开种子足够，但对强制分享率的 PT 站不适用。
- 加密 ZIP（ZipCrypto/AES）暂不支持，RAR 和 7z 的加密都支持。
- TAR / GZ / BZ2 / XZ 解压会把整个文件读入内存，超大的 tar.gz 在内存较小的设备上可能失败（ZIP、RAR、7z 是流式解压，不受影响）。

请只下载你有权获取的内容。

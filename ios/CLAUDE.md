# TorrentBox — notes for Claude Code

iOS app (SwiftUI, iOS 17+) that downloads BitTorrent (magnet / .torrent), extracts archives and plays media.
The user is not a developer and prefers Chinese; explain steps simply.

## Layout
- `project.yml` — XcodeGen spec. The `.xcodeproj` and `TorrentBox/Info.plist` are generated, not committed.
- `TorrentBox/` — app UI: `App/AppModel.swift` (state, background handling), `Views/`, `Player/VLCPlayerScreen.swift`.
- `BoxCore/` — Swift package, UI-free, builds on macOS and Linux:
  - `TorrentKit` — own BitTorrent engine on SwiftNIO (trackers, DHT, BEP 9 magnets, piece picking, resume,
    local HTTP Range server in `StreamServer.swift` for play-while-downloading).
  - `ArchiveKit` — zip (ZIPFoundation), rar (Unrar.swift), 7z (PLzmaSDK, pinned by revision), tar/gz/bz2/xz (SWCompression).
  - `boxcli` — CLI harness; `Scripts/e2e_test.sh` runs it against a libtorrent seeder.

## Build & run on a Mac
```bash
brew install xcodegen
cd ios && xcodegen generate && open TorrentBox.xcodeproj
```
Set Signing & Capabilities → Team to the user's Apple ID, change the bundle id if it is taken, pick the
iPhone, Run. Rerun `xcodegen generate` after adding/removing files or editing `project.yml`.

Command-line build check (no signing):
```bash
cd ios && xcodebuild -project TorrentBox.xcodeproj -scheme TorrentBox -sdk iphoneos \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

## Tests
```bash
cd ios/BoxCore && swift test
python3 -m venv /tmp/venv && /tmp/venv/bin/pip install libtorrent
PYTHON=/tmp/venv/bin/python ./Scripts/e2e_test.sh
```
`TORRENTKIT_DEBUG=1` logs peer connects/disconnects to stderr.

## Gotchas learned so far
- Use `ChannelOptions.tcpOption(...)` for TCP options; `socketOption(.tcp_nodelay)` sets SO_DEBUG and fails
  without root (this broke every peer connection once).
- Torrent creators order files differently; never assume a file index in tests.
- VLCKit 3.6 (vlckit-spm): `player.time` is non-optional, `remainingTime` is optional.
- CI: `.github/workflows/ios.yml` — Linux tests + unsigned IPA on macOS (macOS minutes count 10x on private repos).

## Not yet verified on a real device
The UI and VLC playback have only been compiled, never run on an iPhone. First on-device run should check:
adding a magnet, file selection, play-while-downloading (AVPlayer for mp4, VLC for mkv), extracting zip/rar/7z,
and files showing up in the Files app.

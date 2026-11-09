import Foundation
import TorrentKit
import ArchiveKit

// Small CLI to exercise the engine on macOS/Linux.
//   boxcli download <file.torrent|magnet> <dir> [--peer host:port] [--stream N] [--timeout S]
//   boxcli extract <archive> <dir> [password]
//   boxcli info <file.torrent>

let args = CommandLine.arguments
func usage() -> Never {
    print("usage: boxcli download <torrent|magnet> <dir> [--peer host:port] [--stream fileIndex] [--timeout seconds]")
    print("       boxcli extract <archive> <dir> [password]")
    print("       boxcli info <torrent>")
    exit(2)
}
guard args.count >= 3 else { usage() }

func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

switch args[1] {
case "info":
    let meta = try TorrentMetafile(data: Data(contentsOf: URL(fileURLWithPath: args[2])))
    print("name: \(meta.info.name)\ninfohash: \(meta.info.infoHashHex)\npieces: \(meta.info.pieceCount) x \(meta.info.pieceLength)")
    for f in meta.info.files { print("  \(f.length)\t\(f.relativePath)") }
    print("trackers: \(meta.trackers)")

case "extract":
    guard args.count >= 4 else { usage() }
    let out = try ArchiveExtractor.extract(URL(fileURLWithPath: args[2]), to: URL(fileURLWithPath: args[3]),
                                           password: args.count > 4 ? args[4] : nil)
    print("extracted to \(out.path)")

case "download":
    guard args.count >= 4 else { usage() }
    let dir = URL(fileURLWithPath: args[3])
    let engine = TorrentEngine(downloadDirectory: dir, stateDirectory: dir.appendingPathComponent(".state"))
    let source = args[2]
    let id: String
    if source.lowercased().hasPrefix("magnet:") || source.count == 40 {
        id = try await engine.add(magnet: source)
    } else {
        id = try await engine.add(torrentData: Data(contentsOf: URL(fileURLWithPath: source)))
    }
    if let p = option("--peer"), let addr = PeerAddress(string: p) { await engine.addPeer(id, addr) }
    let timeout = Double(option("--timeout") ?? "600") ?? 600
    let start = Date()

    if let s = option("--stream"), let fileIndex = Int(s) {
        // Wait for metadata, then fetch the file through the streaming server.
        while await engine.status(id)?.hasMetadata != true {
            try await Task.sleep(nanoseconds: 200_000_000)
            if Date().timeIntervalSince(start) > timeout { print("timeout waiting for metadata"); exit(1) }
        }
        let url = try await engine.playbackURL(id, file: fileIndex)
        print("STREAM_URL \(url.absoluteString)")
        fflush(stdout)
    }

    var last = ""
    while true {
        guard let st = await engine.status(id) else { exit(1) }
        let line = String(format: "%@ %@ %.1f%% %.0f KB/s peers %d/%d", st.name, st.state.rawValue,
                          st.progress * 100, st.downloadRate / 1024, st.connectedPeers, st.knownPeers)
        if line != last { print(line); last = line; fflush(stdout) }
        if st.state == .finished { print("DONE"); break }
        if st.state == .error { print("ERROR \(st.errorMessage ?? "")"); exit(1) }
        if Date().timeIntervalSince(start) > timeout && option("--stream") == nil { print("timeout"); exit(1) }
        try await Task.sleep(nanoseconds: 500_000_000)
    }
    if option("--stream") != nil {
        // Keep serving for a few seconds so a client can finish reading.
        try await Task.sleep(nanoseconds: UInt64(Double(option("--linger") ?? "0")! * 1e9))
    }

default:
    usage()
}

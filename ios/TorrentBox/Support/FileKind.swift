import Foundation
import ArchiveKit

enum FileKind: Equatable {
    case folder, video, audio, archive, torrent, image, subtitle, text, other

    init(url: URL, isDirectory: Bool = false) {
        if isDirectory { self = .folder; return }
        self.init(name: url.lastPathComponent)
        if self == .other, ArchiveExtractor.format(of: url) != nil { self = .archive }
    }

    init(name: String) {
        let lower = name.lowercased()
        let ext = (lower as NSString).pathExtension
        if lower.hasSuffix(".tar.gz") || lower.hasSuffix(".tar.bz2") || lower.hasSuffix(".tar.xz") { self = .archive; return }
        switch ext {
        case "mp4", "m4v", "mov", "mkv", "avi", "wmv", "flv", "webm", "ts", "m2ts", "mts", "rmvb", "rm", "mpg", "mpeg",
             "3gp", "vob", "ogv", "f4v", "asf", "divx":
            self = .video
        case "mp3", "m4a", "aac", "flac", "wav", "ogg", "opus", "ape", "wma", "alac", "aiff", "caf", "dsf", "dff":
            self = .audio
        case "zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "tbz2", "xz", "txz", "cbz", "cbr", "cb7":
            self = .archive
        case "torrent":
            self = .torrent
        case "jpg", "jpeg", "png", "gif", "heic", "webp", "bmp", "tiff":
            self = .image
        case "srt", "ass", "ssa", "vtt", "sub", "idx":
            self = .subtitle
        case "txt", "nfo", "md", "log", "json", "xml", "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "epub":
            self = .text
        default:
            self = .other
        }
    }

    var isPlayable: Bool { self == .video || self == .audio }

    var symbol: String {
        switch self {
        case .folder: return "folder.fill"
        case .video: return "film"
        case .audio: return "music.note"
        case .archive: return "doc.zipper"
        case .torrent: return "arrow.down.doc"
        case .image: return "photo"
        case .subtitle: return "captions.bubble"
        case .text: return "doc.text"
        case .other: return "doc"
        }
    }
}

enum Fmt {
    static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    static func rate(_ bps: Double) -> String {
        bps < 1 ? "0 KB/s" : ByteCountFormatter.string(fromByteCount: Int64(bps), countStyle: .file) + "/s"
    }

    static func duration(_ t: TimeInterval?) -> String {
        guard let t, t.isFinite, t > 0 else { return "--" }
        let s = Int(t)
        if s >= 86400 { return "\(s / 86400)天\((s % 86400) / 3600)时" }
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

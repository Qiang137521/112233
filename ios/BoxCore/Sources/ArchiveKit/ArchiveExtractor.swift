import Foundation
import ZIPFoundation
import SWCompression
import Unrar
import PLzmaSDK

public enum ArchiveFormat: String, Sendable {
    case zip, rar, sevenZip = "7z", tar, gzip = "gz", bzip2 = "bz2", xz, tarGz = "tar.gz", tarBz2 = "tar.bz2", tarXz = "tar.xz"
}

public enum ArchiveExtractError: Error, LocalizedError, Equatable {
    case unsupported
    case needsPassword
    case wrongPassword
    case corrupted(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .unsupported: return "不支持的压缩格式"
        case .needsPassword: return "该压缩包需要密码"
        case .wrongPassword: return "密码错误"
        case .corrupted(let s): return "压缩包损坏或无法读取: \(s)"
        case .cancelled: return "已取消"
        }
    }
}

public final class ExtractProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var _fraction: Double = 0
    private var _cancelled = false
    private var _currentName = ""
    public init() {}
    public var fraction: Double { lock.lock(); defer { lock.unlock() }; return _fraction }
    public var currentName: String { lock.lock(); defer { lock.unlock() }; return _currentName }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }
    public func cancel() { lock.lock(); _cancelled = true; lock.unlock() }
    func update(_ f: Double, _ name: String? = nil) {
        lock.lock(); _fraction = min(max(f, 0), 1); if let name { _currentName = name }; lock.unlock()
    }
}

public enum ArchiveExtractor {
    public static func format(of url: URL) -> ArchiveFormat? {
        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz") { return .tarGz }
        if name.hasSuffix(".tar.bz2") || name.hasSuffix(".tbz2") || name.hasSuffix(".tbz") { return .tarBz2 }
        if name.hasSuffix(".tar.xz") || name.hasSuffix(".txz") { return .tarXz }
        switch url.pathExtension.lowercased() {
        case "zip", "cbz": return .zip
        case "rar", "cbr": return .rar
        case "7z", "cb7": return .sevenZip
        case "tar": return .tar
        case "gz": return .gzip
        case "bz2": return .bzip2
        case "xz": return .xz
        default: break
        }
        // Fall back to magic bytes (e.g. files without an extension).
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let magic = [UInt8]((try? h.read(upToCount: 8)) ?? Data())
        if magic.starts(with: [0x50, 0x4b, 0x03, 0x04]) { return .zip }
        if magic.starts(with: [0x52, 0x61, 0x72, 0x21, 0x1a, 0x07]) { return .rar }
        if magic.starts(with: [0x37, 0x7a, 0xbc, 0xaf, 0x27, 0x1c]) { return .sevenZip }
        if magic.starts(with: [0x1f, 0x8b]) { return .gzip }
        if magic.starts(with: [0x42, 0x5a, 0x68]) { return .bzip2 }
        if magic.starts(with: [0xfd, 0x37, 0x7a, 0x58, 0x5a, 0x00]) { return .xz }
        return nil
    }

    public static func isArchive(_ url: URL) -> Bool {
        guard format(of: url) != nil else { return false }
        // Split RAR volumes other than the first one are not extracted on their own.
        let n = url.lastPathComponent.lowercased()
        if let r = n.range(of: #"\.part(\d+)\.rar$"#, options: .regularExpression) {
            let num = n[r].filter(\.isNumber)
            return Int(num) == 1
        }
        return true
    }

    /// Extracts `archive` into a new folder inside `destination` and returns that folder.
    @discardableResult
    public static func extract(_ archive: URL, to destination: URL, password: String? = nil,
                               progress: ExtractProgress = ExtractProgress()) throws -> URL {
        guard let fmt = format(of: archive) else { throw ArchiveExtractError.unsupported }
        let fm = FileManager.default
        var base = archive.deletingPathExtension().lastPathComponent
        if base.lowercased().hasSuffix(".tar") { base = String(base.dropLast(4)) }
        if let r = base.range(of: #"\.part\d+$"#, options: [.regularExpression, .caseInsensitive]) { base.removeSubrange(r) }
        let out = uniqueURL(destination.appendingPathComponent(base, isDirectory: true))
        try fm.createDirectory(at: out, withIntermediateDirectories: true)
        do {
            switch fmt {
            case .zip: try extractZip(archive, to: out, progress: progress)
            case .rar: try extractRar(archive, to: out, password: password, progress: progress)
            case .sevenZip: try extract7z(archive, to: out, password: password, progress: progress)
            case .tar:
                let data = try Data(contentsOf: archive, options: .mappedIfSafe)
                try writeEntries(try TarContainer.open(container: data), to: out, progress: progress)
            case .tarGz, .tarBz2, .tarXz:
                let data = try Data(contentsOf: archive, options: .mappedIfSafe)
                progress.update(0.05, archive.lastPathComponent)
                let tar = try decompress(data, fmt)
                try writeEntries(try TarContainer.open(container: tar), to: out, progress: progress)
            case .gzip, .bzip2, .xz:
                let data = try Data(contentsOf: archive, options: .mappedIfSafe)
                progress.update(0.1, base)
                let raw = try decompress(data, fmt)
                // A lone .gz may still contain a tar.
                if let entries = try? TarContainer.open(container: raw), !entries.isEmpty {
                    try writeEntries(entries, to: out, progress: progress)
                } else {
                    try raw.write(to: out.appendingPathComponent(base))
                }
            }
        } catch {
            try? fm.removeItem(at: out)
            if let e = error as? ArchiveExtractError { throw e }
            throw ArchiveExtractError.corrupted(error.localizedDescription)
        }
        progress.update(1)
        return out
    }

    private static func decompress(_ data: Data, _ fmt: ArchiveFormat) throws -> Data {
        switch fmt {
        case .gzip, .tarGz: return try GzipArchive.unarchive(archive: data)
        case .bzip2, .tarBz2: return try BZip2.decompress(data: data)
        case .xz, .tarXz: return try XZArchive.unarchive(archive: data)
        default: throw ArchiveExtractError.unsupported
        }
    }

    // MARK: - Helpers

    /// Returns `url`, or "name (2).ext", "name (3).ext"... if it already exists.
    public static func uniqueDestination(_ url: URL) -> URL { uniqueURL(url) }

    static func uniqueURL(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let parent = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let stem = ext.isEmpty ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
        var i = 2
        while true {
            let name = ext.isEmpty ? "\(stem) (\(i))" : "\(stem) (\(i)).\(ext)"
            let u = parent.appendingPathComponent(name)
            if !fm.fileExists(atPath: u.path) { return u }
            i += 1
        }
    }

    /// Resolves an entry path inside `root`, refusing absolute paths and ".." (zip-slip).
    static func safeURL(root: URL, entryPath: String) -> URL? {
        let comps = entryPath.replacingOccurrences(of: "\\", with: "/").split(separator: "/")
            .map(String.init).filter { !$0.isEmpty && $0 != "." }
        guard !comps.isEmpty, !comps.contains("..") else { return nil }
        var u = root
        for c in comps { u.appendPathComponent(c) }
        return u
    }

    private static func writeEntries<E: ContainerEntry>(_ entries: [E], to root: URL, progress: ExtractProgress) throws {
        let fm = FileManager.default
        for (i, e) in entries.enumerated() {
            if progress.isCancelled { throw ArchiveExtractError.cancelled }
            guard let dest = safeURL(root: root, entryPath: e.info.name) else { continue }
            progress.update(0.1 + 0.9 * Double(i) / Double(max(entries.count, 1)), e.info.name)
            switch e.info.type {
            case .directory:
                try fm.createDirectory(at: dest, withIntermediateDirectories: true)
            case .regular, .contiguous:
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try (e.data ?? Data()).write(to: dest)
            default:
                continue
            }
        }
    }

    /// Entry names flagged as UTF-8 decode identically either way; anything else is a legacy
    /// code page name, which for Chinese Windows zips is GBK.
    static func zipPath(_ e: ZIPFoundation.Entry) -> String {
        let def = e.path
        if e.path(using: .utf8) == def { return def }
        if let enc = legacyZipEncoding { return e.path(using: enc) }
        return def
    }

    private static func extractZip(_ url: URL, to root: URL, progress: ExtractProgress) throws {
        let fm = FileManager.default
        let archive: ZIPFoundation.Archive
        do {
            archive = try ZIPFoundation.Archive(url: url, accessMode: .read)
        } catch {
            throw ArchiveExtractError.corrupted(error.localizedDescription)
        }
        // ZIPFoundation skips encrypted entries, so an apparently empty archive means encryption.
        let entries = Array(archive)
        if entries.isEmpty, ((try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0) > 1024 {
            throw ArchiveExtractError.corrupted("加密的 ZIP 暂不支持，请使用 7z 或 RAR")
        }
        let total = max(entries.reduce(UInt64(0)) { $0 + $1.uncompressedSize }, 1)
        var done: UInt64 = 0
        for e in entries {
            if progress.isCancelled { throw ArchiveExtractError.cancelled }
            let path = zipPath(e)
            if path.hasPrefix("__MACOSX/") { continue }
            guard let dest = safeURL(root: root, entryPath: path) else { continue }
            progress.update(Double(done) / Double(total), path)
            switch e.type {
            case .directory:
                try fm.createDirectory(at: dest, withIntermediateDirectories: true)
            case .file:
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                _ = try archive.extract(e, to: dest)
            case .symlink:
                continue // never follow links from untrusted archives
            }
            done += e.uncompressedSize
        }
    }

    /// Encoding for zip entries without the UTF-8 flag. Windows zips in China use GBK.
    static var legacyZipEncoding: String.Encoding? {
        #if canImport(Darwin)
        let cf = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        return String.Encoding(rawValue: cf)
        #else
        return nil
        #endif
    }

    private static func extractRar(_ url: URL, to root: URL, password: String?, progress: ExtractProgress) throws {
        let pw = (password?.isEmpty ?? true) ? nil : password
        let archive: Unrar.Archive
        do { archive = try Unrar.Archive(fileURL: url, password: pw) } catch {
            throw ArchiveExtractError.corrupted("\(error)")
        }
        if archive.isHeaderEncrypted && pw == nil { throw ArchiveExtractError.needsPassword }
        let entries: [Unrar.Entry]
        do { entries = try archive.entries() } catch {
            throw pw == nil ? ArchiveExtractError.needsPassword : ArchiveExtractError.wrongPassword
        }
        if pw == nil && entries.contains(where: { $0.encrypted }) { throw ArchiveExtractError.needsPassword }
        let total = max(entries.reduce(UInt64(0)) { $0 + $1.uncompressedSize }, 1)
        var done: UInt64 = 0
        let fm = FileManager.default
        for e in entries {
            if progress.isCancelled { throw ArchiveExtractError.cancelled }
            guard let dest = safeURL(root: root, entryPath: e.fileName) else { continue }
            if e.directory {
                try fm.createDirectory(at: dest, withIntermediateDirectories: true)
                continue
            }
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard fm.createFile(atPath: dest.path, contents: nil) else { throw ArchiveExtractError.corrupted("无法写入文件") }
            let handle = try FileHandle(forWritingTo: dest)
            var writeError: Error?
            let start = done
            do {
                try archive.extract(e) { data, p in
                    if writeError == nil {
                        do { try handle.write(contentsOf: data) } catch { writeError = error; p.cancel() }
                    }
                    if progress.isCancelled { p.cancel() }
                    progress.update(Double(start + UInt64(max(p.completedUnitCount, 0))) / Double(total), e.fileName)
                }
            } catch {
                try? handle.close()
                if progress.isCancelled { throw ArchiveExtractError.cancelled }
                if case UnrarError.missingPassword = error { throw ArchiveExtractError.needsPassword }
                if e.encrypted { throw ArchiveExtractError.wrongPassword }
                throw ArchiveExtractError.corrupted("\(error)")
            }
            try handle.close()
            if let writeError { throw writeError }
            if progress.isCancelled { throw ArchiveExtractError.cancelled }
            done += e.uncompressedSize
        }
    }

    // MARK: - 7z

    private final class SevenZipDelegate: DecoderDelegate {
        let progress: ExtractProgress
        init(_ p: ExtractProgress) { progress = p }
        func decoder(decoder: Decoder, path: String, progress value: Double) {
            progress.update(value, path)
            if progress.isCancelled { try? decoder.abort() }
        }
    }

    private static func extract7z(_ url: URL, to root: URL, password: String?, progress: ExtractProgress) throws {
        let pw = (password?.isEmpty ?? true) ? nil : password
        let delegate = SevenZipDelegate(progress)
        let decoder: Decoder
        do {
            decoder = try Decoder(stream: try InStream(path: Path(url.path)), fileType: .sevenZ, delegate: delegate)
            try decoder.setPassword(pw)
        } catch {
            throw ArchiveExtractError.corrupted("\(error)")
        }
        let opened = (try? decoder.open()) ?? false
        guard opened else {
            // Header-encrypted archives cannot even be listed without the right password.
            throw pw == nil ? ArchiveExtractError.needsPassword : ArchiveExtractError.wrongPassword
        }
        let items = try decoder.items()
        var anyEncrypted = false
        for i in 0..<items.count {
            let item = try items.item(at: i)
            let path = try item.path().description
            if safeURL(root: root, entryPath: path) == nil && !path.isEmpty {
                throw ArchiveExtractError.corrupted("包含不安全的路径: \(path)")
            }
            if item.encrypted { anyEncrypted = true }
        }
        if anyEncrypted && pw == nil { throw ArchiveExtractError.needsPassword }
        let ok: Bool
        do { ok = try decoder.extract(to: Path(root.path)) } catch {
            if progress.isCancelled { throw ArchiveExtractError.cancelled }
            throw anyEncrypted ? ArchiveExtractError.wrongPassword : ArchiveExtractError.corrupted("\(error)")
        }
        if progress.isCancelled { throw ArchiveExtractError.cancelled }
        if !ok { throw anyEncrypted ? ArchiveExtractError.wrongPassword : ArchiveExtractError.corrupted("7z") }
    }
}

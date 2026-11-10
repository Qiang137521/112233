import Foundation

/// Maps the torrent's contiguous byte space onto files on disk.
final class TorrentStorage {
    let info: TorrentInfo
    let root: URL
    private var handles: [Int: FileHandle] = [:]

    init(info: TorrentInfo, downloadDirectory: URL) {
        self.info = info
        self.root = downloadDirectory
    }

    deinit { closeAll() }

    func url(forFile index: Int) -> URL {
        var u = root
        if info.isMultiFile { u.appendPathComponent(info.name, isDirectory: true) }
        for c in info.files[index].path { u.appendPathComponent(c) }
        return u
    }

    /// Top-level item (folder or single file) of the torrent on disk.
    var contentURL: URL { root.appendingPathComponent(info.name, isDirectory: info.isMultiFile) }

    private func handle(forFile index: Int) throws -> FileHandle {
        if let h = handles[index] { return h }
        let u = url(forFile: index)
        let fm = FileManager.default
        if !fm.fileExists(atPath: u.path) {
            try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard fm.createFile(atPath: u.path, contents: nil) else { throw TorrentError.io("无法创建 \(u.lastPathComponent)") }
        }
        let h = try FileHandle(forUpdating: u)
        if handles.count > 64 { closeAll() }
        handles[index] = h
        return h
    }

    func closeAll() {
        for h in handles.values { try? h.close() }
        handles.removeAll()
    }

    /// Calls `body` for every (file, offset-in-file, range-in-buffer) touched by [offset, offset+length).
    private func forEachSegment(offset: Int64, length: Int, _ body: (Int, Int64, Range<Int>) throws -> Void) rethrows {
        var remaining = Int64(length)
        var pos = offset
        var bufPos = 0
        // Binary search the first file containing `pos`.
        var lo = 0, hi = info.files.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if info.files[mid].offset <= pos { lo = mid } else { hi = mid - 1 }
        }
        var i = lo
        while remaining > 0 && i < info.files.count {
            let f = info.files[i]
            let fileEnd = f.offset + f.length
            if f.length > 0 && pos >= f.offset && pos < fileEnd {
                let n = min(remaining, fileEnd - pos)
                try body(i, pos - f.offset, bufPos..<(bufPos + Int(n)))
                pos += n
                bufPos += Int(n)
                remaining -= n
            }
            i += 1
        }
    }

    func write(piece index: Int, data: Data) throws {
        let offset = Int64(index) * Int64(info.pieceLength)
        try forEachSegment(offset: offset, length: data.count) { file, fileOffset, range in
            if info.isPadding(file) { return }
            let h = try handle(forFile: file)
            try h.seek(toOffset: UInt64(fileOffset))
            try h.write(contentsOf: data.subdata(in: (data.startIndex + range.lowerBound)..<(data.startIndex + range.upperBound)))
        }
    }

    func read(offset: Int64, length: Int) throws -> Data {
        var out = Data(count: length)
        try forEachSegment(offset: offset, length: length) { file, fileOffset, range in
            if info.isPadding(file) { return }
            let h = try handle(forFile: file)
            try h.seek(toOffset: UInt64(fileOffset))
            let chunk = try h.read(upToCount: range.count) ?? Data()
            out.replaceSubrange(range.lowerBound..<(range.lowerBound + chunk.count), with: chunk)
        }
        return out
    }

    func readPiece(_ index: Int) throws -> Data {
        try read(offset: Int64(index) * Int64(info.pieceLength), length: info.length(ofPiece: index))
    }

    /// Ensures each selected file exists with its final size (so players see the right length).
    func truncateToFinalSizes(selected: [Bool]) {
        for (i, f) in info.files.enumerated() where selected[i] && !info.isPadding(i) {
            if let h = try? handle(forFile: i) {
                if let end = try? h.seekToEnd(), end != UInt64(f.length) { try? h.truncate(atOffset: UInt64(f.length)) }
            }
        }
    }
}

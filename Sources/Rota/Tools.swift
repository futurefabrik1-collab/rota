import Foundation
import UniformTypeIdentifiers

struct WheelError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

/// A result that isn't a failure but produced nothing (e.g. already smaller).
struct Skipped: LocalizedError {
    let reason: String
    var errorDescription: String? { reason }
}

enum Tools {
    static let searchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]

    static func path(_ tool: String) throws -> String {
        for dir in searchPaths {
            let p = "\(dir)/\(tool)"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        throw WheelError("\(tool) not found — install it with: brew install \(tool == "cwebp" ? "webp" : tool)")
    }

    static func has(_ tool: String) -> Bool { (try? path(tool)) != nil }

    /// Runs a tool, returns its exit status. Throws on non-zero unless `allow` contains it.
    @discardableResult
    static func run(_ tool: String, _ args: [String], cwd: URL? = nil, allow: Set<Int32> = []) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: try path(tool))
        p.arguments = args
        if let cwd { p.currentDirectoryURL = cwd }
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        try p.run()
        let data = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let status = p.terminationStatus
        if status != 0 && !allow.contains(status) {
            let msg = String(decoding: data, as: UTF8.self)
                .split(separator: "\n").suffix(3).joined(separator: " ")
            throw WheelError("\(tool) failed (\(status)): \(msg)")
        }
        return status
    }

    static func ffmpeg(_ input: URL, _ args: [String], _ out: URL) throws {
        do {
            try run("ffmpeg", ["-nostdin", "-hide_banner", "-loglevel", "error", "-i", input.path] + args + [out.path])
        } catch {
            try? FileManager.default.removeItem(at: out)
            throw error
        }
    }
}

enum Out {
    /// `name.ext` beside the source; `name (suffix).ext` when a suffix is given; never overwrites.
    static func url(for src: URL, ext: String, suffix: String? = nil, dir: URL? = nil) -> URL {
        let folder = dir ?? src.deletingLastPathComponent()
        let base = src.deletingPathExtension().lastPathComponent + (suffix.map { " (\($0))" } ?? "")
        return unique(folder, base, ext)
    }

    static func unique(_ dir: URL, _ base: String, _ ext: String) -> URL {
        let fm = FileManager.default
        func make(_ b: String) -> URL {
            ext.isEmpty ? dir.appendingPathComponent(b) : dir.appendingPathComponent(b).appendingPathExtension(ext)
        }
        var u = make(base)
        var n = 2
        while fm.fileExists(atPath: u.path) {
            u = make("\(base) \(n)")
            n += 1
        }
        return u
    }

    static func size(_ u: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? Int64) ?? 0
    }

    static func temp(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("rota-\(UUID().uuidString)").appendingPathExtension(ext)
    }

    /// Deletes `out` and throws Skipped if it isn't smaller than `src`.
    static func requireSmaller(_ out: URL, than src: URL) throws {
        if size(out) >= size(src) {
            try? FileManager.default.removeItem(at: out)
            throw Skipped(reason: "\(src.lastPathComponent) is already as small as it gets")
        }
    }
}

enum Log {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Rota.log")

    static func write(_ s: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

enum Kind: String, CaseIterable { case image, video, audio, pdf, document, slides, sheet, archive, other }

extension URL {
    static let docExts: Set<String> = ["docx", "doc", "rtf", "rtfd", "txt", "text", "md", "markdown", "html", "htm", "odt", "pages", "webarchive"]
    static let slideExts: Set<String> = ["pptx", "ppt", "key", "odp"]
    static let sheetExts: Set<String> = ["xlsx", "xls", "csv", "tsv", "numbers", "ods"]
    static let archiveExts: Set<String> = ["zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar"]

    var fileKind: Kind {
        let e = pathExtension.lowercased()
        // iWork documents are packages; classify them before the folder check.
        if Self.docExts.contains(e) { return .document }
        if Self.slideExts.contains(e) { return .slides }
        if Self.sheetExts.contains(e) { return .sheet }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue { return .other }
        if Self.archiveExts.contains(e) { return .archive }
        guard let t = UTType(filenameExtension: e) else { return .other }
        if t.conforms(to: .pdf) { return .pdf }
        if t.conforms(to: .image) { return .image }
        if t.conforms(to: .movie) || t.conforms(to: .video) { return .video }
        if t.conforms(to: .audio) { return .audio }
        return .other
    }
    var ext: String { pathExtension.lowercased() }
}

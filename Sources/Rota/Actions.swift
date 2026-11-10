import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers

struct Action {
    let id: String
    let title: String
    let symbol: String
    let detail: String
    let kinds: Set<Kind>
    /// Extensions for which this action is pointless (e.g. JPEG → JPEG).
    var hideFor: Set<String> = []
    var minFiles = 1
    /// Batch actions get all files at once; others run per file.
    var batch: (([URL]) throws -> [URL])? = nil
    var each: ((URL) throws -> [URL])? = nil
    /// UI actions (pickers, AirDrop) must run on the main thread.
    var onMain = false
}

// MARK: - Implementations

enum Probe {
    static func sampleRate(_ u: URL) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: try Tools.path("ffprobe"))
        p.arguments = ["-v", "error", "-select_streams", "a:0", "-show_entries", "stream=sample_rate",
                       "-of", "default=nw=1:nk=1", u.path]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        let s = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard Int(s) != nil else { throw WheelError("no sample rate") }
        return s
    }
}

enum Img {
    static func source(_ u: URL) throws -> CGImageSource {
        guard let s = CGImageSourceCreateWithURL(u as CFURL, nil), CGImageSourceGetCount(s) > 0 else {
            throw WheelError("Can't read \(u.lastPathComponent)")
        }
        return s
    }

    static func write(_ img: CGImage, props: [CFString: Any], to out: URL, type: UTType, quality: Double?) throws {
        if type == .webP {
            let tmp = Out.temp("png")
            defer { try? FileManager.default.removeItem(at: tmp) }
            try write(img, props: props, to: tmp, type: .png, quality: nil)
            try Tools.run("cwebp", ["-quiet", "-q", "\(Int((quality ?? 0.82) * 100))", "-metadata", "icc",
                                    tmp.path, "-o", out.path])
            return
        }
        guard let d = CGImageDestinationCreateWithURL(out as CFURL, type.identifier as CFString, 1, nil) else {
            throw WheelError("Can't write \(type.preferredFilenameExtension ?? "image")")
        }
        var opts = props
        if let q = quality { opts[kCGImageDestinationLossyCompressionQuality] = q }
        CGImageDestinationAddImage(d, img, opts as CFDictionary)
        guard CGImageDestinationFinalize(d) else {
            try? FileManager.default.removeItem(at: out)
            throw WheelError("Couldn't encode \(out.lastPathComponent)")
        }
    }

    static func props(_ s: CGImageSource) -> [CFString: Any] {
        (CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as? [CFString: Any]) ?? [:]
    }

    static func convert(_ src: URL, to type: UTType, ext: String, quality: Double?) throws -> [URL] {
        let s = try source(src)
        guard let img = CGImageSourceCreateImageAtIndex(s, 0, nil) else { throw WheelError("Can't decode \(src.lastPathComponent)") }
        let out = Out.url(for: src, ext: ext)
        var p = props(s)
        if type == .jpeg, img.alphaInfo != .none, img.alphaInfo != .noneSkipFirst, img.alphaInfo != .noneSkipLast {
            // JPEG has no alpha; flatten onto white instead of black.
            try write(flatten(img), props: p, to: out, type: type, quality: quality)
            return [out]
        }
        p[kCGImagePropertyHasAlpha] = nil
        try write(img, props: p, to: out, type: type, quality: quality)
        return [out]
    }

    static func flatten(_ img: CGImage) throws -> CGImage {
        guard let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw WheelError("Out of memory") }
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: img.width, height: img.height))
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        guard let o = ctx.makeImage() else { throw WheelError("Out of memory") }
        return o
    }

    static func compress(_ src: URL) throws -> [URL] {
        let s = try source(src)
        let e = src.ext
        let out: URL
        switch e {
        case "png":
            out = Out.url(for: src, ext: "png", suffix: "compressed")
            let st = try Tools.run("pngquant", ["--quality=60-90", "--skip-if-larger", "--output", out.path, "--", src.path],
                                   allow: [98, 99])
            if st != 0 { throw Skipped(reason: "\(src.lastPathComponent) is already well compressed") }
        case "webp":
            out = Out.url(for: src, ext: "webp", suffix: "compressed")
            try Tools.run("cwebp", ["-quiet", "-q", "60", "-metadata", "icc", src.path, "-o", out.path])
        default:
            let heic = ["heic", "heif"].contains(e)
            out = Out.url(for: src, ext: heic ? "heic" : "jpg", suffix: "compressed")
            guard let img = CGImageSourceCreateImageAtIndex(s, 0, nil) else { throw WheelError("Can't decode") }
            let flat = heic ? img : try flatten(img)
            try write(flat, props: props(s), to: out, type: heic ? .heic : .jpeg, quality: 0.6)
        }
        try Out.requireSmaller(out, than: src)
        return [out]
    }

    static func resize(_ src: URL, maxEdge: Int?, scale: Double?) throws -> [URL] {
        let s = try source(src)
        let p = props(s)
        let w = p[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = p[kCGImagePropertyPixelHeight] as? Int ?? 0
        let long = max(w, h)
        let target = maxEdge ?? Int(Double(long) * (scale ?? 1))
        guard target > 0 else { throw WheelError("Unknown image size") }
        if let maxEdge, long <= maxEdge { throw Skipped(reason: "\(src.lastPathComponent) is already ≤ \(maxEdge) px") }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: target,
        ]
        guard let img = CGImageSourceCreateThumbnailAtIndex(s, 0, opts as CFDictionary) else { throw WheelError("Can't resize") }
        var outProps = p
        outProps[kCGImagePropertyOrientation] = 1  // transform already applied
        outProps[kCGImagePropertyPixelWidth] = nil
        outProps[kCGImagePropertyPixelHeight] = nil
        if var tiff = outProps[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1; outProps[kCGImagePropertyTIFFDictionary] = tiff
        }
        let (type, ext) = writable(src)
        let out = Out.url(for: src, ext: ext, suffix: maxEdge.map { "\($0)px" } ?? "\(img.width)×\(img.height)")
        try write(img, props: outProps, to: out, type: type, quality: type == .png ? nil : 0.88)
        return [out]
    }

    /// Same format as the source where we can write it, else PNG.
    static func writable(_ src: URL) -> (UTType, String) {
        switch src.ext {
        case "jpg", "jpeg": return (.jpeg, src.ext)
        case "heic", "heif": return (.heic, "heic")
        case "webp": return (.webP, "webp")
        case "tif", "tiff": return (.tiff, src.ext)
        default: return (.png, "png")
        }
    }

    static func strip(_ src: URL) throws -> [URL] {
        let s = try source(src)
        if src.ext == "webp" {
            let out = Out.url(for: src, ext: "webp", suffix: "clean")
            try Tools.run("cwebp", ["-quiet", "-lossless", "-metadata", "icc", src.path, "-o", out.path])
            return [out]
        }
        guard let type = CGImageSourceGetType(s) else { throw WheelError("Unknown image type") }
        let out = Out.url(for: src, ext: src.ext, suffix: "clean")
        guard let d = CGImageDestinationCreateWithURL(out as CFURL, type, 1, nil) else { throw WheelError("Can't write") }
        // Lossless copy (no re-encode) with all metadata replaced by an empty set.
        let opts: [CFString: Any] = [
            kCGImageDestinationMetadata: CGImageMetadataCreateMutable(),
            kCGImageDestinationMergeMetadata: false,
            kCGImageMetadataShouldExcludeGPS: true,
            kCGImageMetadataShouldExcludeXMP: true,
        ]
        var err: Unmanaged<CFError>?
        if !CGImageDestinationCopyImageSource(d, s, opts as CFDictionary, &err) {
            // Formats without lossless copy support: re-encode, dropping properties.
            guard let img = CGImageSourceCreateImageAtIndex(s, 0, nil),
                  let d2 = CGImageDestinationCreateWithURL(out as CFURL, type, 1, nil) else { throw WheelError("Can't decode") }
            let o = props(s)[kCGImagePropertyOrientation].map { [kCGImagePropertyOrientation: $0] } ?? [:]
            CGImageDestinationAddImage(d2, img, o as CFDictionary)
            guard CGImageDestinationFinalize(d2) else { throw WheelError("Couldn't write \(out.lastPathComponent)") }
        }
        return [out]
    }

    static func toPDF(_ urls: [URL]) throws -> [URL] {
        let doc = PDFDocument()
        for u in urls.sorted(by: Finder.order) {
            let s = try source(u)
            let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                         kCGImageSourceCreateThumbnailWithTransform: true,
                                         kCGImageSourceThumbnailMaxPixelSize: 100_000]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(s, 0, opts as CFDictionary) else { continue }
            let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            if let page = PDFPage(image: img) { doc.insert(page, at: doc.pageCount) }
        }
        guard doc.pageCount > 0, let first = urls.sorted(by: Finder.order).first else { throw WheelError("No readable images") }
        let out = Out.url(for: first, ext: "pdf", suffix: urls.count > 1 ? "combined" : nil)
        guard doc.write(to: out) else { throw WheelError("Couldn't write PDF") }
        return [out]
    }
}

enum PDFOps {
    static func pages(_ src: URL, type: UTType, ext: String) throws -> [URL] {
        guard let doc = CGPDFDocument(src as CFURL), doc.numberOfPages > 0 else {
            throw WheelError("\(src.lastPathComponent) can't be read (password-protected?)")
        }
        let n = doc.numberOfPages
        let base = src.deletingPathExtension().lastPathComponent
        let dir: URL
        if n == 1 {
            dir = src.deletingLastPathComponent()
        } else {
            dir = Out.unique(src.deletingLastPathComponent(), "\(base) (pages)", "")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let scale: CGFloat = 2  // 144 dpi
        var outs: [URL] = []
        for i in 1...n {
            guard let page = doc.page(at: i) else { continue }
            let box = page.getBoxRect(.cropBox)
            let rotated = page.rotationAngle % 180 != 0
            let size = rotated ? CGSize(width: box.height, height: box.width) : box.size
            let w = Int(size.width * scale), h = Int(size.height * scale)
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw WheelError("Page too large") }
            ctx.setFillColor(.white)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.interpolationQuality = .high
            ctx.scaleBy(x: scale, y: scale)
            ctx.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size),
                                                     rotate: 0, preserveAspectRatio: true))
            ctx.drawPDFPage(page)
            guard let img = ctx.makeImage() else { continue }
            let name = n == 1 ? base : String(format: "%@-%03d", base, i)
            let out = Out.unique(dir, name, ext)
            try Img.write(img, props: [:], to: out, type: type, quality: type == .jpeg ? 0.9 : nil)
            outs.append(out)
        }
        return n == 1 ? outs : [dir]
    }

    static func compress(_ src: URL) throws -> [URL] {
        guard let doc = PDFDocument(url: src) else { throw WheelError("Can't open \(src.lastPathComponent)") }
        if doc.isLocked { throw WheelError("\(src.lastPathComponent) is password-protected") }
        let out = Out.url(for: src, ext: "pdf", suffix: "compressed")
        let ok = doc.write(to: out, withOptions: [.saveImagesAsJPEGOption: true, .optimizeImagesForScreenOption: true])
        guard ok else { throw WheelError("Couldn't write compressed PDF") }
        try Out.requireSmaller(out, than: src)
        return [out]
    }

    static func merge(_ urls: [URL]) throws -> [URL] {
        let sorted = urls.sorted(by: Finder.order)
        let doc = PDFDocument()
        for u in sorted {
            guard let d = PDFDocument(url: u), !d.isLocked else { throw WheelError("Can't open \(u.lastPathComponent)") }
            for i in 0..<d.pageCount { if let p = d.page(at: i) { doc.insert(p, at: doc.pageCount) } }
        }
        let out = Out.url(for: sorted[0], ext: "pdf", suffix: "merged")
        guard doc.write(to: out) else { throw WheelError("Couldn't write merged PDF") }
        return [out]
    }

    static func strip(_ src: URL) throws -> [URL] {
        guard let doc = PDFDocument(url: src) else { throw WheelError("Can't open \(src.lastPathComponent)") }
        doc.documentAttributes = [:]
        let out = Out.url(for: src, ext: "pdf", suffix: "clean")
        guard doc.write(to: out) else { throw WheelError("Couldn't write PDF") }
        return [out]
    }
}

enum Archive {
    static func zip(_ urls: [URL]) throws -> [URL] {
        let sorted = urls.sorted(by: Finder.order)
        let parent = sorted[0].deletingLastPathComponent()
        if sorted.count == 1 {
            let src = sorted[0]
            let out = Out.unique(parent, src.lastPathComponent, "zip")
            try Tools.run("ditto", ["-c", "-k", "--norsrc", "--noextattr", "--noqtn", "--keepParent", src.path, out.path])
            return [out]
        }
        let out = Out.unique(parent, "Archive", "zip")
        let sameParent = sorted.allSatisfy { $0.deletingLastPathComponent() == parent }
        let names = sameParent ? sorted.map(\.lastPathComponent) : sorted.map(\.path)
        try Tools.run("zip", ["-r", "-q", "-y", out.path] + names + ["-x", "*.DS_Store", "__MACOSX/*"], cwd: parent)
        return [out]
    }
}

/// Not a failure: a message to show instead of a file result.
struct Notice: LocalizedError {
    let text: String
    var errorDescription: String? { text }
}

enum FileOps {
    static func copyPaths(_ urls: [URL]) throws -> [URL] {
        let paths = urls.map(\.path).joined(separator: "\n")
        let put = {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(paths, forType: .string)
        }
        if Thread.isMainThread { put() } else { DispatchQueue.main.sync(execute: put) }
        throw Notice(text: urls.count == 1 ? "Copied path" : "Copied \(urls.count) paths")
    }

    static func terminal(_ urls: [URL]) throws -> [URL] {
        let u = urls[0]
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir)
        let dir = isDir.boolValue && u.pathExtension.isEmpty ? u : u.deletingLastPathComponent()
        try Tools.run("open", ["-a", "Terminal", dir.path])
        throw Notice(text: "Terminal opened in \(dir.lastPathComponent)")
    }

    static func airdrop(_ urls: [URL]) throws -> [URL] {
        guard let s = NSSharingService(named: .sendViaAirDrop), s.canPerform(withItems: urls) else {
            throw WheelError("AirDrop isn't available")
        }
        NSApp.activate(ignoringOtherApps: true)
        s.perform(withItems: urls)
        throw Notice(text: "AirDrop…")
    }

    static func transfer(_ urls: [URL], move: Bool) throws -> [URL] {
        NSApp.activate(ignoringOtherApps: true)
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.prompt = move ? "Move Here" : "Copy Here"
        p.message = "\(move ? "Move" : "Copy") \(urls.count) item\(urls.count == 1 ? "" : "s") to…"
        p.directoryURL = urls[0].deletingLastPathComponent()
        guard p.runModal() == .OK, let dest = p.url else { throw Notice(text: "Cancelled") }
        var outs: [URL] = []
        for u in urls {
            let target = Out.unique(dest, u.deletingPathExtension().lastPathComponent, u.pathExtension)
            if move { try FileManager.default.moveItem(at: u, to: target) }
            else { try FileManager.default.copyItem(at: u, to: target) }
            outs.append(target)
        }
        return outs
    }
}

enum Finder {
    static func order(_ a: URL, _ b: URL) -> Bool {
        a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending
    }
}

// MARK: - Runner

enum Runner {
    struct Report { var outputs: [URL] = []; var skipped: [String] = []; var errors: [String] = []; var notes: [String] = [] }

    static func run(_ a: Action, _ urls: [URL], progress: ((Int, Int) -> Void)? = nil) -> Report {
        var r = Report()
        func record(_ body: () throws -> [URL], _ label: String) {
            do { r.outputs += try body() }
            catch let s as Skipped { r.skipped.append(s.reason) }
            catch let n as Notice { r.notes.append(n.text) }
            catch { r.errors.append("\(label): \(error.localizedDescription)") }
        }
        if let batch = a.batch {
            progress?(0, 1)
            record({ try batch(urls) }, a.title)
        } else if let each = a.each {
            for (i, u) in urls.enumerated() {
                progress?(i, urls.count)
                record({ try each(u) }, u.lastPathComponent)
            }
        }
        Log.write("\(a.id) on \(urls.count) file(s): \(r.outputs.count) out, \(r.skipped.count) skipped, \(r.errors.count) errors")
        r.errors.forEach { Log.write("  error: \($0)") }
        r.skipped.forEach { Log.write("  skipped: \($0)") }
        return r
    }
}

import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import Vision

// MARK: - Probing

extension Probe {
    static func stdout(_ args: [String], _ u: URL) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: try Tools.path("ffprobe"))
        p.arguments = ["-v", "error"] + args + [u.path]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        try p.run()
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func duration(_ u: URL) throws -> Double {
        guard let d = Double(try stdout(["-show_entries", "format=duration", "-of", "default=nw=1:nk=1"], u)), d > 0 else {
            throw WheelError("Can't read the duration of \(u.lastPathComponent)")
        }
        return d
    }
    static func hasAudio(_ u: URL) -> Bool {
        !((try? stdout(["-select_streams", "a", "-show_entries", "stream=index", "-of", "csv=p=0"], u)) ?? "").isEmpty
    }
}

/// Runs a throwing block on the main thread (AppKit text import needs it).
func onMain<T>(_ f: () throws -> T) rethrows -> T {
    Thread.isMainThread ? try f() : try DispatchQueue.main.sync(execute: f)
}

// MARK: - Images

enum ImgX {
    static let ctx = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])

    static func ciImage(_ src: URL) throws -> CIImage {
        guard let i = CIImage(contentsOf: src, options: [.applyOrientationProperty: true]) else {
            throw WheelError("Can't read \(src.lastPathComponent)")
        }
        return i
    }

    /// Source metadata without orientation/size (pixels are already upright).
    static func cleanProps(_ src: URL) -> [CFString: Any] {
        guard let s = CGImageSourceCreateWithURL(src as CFURL, nil) else { return [:] }
        var p = Img.props(s)
        p[kCGImagePropertyOrientation] = 1
        p[kCGImagePropertyPixelWidth] = nil
        p[kCGImagePropertyPixelHeight] = nil
        if var tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1; p[kCGImagePropertyTIFFDictionary] = tiff
        }
        return p
    }

    static func save(_ img: CIImage, from src: URL, suffix: String, forcePNG: Bool = false, forceJPEG: Bool = false) throws -> [URL] {
        let e = img.extent.integral
        let moved = img.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
        guard let cg = ctx.createCGImage(moved, from: CGRect(origin: .zero, size: e.size), format: .RGBA8,
                                         colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else {
            throw WheelError("Couldn't render \(src.lastPathComponent)")
        }
        let (type, ext) = forcePNG ? (UTType.png, "png") : forceJPEG ? (UTType.jpeg, "jpg") : Img.writable(src)
        let out = Out.url(for: src, ext: ext, suffix: suffix)
        let final = type == .jpeg ? try Img.flatten(cg) : cg
        try Img.write(final, props: cleanProps(src), to: out, type: type, quality: type == .png ? nil : 0.9)
        return [out]
    }

    static func rotate(_ src: URL) throws -> [URL] {
        try save(try ciImage(src).transformed(by: CGAffineTransform(rotationAngle: -.pi / 2)), from: src, suffix: "rotated")
    }

    static func flip(_ src: URL) throws -> [URL] {
        try save(try ciImage(src).transformed(by: CGAffineTransform(scaleX: -1, y: 1)), from: src, suffix: "flipped")
    }

    static func mono(_ src: URL) throws -> [URL] {
        let f = CIFilter.photoEffectMono()
        f.inputImage = try ciImage(src)
        guard let o = f.outputImage else { throw WheelError("Filter failed") }
        return try save(o, from: src, suffix: "b&w")
    }

    /// Aspect-fill crop to an exact canvas (social presets).
    static func canvas(_ src: URL, _ w: CGFloat, _ h: CGFloat) throws -> [URL] {
        let i = try ciImage(src)
        let s = max(w / i.extent.width, h / i.extent.height)
        let scaled = i.transformed(by: CGAffineTransform(scaleX: s, y: s))
        let e = scaled.extent
        let crop = CGRect(x: e.midX - w / 2, y: e.midY - h / 2, width: w, height: h)
        return try save(scaled.cropped(to: crop), from: src, suffix: "\(Int(w))×\(Int(h))")
    }

    /// Social preset: exact canvas, cropped to fill or fitted over a blurred copy (menu setting).
    static func social(_ src: URL, _ w: CGFloat, _ h: CGFloat) throws -> [URL] {
        let i = try ciImage(src)
        let iw = i.extent.width, ih = i.extent.height
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        func placed(_ s: CGFloat) -> CIImage {
            let sc = i.transformed(by: CGAffineTransform(scaleX: s, y: s))
            let e = sc.extent
            return sc.transformed(by: CGAffineTransform(translationX: (w - e.width) / 2 - e.minX, y: (h - e.height) / 2 - e.minY))
        }
        let fill = max(w / iw, h / ih), fit = min(w / iw, h / ih)
        let out: CIImage
        if !Social.blurFit || abs(fill - fit) / fill < 0.02 {
            out = placed(fill).cropped(to: rect)
        } else {
            let dim = CIFilter.colorControls()
            dim.inputImage = placed(fill).clampedToExtent().applyingGaussianBlur(sigma: 45)
            dim.brightness = -0.06
            dim.saturation = 1.1
            out = placed(fit).composited(over: dim.outputImage!.cropped(to: rect)).cropped(to: rect)
        }
        return try save(out, from: src, suffix: "\(Int(w))×\(Int(h))", forceJPEG: true)
    }

    /// The source fitted, centred and padded onto a transparent square.
    static func squareCG(_ src: URL, side: Int) throws -> CGImage {
        let i = try ciImage(src)
        let target = CGFloat(side)
        let s = target / max(i.extent.width, i.extent.height)
        let scaled = i.transformed(by: CGAffineTransform(scaleX: s, y: s))
        let e = scaled.extent
        let centred = scaled.transformed(by: CGAffineTransform(translationX: (target - e.width) / 2 - e.minX,
                                                               y: (target - e.height) / 2 - e.minY))
        let rect = CGRect(x: 0, y: 0, width: target, height: target)
        guard let cg = ctx.createCGImage(centred.composited(over: CIImage(color: .clear).cropped(to: rect)), from: rect,
                                         format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else {
            throw WheelError("Render failed")
        }
        return cg
    }

    static func scaled(_ cg: CGImage, _ px: Int) -> CGImage? {
        guard let c = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        c.interpolationQuality = .high
        c.draw(cg, in: CGRect(x: 0, y: 0, width: px, height: px))
        return c.makeImage()
    }

    /// A ready-to-upload favicon folder: multi-size favicon.ico, PNGs for browsers, Apple and Android,
    /// a web manifest and the <head> snippet.
    static func favicon(_ src: URL) throws -> [URL] {
        let master = try squareCG(src, side: 512)
        let base = src.deletingPathExtension().lastPathComponent
        let dir = Out.unique(src.deletingLastPathComponent(), "\(base) (favicon)", "")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let ico = dir.appendingPathComponent("favicon.ico")
        guard let d = CGImageDestinationCreateWithURL(ico as CFURL, "com.microsoft.ico" as CFString, 3, nil) else {
            throw WheelError("Can't write favicon.ico")
        }
        for px in [16, 32, 48] { if let img = scaled(master, px) { CGImageDestinationAddImage(d, img, nil) } }
        guard CGImageDestinationFinalize(d) else { throw WheelError("Couldn't encode favicon.ico") }

        for (name, px) in [("favicon-16x16", 16), ("favicon-32x32", 32), ("apple-touch-icon", 180),
                           ("android-chrome-192x192", 192), ("android-chrome-512x512", 512)] {
            guard var img = scaled(master, px) else { continue }
            if name == "apple-touch-icon" { img = try Img.flatten(img) }  // iOS shows transparency as black
            try Img.write(img, props: [:], to: dir.appendingPathComponent("\(name).png"), type: .png, quality: nil)
        }

        let manifest = """
        {
          "name": "",
          "short_name": "",
          "icons": [
            { "src": "/android-chrome-192x192.png", "sizes": "192x192", "type": "image/png" },
            { "src": "/android-chrome-512x512.png", "sizes": "512x512", "type": "image/png" }
          ],
          "theme_color": "#ffffff",
          "background_color": "#ffffff",
          "display": "standalone"
        }

        """
        try manifest.write(to: dir.appendingPathComponent("site.webmanifest"), atomically: true, encoding: .utf8)
        let head = """
        <link rel="icon" href="/favicon.ico" sizes="48x48">
        <link rel="icon" type="image/png" sizes="32x32" href="/favicon-32x32.png">
        <link rel="icon" type="image/png" sizes="16x16" href="/favicon-16x16.png">
        <link rel="apple-touch-icon" sizes="180x180" href="/apple-touch-icon.png">
        <link rel="manifest" href="/site.webmanifest">

        """
        try head.write(to: dir.appendingPathComponent("head-snippet.html"), atomically: true, encoding: .utf8)
        return [dir]
    }

    static func icon(_ src: URL, type: UTType, ext: String, side: Int) throws -> [URL] {
        let i = try ciImage(src)
        let longest = max(i.extent.width, i.extent.height)
        let target = CGFloat(side)
        let s = target / longest
        let scaled = i.transformed(by: CGAffineTransform(scaleX: s, y: s))
        let e = scaled.extent
        let centred = scaled.transformed(by: CGAffineTransform(translationX: (target - e.width) / 2 - e.minX,
                                                               y: (target - e.height) / 2 - e.minY))
        let square = centred.composited(over: CIImage(color: .clear).cropped(to: CGRect(x: 0, y: 0, width: target, height: target)))
        guard let cg = ctx.createCGImage(square, from: CGRect(x: 0, y: 0, width: target, height: target), format: .RGBA8,
                                         colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else { throw WheelError("Render failed") }
        let out = Out.url(for: src, ext: ext)
        guard type == .icns else {
            try Img.write(cg, props: [:], to: out, type: type, quality: nil)
            return [out]
        }
        // ICNS: build a full .iconset (16–1024 px) and let iconutil pack it.
        let set = FileManager.default.temporaryDirectory.appendingPathComponent("filewheel-\(UUID().uuidString).iconset")
        try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: set) }
        for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                           ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
            guard let c = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
            c.interpolationQuality = .high
            c.draw(cg, in: CGRect(x: 0, y: 0, width: px, height: px))
            if let img = c.makeImage() {
                try Img.write(img, props: [:], to: set.appendingPathComponent("icon_\(name).png"), type: .png, quality: nil)
            }
        }
        try Tools.run("iconutil", ["-c", "icns", set.path, "-o", out.path])
        return [out]
    }

    private static func handler(_ src: URL) throws -> (VNImageRequestHandler, CGImage) {
        guard let s = CGImageSourceCreateWithURL(src as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(s, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 8192] as CFDictionary) else {
            throw WheelError("Can't read \(src.lastPathComponent)")
        }
        return (VNImageRequestHandler(cgImage: cg, options: [:]), cg)
    }

    static func removeBackground(_ src: URL) throws -> [URL] {
        let (h, _) = try handler(src)
        let req = VNGenerateForegroundInstanceMaskRequest()
        try h.perform([req])
        guard let r = req.results?.first, !r.allInstances.isEmpty else {
            throw Skipped(reason: "No clear subject found in \(src.lastPathComponent)")
        }
        let buf = try r.generateMaskedImage(ofInstances: r.allInstances, from: h, croppedToInstancesExtent: false)
        return try save(CIImage(cvPixelBuffer: buf), from: src, suffix: "cutout", forcePNG: true)
    }

    static func ocr(_ src: URL) throws -> [URL] {
        let (h, _) = try handler(src)
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        req.automaticallyDetectsLanguage = true
        try h.perform([req])
        let text = (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        guard !text.isEmpty else { throw Skipped(reason: "No text found in \(src.lastPathComponent)") }
        let out = Out.url(for: src, ext: "txt")
        try text.write(to: out, atomically: true, encoding: .utf8)
        return [out]
    }

    static func readCodes(_ urls: [URL]) throws -> [URL] {
        var found: [String] = []
        for u in urls {
            let (h, _) = try handler(u)
            let req = VNDetectBarcodesRequest()
            try h.perform([req])
            found += (req.results ?? []).compactMap(\.payloadStringValue)
        }
        guard !found.isEmpty else { throw Skipped(reason: "No QR or barcodes found") }
        let text = found.joined(separator: "\n")
        onMain {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        let preview = found[0].count > 48 ? String(found[0].prefix(48)) + "…" : found[0]
        throw Notice(text: found.count == 1 ? "Copied: \(preview)" : "Copied \(found.count) codes")
    }

    static func collage(_ urls: [URL]) throws -> [URL] {
        let sorted = urls.sorted(by: Finder.order)
        let cols = Int(ceil(sqrt(Double(sorted.count))))
        let rows = Int(ceil(Double(sorted.count) / Double(cols)))
        let cell: CGFloat = 900, gap: CGFloat = 24
        let W = CGFloat(cols) * cell + CGFloat(cols + 1) * gap
        let H = CGFloat(rows) * cell + CGFloat(rows + 1) * gap
        guard let c = CGContext(data: nil, width: Int(W), height: Int(H), bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw WheelError("Collage too large") }
        c.setFillColor(.white)
        c.fill(CGRect(x: 0, y: 0, width: W, height: H))
        c.interpolationQuality = .high
        for (i, u) in sorted.enumerated() {
            guard let s = CGImageSourceCreateWithURL(u as CFURL, nil),
                  let img = CGImageSourceCreateThumbnailAtIndex(s, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: Int(cell)] as CFDictionary) else { continue }
            let col = i % cols, row = i / cols
            let x0 = gap + CGFloat(col) * (cell + gap)
            let y0 = H - gap - cell - CGFloat(row) * (cell + gap)
            let f = min(cell / CGFloat(img.width), cell / CGFloat(img.height))
            let w = CGFloat(img.width) * f, h = CGFloat(img.height) * f
            c.draw(img, in: CGRect(x: x0 + (cell - w) / 2, y: y0 + (cell - h) / 2, width: w, height: h))
        }
        guard let out = c.makeImage() else { throw WheelError("Collage failed") }
        let dest = Out.unique(sorted[0].deletingLastPathComponent(), "Collage", "jpg")
        try Img.write(out, props: [:], to: dest, type: .jpeg, quality: 0.9)
        return [dest]
    }
}

// MARK: - Audio / video

enum AV {
    /// Encoder arguments that keep the source's format.
    static func codec(for ext: String) -> [String] {
        switch ext {
        case "mp3": return ["-c:a", "libmp3lame", "-q:a", "2"]
        case "m4a", "aac", "mp4": return ["-c:a", "aac", "-b:a", "256k"]
        case "wav": return ["-c:a", "pcm_s24le"]
        case "aif", "aiff": return ["-c:a", "pcm_s24be"]
        case "flac": return ["-c:a", "flac"]
        case "opus", "ogg": return ["-c:a", "libopus", "-b:a", "160k"]
        default: return []
        }
    }

    static func speed(_ src: URL, _ factor: Double) throws -> [URL] {
        let o = Out.url(for: src, ext: "mp4", suffix: factor > 1 ? "2x" : "half speed")
        let pts = String(format: "%.3f", 1 / factor)
        var args: [String]
        if Probe.hasAudio(src) {
            args = ["-filter_complex", "[0:v]setpts=\(pts)*PTS[v];[0:a]atempo=\(factor)[a]", "-map", "[v]", "-map", "[a]"]
        } else {
            args = ["-vf", "setpts=\(pts)*PTS", "-an"]
        }
        try Tools.ffmpeg(src, args + Actions.h264, o)
        return [o]
    }

    /// Social preset video: exact frame size, H.264/AAC, cropped or fitted over a blurred copy.
    static func social(_ src: URL, _ w: Int, _ h: Int) throws -> [URL] {
        let o = Out.url(for: src, ext: "mp4", suffix: "\(w)×\(h)")
        let vf = Social.blurFit
            ? "split[a][b];[a]scale=\(w):\(h):force_original_aspect_ratio=increase,crop=\(w):\(h),boxblur=40:6,eq=brightness=-0.06[bg];"
              + "[b]scale=\(w):\(h):force_original_aspect_ratio=decrease:force_divisible_by=2[fg];[bg][fg]overlay=(W-w)/2:(H-h)/2,setsar=1"
            : "scale=\(w):\(h):force_original_aspect_ratio=increase,crop=\(w):\(h),setsar=1"
        try Tools.ffmpeg(src, ["-vf", vf, "-fpsmax", "60"] + Actions.h264, o)
        return [o]
    }

    static func frames(_ src: URL) throws -> [URL] {
        let base = src.deletingPathExtension().lastPathComponent
        let dir = Out.unique(src.deletingLastPathComponent(), "\(base) (frames)", "")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            try Tools.run("ffmpeg", ["-nostdin", "-hide_banner", "-loglevel", "error", "-i", src.path, "-vf", "fps=1",
                                     dir.appendingPathComponent("\(base)-%04d.png").path])
        } catch { try? FileManager.default.removeItem(at: dir); throw error }
        return [dir]
    }

    static func contactSheet(_ src: URL) throws -> [URL] {
        let d = try Probe.duration(src)
        let o = Out.url(for: src, ext: "jpg", suffix: "contact sheet")
        try Tools.ffmpeg(src, ["-vf", "fps=\(16 / d),scale=480:-2,tile=4x4:padding=8:margin=8:color=white",
                               "-frames:v", "1", "-q:v", "3"], o)
        return [o]
    }

    private static func concatList(_ urls: [URL]) throws -> URL {
        let list = Out.temp("txt")
        let body = urls.sorted(by: Finder.order)
            .map { "file '\($0.path.replacingOccurrences(of: "'", with: "'\\''"))'" }.joined(separator: "\n")
        try body.write(to: list, atomically: true, encoding: .utf8)
        return list
    }

    static func joinVideo(_ urls: [URL]) throws -> [URL] {
        let list = try concatList(urls)
        defer { try? FileManager.default.removeItem(at: list) }
        let first = urls.sorted(by: Finder.order)[0]
        let o = Out.url(for: first, ext: "mp4", suffix: "joined")
        try Tools.run("ffmpeg", ["-nostdin", "-hide_banner", "-loglevel", "error", "-f", "concat", "-safe", "0", "-i", list.path]
                      + Actions.h264 + [o.path])
        return [o]
    }

    static func joinAudio(_ urls: [URL]) throws -> [URL] {
        let list = try concatList(urls)
        defer { try? FileManager.default.removeItem(at: list) }
        let first = urls.sorted(by: Finder.order)[0]
        let o = Out.url(for: first, ext: first.ext, suffix: "joined")
        try Tools.run("ffmpeg", ["-nostdin", "-hide_banner", "-loglevel", "error", "-f", "concat", "-safe", "0", "-i", list.path,
                                 "-vn"] + codec(for: first.ext) + [o.path])
        return [o]
    }
}

// MARK: - PDF

enum PDFX {
    static func toPages(_ src: URL) throws -> [URL] {
        let tmp = Out.temp("docx")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try Doc.write(try attributed(src), type: .officeOpenXML, to: tmp)
        let out = Out.url(for: src, ext: "pages")
        try IWork.export("Pages", tmp, to: out, as: nil)
        return [out]
    }

    static func text(_ src: URL, type: NSAttributedString.DocumentType?, ext: String) throws -> [URL] {
        let out = Out.url(for: src, ext: ext)
        try Doc.write(try attributed(src), type: type, to: out)
        return [out]
    }

    static func attributed(_ src: URL) throws -> NSAttributedString {
        guard let d = PDFDocument(url: src) else { throw WheelError("Can't open \(src.lastPathComponent)") }
        if d.isLocked { throw WheelError("\(src.lastPathComponent) is password-protected") }
        let m = NSMutableAttributedString()
        for i in 0..<d.pageCount {
            if let a = d.page(at: i)?.attributedString, a.length > 0 {
                m.append(a)
                m.append(NSAttributedString(string: "\n\n"))
            }
        }
        guard m.string.contains(where: { !$0.isWhitespace }) else {
            throw Skipped(reason: "\(src.lastPathComponent) has no selectable text — run OCR first (Tools wheel)")
        }
        return m
    }

    static func gs(_ src: URL, suffix: String, _ extra: [String]) throws -> [URL] {
        let o = Out.url(for: src, ext: "pdf", suffix: suffix)
        do {
            try Tools.run("gs", ["-q", "-dNOPAUSE", "-dBATCH", "-dSAFER", "-sDEVICE=pdfwrite"] + extra
                          + ["-sOutputFile=\(o.path)", src.path])
        } catch { try? FileManager.default.removeItem(at: o); throw error }
        return [o]
    }

    static func compress(_ src: URL) throws -> [URL] {
        let outs = try gs(src, suffix: "compressed", ["-dPDFSETTINGS=/ebook", "-dCompatibilityLevel=1.6"])
        try Out.requireSmaller(outs[0], than: src)
        return outs
    }

    static func split(_ src: URL) throws -> [URL] {
        let base = src.deletingPathExtension().lastPathComponent
        let dir = Out.unique(src.deletingLastPathComponent(), "\(base) (pages)", "")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Tools.run("qpdf", ["--split-pages", src.path, dir.appendingPathComponent("\(base)-%d.pdf").path])
        return [dir]
    }

    static var ocrLangs: String = {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: (try? Tools.path("tesseract")) ?? "/usr/bin/false")
        p.arguments = ["--list-langs"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        try? p.run(); p.waitUntilExit()
        let have = Set(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n").map(String.init))
        return ["eng", "deu"].filter(have.contains).joined(separator: "+").ifEmpty("eng")
    }()

    static func ocr(_ src: URL) throws -> [URL] {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("filewheel-ocr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try Tools.run("gs", ["-q", "-dNOPAUSE", "-dBATCH", "-dSAFER", "-sDEVICE=png16m", "-r300",
                             "-sOutputFile=\(tmp.path)/p-%04d.png", src.path])
        let pages = try FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "png" }.sorted(by: Finder.order)
        guard !pages.isEmpty else { throw WheelError("No pages rendered") }
        let list = tmp.appendingPathComponent("list.txt")
        try pages.map(\.path).joined(separator: "\n").write(to: list, atomically: true, encoding: .utf8)
        let o = Out.url(for: src, ext: "pdf", suffix: "searchable")
        let base = o.deletingPathExtension()
        try Tools.run("tesseract", [list.path, base.path, "-l", ocrLangs, "pdf"])
        return [o]
    }
}

extension String {
    func ifEmpty(_ s: String) -> String { isEmpty ? s : self }
}

// MARK: - Documents

enum Doc {
    static let pagesOpens: Set<String> = ["pages", "docx", "doc", "rtf", "txt", "text"]

    static func load(_ src: URL) throws -> NSAttributedString {
        switch src.ext {
        case "md", "markdown":
            let html = Markdown.html(try String(contentsOf: src, encoding: .utf8))
            return try onMain {
                try NSAttributedString(data: Data(html.utf8), options: [
                    .documentType: NSAttributedString.DocumentType.html,
                    .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil)
            }
        case "pages":
            let tmp = Out.temp("docx")
            defer { try? FileManager.default.removeItem(at: tmp) }
            try IWork.export("Pages", src, to: tmp, as: "Microsoft Word")
            return try load(tmp)
        case "html", "htm", "webarchive":
            return try onMain { try NSAttributedString(url: src, options: [:], documentAttributes: nil) }
        default:
            return try NSAttributedString(url: src, options: [:], documentAttributes: nil)
        }
    }

    static func write(_ a: NSAttributedString, type: NSAttributedString.DocumentType?, to out: URL) throws {
        if let type {
            let d = try a.data(from: NSRange(location: 0, length: a.length), documentAttributes: [.documentType: type])
            try d.write(to: out)
        } else {
            try a.string.write(to: out, atomically: true, encoding: .utf8)
        }
    }

    static func convert(_ src: URL, type: NSAttributedString.DocumentType?, ext: String) throws -> [URL] {
        let out = Out.url(for: src, ext: ext)
        try write(try load(src), type: type, to: out)
        return [out]
    }

    /// PDF, EPUB or a native .pages file through Pages; formats Pages can't open go via a temporary .docx.
    static func viaPages(_ src: URL, format: String?, ext: String) throws -> [URL] {
        let out = Out.url(for: src, ext: ext)
        var input = src
        var tmp: URL?
        if !pagesOpens.contains(src.ext) {
            let t = Out.temp("docx")
            try write(try load(src), type: .officeOpenXML, to: t)
            input = t; tmp = t
        }
        defer { if let tmp { try? FileManager.default.removeItem(at: tmp) } }
        try IWork.export("Pages", input, to: out, as: format)
        return [out]
    }
}

enum IWork {
    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// format nil = save in the app's own format.
    static func export(_ app: String, _ src: URL, to out: URL, as format: String?, props: String = "") throws {
        let action = format.map { "export d to (POSIX file \"\(esc(out.path))\") as \($0)\(props)" }
            ?? "save d in (POSIX file \"\(esc(out.path))\")"
        let script = """
        tell application "\(app)"
            set d to open (POSIX file "\(esc(src.path))")
            \(action)
            close d saving no
        end tell
        """
        try Tools.run("osascript", ["-e", script])
        guard FileManager.default.fileExists(atPath: out.path) else {
            throw WheelError("\(app) didn't create \(out.lastPathComponent)")
        }
    }

    static func out(_ app: String, _ src: URL, ext: String, suffix: String? = nil, as format: String?, props: String = "") throws -> [URL] {
        let out = Out.url(for: src, ext: ext, suffix: suffix)
        try export(app, src, to: out, as: format, props: props)
        return [out]
    }
}

/// Just enough Markdown for notes and READMEs: headings, lists, code, emphasis, links.
enum Markdown {
    static func html(_ md: String) -> String {
        var out = ["<html><head><meta charset=\"utf-8\"><style>body{font:14px -apple-system,Helvetica;line-height:1.5} code,pre{font-family:Menlo,monospace;font-size:12px} pre{background:#f4f4f4;padding:8px}</style></head><body>"]
        var inCode = false, list: String? = nil, para: [String] = []
        func flushPara() { if !para.isEmpty { out.append("<p>\(inline(para.joined(separator: " ")))</p>"); para = [] } }
        func closeList() { if let l = list { out.append("</\(l)>"); list = nil } }
        for raw in md.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                flushPara(); closeList()
                out.append(inCode ? "</pre>" : "<pre>"); inCode.toggle(); continue
            }
            if inCode { out.append(escape(raw)); continue }
            if line.isEmpty { flushPara(); closeList(); continue }
            if let h = line.firstIndex(where: { $0 != "#" }), line.hasPrefix("#"), line[h] == " " {
                flushPara(); closeList()
                let n = min(line.distance(from: line.startIndex, to: h), 6)
                out.append("<h\(n)>\(inline(String(line[h...]).trimmingCharacters(in: .whitespaces)))</h\(n)>"); continue
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
                flushPara(); if list != "ul" { closeList(); out.append("<ul>"); list = "ul" }
                out.append("<li>\(inline(String(line.dropFirst(2))))</li>"); continue
            }
            if let r = line.range(of: #"^\d+[.)] "#, options: .regularExpression) {
                flushPara(); if list != "ol" { closeList(); out.append("<ol>"); list = "ol" }
                out.append("<li>\(inline(String(line[r.upperBound...])))</li>"); continue
            }
            if line.hasPrefix("> ") { flushPara(); closeList(); out.append("<blockquote>\(inline(String(line.dropFirst(2))))</blockquote>"); continue }
            closeList(); para.append(line)
        }
        flushPara(); closeList()
        if inCode { out.append("</pre>") }
        out.append("</body></html>")
        return out.joined(separator: "\n")
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    static func inline(_ s: String) -> String {
        var t = escape(s)
        let rules: [(String, String)] = [
            (#"`([^`]+)`"#, "<code>$1</code>"),
            (#"\*\*([^*]+)\*\*"#, "<b>$1</b>"),
            (#"__([^_]+)__"#, "<b>$1</b>"),
            (#"\*([^*]+)\*"#, "<i>$1</i>"),
            (#"\[([^\]]+)\]\(([^)\s]+)\)"#, "<a href=\"$2\">$1</a>"),
        ]
        for (p, r) in rules {
            t = t.replacingOccurrences(of: p, with: r, options: .regularExpression)
        }
        return t
    }
}

// MARK: - Share & functions

enum Share {
    static func service(_ name: NSSharingService.Name, _ urls: [URL], _ label: String) throws -> [URL] {
        guard let s = NSSharingService(named: name), s.canPerform(withItems: urls) else {
            throw WheelError("\(label) isn't available")
        }
        NSApp.activate(ignoringOtherApps: true)
        s.perform(withItems: urls)
        throw Notice(text: "\(label)…")
    }

    static func copyFiles(_ urls: [URL]) throws -> [URL] {
        onMain {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects(urls as [NSURL])
        }
        throw Notice(text: urls.count == 1 ? "Copied \(urls[0].lastPathComponent)" : "Copied \(urls.count) items — paste in Finder")
    }

    static func duplicate(_ urls: [URL]) throws -> [URL] {
        try urls.map { u in
            let t = Out.unique(u.deletingLastPathComponent(), u.deletingPathExtension().lastPathComponent + " copy", u.pathExtension)
            try FileManager.default.copyItem(at: u, to: t)
            return t
        }
    }

    static func extract(_ src: URL) throws -> [URL] {
        var base = src.deletingPathExtension()
        if base.pathExtension.lowercased() == "tar" { base = base.deletingPathExtension() }
        let dir = Out.unique(src.deletingLastPathComponent(), base.lastPathComponent, "")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            if src.ext == "zip" { try Tools.run("ditto", ["-x", "-k", src.path, dir.path]) }
            else { try Tools.run("bsdtar", ["-xf", src.path, "-C", dir.path]) }
        } catch { try? FileManager.default.removeItem(at: dir); throw error }
        // A single top-level folder inside? Lift it up so there's no "name/name/".
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
            .filter { !$0.lastPathComponent.hasPrefix(".") && $0.lastPathComponent != "__MACOSX" } ?? []
        if items.count == 1, items[0].hasDirectoryPath {
            let lifted = Out.unique(src.deletingLastPathComponent(), items[0].lastPathComponent, "")
            try FileManager.default.moveItem(at: items[0], to: lifted)
            try? FileManager.default.removeItem(at: dir)
            return [lifted]
        }
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("__MACOSX"))
        return [dir]
    }

    static func quickLook(_ urls: [URL]) throws -> [URL] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
        p.arguments = ["-p"] + urls.map(\.path)
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()  // stays open until the preview is closed
        throw Notice(text: "Quick Look")
    }

    static func openWith(_ urls: [URL]) throws -> [URL] {
        NSApp.activate(ignoringOtherApps: true)
        let p = NSOpenPanel()
        p.directoryURL = URL(fileURLWithPath: "/Applications")
        p.allowedContentTypes = [.application]
        p.prompt = "Open"
        p.message = "Open \(urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items") with…"
        guard p.runModal() == .OK, let app = p.url else { throw Notice(text: "Cancelled") }
        NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        throw Notice(text: "Opening in \(app.deletingPathExtension().lastPathComponent)")
    }
}

enum Social {
    static var blurFit: Bool {
        get { UserDefaults.standard.bool(forKey: "socialBlurFit") }
        set { UserDefaults.standard.set(newValue, forKey: "socialBlurFit") }
    }
}

// MARK: - Places

enum Places {
    enum Mode: String, CaseIterable { case auto, move, copy
        var label: String {
            switch self { case .auto: return "Move on same disk, copy across disks"; case .move: return "Always move"; case .copy: return "Always copy" }
        }
    }

    static let home = FileManager.default.homeDirectoryForCurrentUser
    static var defaults: [URL] {
        let icloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        return [home.appendingPathComponent("Desktop"), home.appendingPathComponent("Downloads"),
                home.appendingPathComponent("Documents"), icloud, home.appendingPathComponent("Pictures")]
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static var favourites: [URL] {
        get {
            guard let paths = UserDefaults.standard.stringArray(forKey: "favouritePlaces") else { return defaults }
            return paths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        }
        set { UserDefaults.standard.set(newValue.map(\.path), forKey: "favouritePlaces") }
    }

    static var recents: [URL] {
        let favs = Set(favourites.map(\.standardizedFileURL.path))
        return (UserDefaults.standard.stringArray(forKey: "recentPlaces") ?? [])
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) && !favs.contains($0.standardizedFileURL.path) }
    }

    static var mode: Mode {
        get { Mode(rawValue: UserDefaults.standard.string(forKey: "placesMode") ?? "") ?? .auto }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "placesMode") }
    }

    static func remember(_ dir: URL) {
        var list = UserDefaults.standard.stringArray(forKey: "recentPlaces") ?? []
        list.removeAll { $0 == dir.path }
        list.insert(dir.path, at: 0)
        UserDefaults.standard.set(Array(list.prefix(8)), forKey: "recentPlaces")
    }

    static func clearRecents() { UserDefaults.standard.removeObject(forKey: "recentPlaces") }

    static func symbol(for dir: URL) -> String {
        switch dir.standardizedFileURL.path {
        case home.appendingPathComponent("Desktop").path: return "menubar.dock.rectangle"
        case home.appendingPathComponent("Downloads").path: return "arrow.down.circle"
        case home.appendingPathComponent("Documents").path: return "doc"
        case home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs").path: return "icloud"
        case home.appendingPathComponent("Pictures").path: return "photo"
        case home.appendingPathComponent("Movies").path: return "film"
        case home.appendingPathComponent("Music").path: return "music.note"
        case home.path: return "house"
        case "/Applications": return "square.grid.2x2"
        default: return dir.path.hasPrefix("/Volumes/") ? "externaldrive" : "folder"
        }
    }

    /// Custom names set in Settings, keyed by path.
    static var titles: [String: String] {
        get { (UserDefaults.standard.dictionary(forKey: "placeTitles") as? [String: String]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "placeTitles") }
    }

    static var recentCount: Int {
        get { UserDefaults.standard.object(forKey: "recentCount") as? Int ?? 6 }
        set { UserDefaults.standard.set(max(0, min(8, newValue)), forKey: "recentCount") }
    }

    static func defaultName(for dir: URL) -> String {
        dir.path.hasSuffix("com~apple~CloudDocs") ? "iCloud" : dir.lastPathComponent
    }

    static func name(for dir: URL) -> String {
        if let t = titles[dir.path], !t.trimmingCharacters(in: .whitespaces).isEmpty { return t }
        if dir.path.hasSuffix("com~apple~CloudDocs") { return "iCloud" }
        let n = dir.lastPathComponent
        return n.count > 10 ? String(n.prefix(9)) + "…" : n
    }

    static func pretty(_ dir: URL) -> String {
        dir.path.hasPrefix(home.path) ? "~" + dir.path.dropFirst(home.path.count) : dir.path
    }

    static func page(for urls: [URL]) -> WheelPage {
        let verb = mode == .copy ? "Copy to" : (mode == .move ? "Move to" : "Into")
        func action(_ d: URL) -> Action {
            Action(id: "place:\(d.path)", title: name(for: d), symbol: symbol(for: d), detail: "\(verb) \(pretty(d))",
                   kinds: Actions.anyKind, batch: { try drop($0, into: d) })
        }
        let choose = Action(id: "place.choose", title: "Choose…", symbol: "ellipsis.circle", detail: "\(verb) a folder you pick",
                            kinds: Actions.anyKind, batch: { urls in
                                NSApp.activate(ignoringOtherApps: true)
                                let p = NSOpenPanel()
                                p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
                                p.prompt = mode == .copy ? "Copy Here" : "Move Here"
                                p.directoryURL = urls.first?.deletingLastPathComponent()
                                guard p.runModal() == .OK, let d = p.url else { throw Notice(text: "Cancelled") }
                                return try drop(urls, into: d)
                            }, onMain: true)
        let favs = favourites.map(action)
        let recent = recents.prefix(recentCount).map(action)
        return WheelPage(title: "Places", rings: recent.isEmpty ? [favs + [choose]] : [favs, recent + [choose]])
    }

    static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        let k: Set<URLResourceKey> = [.volumeIdentifierKey]
        guard let va = try? a.resourceValues(forKeys: k).volumeIdentifier as? NSObject,
              let vb = try? b.resourceValues(forKeys: k).volumeIdentifier as? NSObject else { return false }
        return va.isEqual(vb)
    }

    static func drop(_ urls: [URL], into dest: URL) throws -> [URL] {
        var outs: [URL] = []
        var moved = 0
        for u in urls {
            if u.deletingLastPathComponent().standardizedFileURL == dest.standardizedFileURL { continue }
            let target = Out.unique(dest, u.deletingPathExtension().lastPathComponent, u.pathExtension)
            let move = mode == .move || (mode == .auto && sameVolume(u, dest))
            if move { try FileManager.default.moveItem(at: u, to: target); moved += 1 }
            else { try FileManager.default.copyItem(at: u, to: target) }
            outs.append(target)
        }
        remember(dest)
        guard !outs.isEmpty else { throw Skipped(reason: "Already in \(dest.lastPathComponent)") }
        let verb = moved == outs.count ? "Moved" : (moved == 0 ? "Copied" : "Moved/copied")
        throw Notice(text: "\(verb) \(outs.count == 1 ? outs[0].lastPathComponent : "\(outs.count) items") to \(name(for: dest))")
    }
}

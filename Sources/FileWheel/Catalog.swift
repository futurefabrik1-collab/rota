import AppKit
import UniformTypeIdentifiers

struct WheelPage {
    let title: String
    /// One or two concentric rings, inner first.
    let rings: [[Action]]
    var actions: [Action] { rings.flatMap { $0 } }
}

/// The modifier keys a wheel can be assigned to.
enum Modifier: String, CaseIterable, Identifiable {
    case shift, command, control, option
    var id: String { rawValue }
    var flags: NSEvent.ModifierFlags {
        switch self { case .shift: return .shift; case .control: return .control
                      case .command: return .command; case .option: return .option }
    }
    var glyph: String {
        switch self { case .shift: return "⇧"; case .control: return "⌃"; case .command: return "⌘"; case .option: return "⌥" }
    }
    var name: String {
        switch self { case .shift: return "Shift"; case .control: return "Control"; case .command: return "Command"; case .option: return "Option" }
    }
}

/// A wheel. Which key opens it is a user setting.
enum WheelKey: String, CaseIterable, Identifiable {
    case convert, tools, share, places
    var id: String { rawValue }
    var title: String {
        switch self { case .convert: return "Convert"; case .tools: return "Tools"; case .share: return "Share"; case .places: return "Places" }
    }
    var defaultModifier: Modifier {
        switch self { case .convert: return .shift; case .tools: return .command; case .share: return .control; case .places: return .option }
    }
    var modifier: Modifier {
        Modifier(rawValue: UserDefaults.standard.string(forKey: "modifier.\(rawValue)") ?? "") ?? defaultModifier
    }
    var flags: NSEvent.ModifierFlags { modifier.flags }
    var glyph: String { modifier.glyph }

    /// Gives this wheel a key; whichever wheel had that key takes this wheel's old one.
    func assign(_ m: Modifier) {
        let previous = modifier
        if let other = WheelKey.allCases.first(where: { $0 != self && $0.modifier == m }) {
            UserDefaults.standard.set(previous.rawValue, forKey: "modifier.\(other.rawValue)")
        }
        UserDefaults.standard.set(m.rawValue, forKey: "modifier.\(rawValue)")
    }
}

/// User choices about which actions show and in what order.
enum Prefs {
    static var hidden: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "hiddenActions") ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: "hiddenActions") }
    }

    /// Full ordering of every action id; new actions from updates append at the end.
    static var order: [String] {
        get {
            let all = Actions.all.map(\.id)
            let saved = (UserDefaults.standard.stringArray(forKey: "actionOrder") ?? []).filter(all.contains)
            return saved + all.filter { !saved.contains($0) }
        }
        set { UserDefaults.standard.set(newValue, forKey: "actionOrder") }
    }

    static func sorted(_ list: [Action]) -> [Action] {
        let idx = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        return list.sorted { (idx[$0.id] ?? .max) < (idx[$1.id] ?? .max) }
    }

    static func arrange(_ list: [Action]) -> [Action] {
        let h = hidden
        return sorted(list.filter { !h.contains($0.id) })
    }

    /// Re-orders a subset in place within the global order.
    static func reorder(subset newOrder: [String]) {
        var o = order
        let positions = o.indices.filter { newOrder.contains(o[$0]) }
        for (p, id) in zip(positions, newOrder) { o[p] = id }
        order = o
    }

    static func resetWheels() {
        UserDefaults.standard.removeObject(forKey: "hiddenActions")
        UserDefaults.standard.removeObject(forKey: "actionOrder")
    }
}

extension Action {
    /// Quick actions don't show a "working…" bubble or reveal results.
    var quiet: Bool { id.hasPrefix("share.") || id.hasPrefix("place") }
}

enum Actions {
    static let anyKind = Set(Kind.allCases)

    static let convert: [Action] = imageConvert + videoConvert + audioConvert + pdfConvert + docConvert + slideConvert + sheetConvert
    static let tools: [Action] = imageTools + videoTools + audioTools + pdfTools
    static let social: [Action] = imageSocial + videoSocial
    static let all: [Action] = convert + social + tools + share

    // MARK: ⇧ Convert — social formats (outer ring)

    /// (title, detail, width, height) — sizes are each platform's recommended upload size.
    static let imagePresets: [(String, String, String, Int, Int)] = [
        ("1:1", "square", "Square · Instagram, Facebook, LinkedIn", 1080, 1080),
        ("4:5", "rectangle.portrait", "Portrait · Instagram feed", 1080, 1350),
        ("9:16", "iphone", "Story / Reel · Instagram, TikTok, Shorts", 1080, 1920),
        ("16:9", "rectangle", "Landscape · YouTube thumbnail, X", 1920, 1080),
        ("1.91:1", "link", "Link card · Facebook, LinkedIn, X", 1200, 628),
        ("2:3", "pin", "Pin · Pinterest", 1000, 1500),
        ("4:1", "rectangle.split.1x2", "Cover · LinkedIn banner", 1584, 396),
        ("Avatar", "person.crop.circle", "Profile picture · all platforms", 800, 800),
    ]

    static let videoPresets: [(String, String, String, Int, Int)] = [
        ("1:1", "square", "Square · Instagram, Facebook, LinkedIn", 1080, 1080),
        ("4:5", "rectangle.portrait", "Portrait · Instagram feed", 1080, 1350),
        ("9:16", "iphone", "Reel / TikTok / Shorts", 1080, 1920),
        ("16:9", "rectangle", "Landscape · YouTube, X, LinkedIn", 1920, 1080),
    ]

    static let imageSocial: [Action] = imagePresets.map { p in
        Action(id: "social.img.\(p.3)x\(p.4)", title: p.0, symbol: p.1, detail: "\(p.2) · \(p.3)×\(p.4)", kinds: [.image],
               each: { try ImgX.social($0, CGFloat(p.3), CGFloat(p.4)) })
    }

    static let videoSocial: [Action] = videoPresets.map { p in
        Action(id: "social.vid.\(p.3)x\(p.4)", title: p.0, symbol: p.1, detail: "\(p.2) · \(p.3)×\(p.4)", kinds: [.video],
               each: { try AV.social($0, p.3, p.4) })
    }

    /// Convert (⇧) · Tools (⌘) · Share (⌃) · Places (⌥) by default; keys are configurable.
    static func page(for key: WheelKey, urls: [URL]) -> WheelPage {
        switch key {
        case .convert:
            let formats = Prefs.arrange(filter(convert, urls)), socials = Prefs.arrange(filter(social, urls))
            if socials.isEmpty || formats.isEmpty { return WheelPage(title: key.title, rings: split(formats + socials)) }
            return WheelPage(title: key.title, rings: [formats, socials])
        case .tools: return WheelPage(title: key.title, rings: split(Prefs.arrange(filter(tools, urls))))
        case .share: return WheelPage(title: key.title, rings: split(Prefs.arrange(filter(share, urls))))
        case .places: return Places.page(for: urls)
        }
    }

    static func filter(_ list: [Action], _ urls: [URL]) -> [Action] {
        let kinds = Set(urls.map(\.fileKind))
        let exts = Set(urls.map(\.ext))
        return list.filter { a in
            urls.count >= a.minFiles && kinds.isSubset(of: a.kinds) && !(exts.isSubset(of: a.hideFor) && !exts.isEmpty)
        }
    }

    /// Long lists go onto two rings, the inner one smaller like a dial.
    static func split(_ a: [Action]) -> [[Action]] {
        guard a.count > 10 else { return [a] }
        let k = Int((Double(a.count) * 0.4).rounded())
        return [Array(a[..<k]), Array(a[k...])]
    }

    // MARK: Builders

    static func ff(_ ext: String, suffix: String? = nil, _ args: [String]) -> (URL) throws -> [URL] {
        ffDyn(ext, suffix: suffix) { _ in args }
    }

    static func ffDyn(_ ext: String, suffix: String? = nil, _ args: @escaping (URL) throws -> [String]) -> (URL) throws -> [URL] {
        { src in
            let o = Out.url(for: src, ext: ext.isEmpty ? src.ext : ext, suffix: suffix)
            try Tools.ffmpeg(src, try args(src), o)
            return [o]
        }
    }

    static let h264 = ["-c:v", "libx264", "-preset", "medium", "-crf", "20", "-pix_fmt", "yuv420p",
                       "-c:a", "aac", "-b:a", "160k", "-movflags", "+faststart"]

    // MARK: ⇧ Convert

    static let imageConvert: [Action] = [
        Action(id: "img.jpeg", title: "JPEG", symbol: "photo", detail: "Convert to JPEG", kinds: [.image], hideFor: ["jpg", "jpeg"],
               each: { try Img.convert($0, to: .jpeg, ext: "jpg", quality: 0.88) }),
        Action(id: "img.png", title: "PNG", symbol: "photo.fill", detail: "Convert to PNG (lossless)", kinds: [.image], hideFor: ["png"],
               each: { try Img.convert($0, to: .png, ext: "png", quality: nil) }),
        Action(id: "img.heic", title: "HEIC", symbol: "photo.stack", detail: "Convert to HEIC", kinds: [.image], hideFor: ["heic", "heif"],
               each: { try Img.convert($0, to: .heic, ext: "heic", quality: 0.8) }),
        Action(id: "img.webp", title: "WebP", symbol: "globe", detail: "Convert to WebP", kinds: [.image], hideFor: ["webp"],
               each: { try Img.convert($0, to: .webP, ext: "webp", quality: 0.82) }),
        Action(id: "img.avif", title: "AVIF", symbol: "sparkles", detail: "Convert to AVIF (smallest)", kinds: [.image], hideFor: ["avif"],
               each: { try Img.convert($0, to: UTType("public.avif")!, ext: "avif", quality: 0.7) }),
        Action(id: "img.tiff", title: "TIFF", symbol: "square.stack.3d.up", detail: "Convert to TIFF", kinds: [.image], hideFor: ["tif", "tiff"],
               each: { try Img.convert($0, to: .tiff, ext: "tiff", quality: nil) }),
        Action(id: "img.gif", title: "GIF", symbol: "photo.on.rectangle", detail: "Convert to GIF", kinds: [.image], hideFor: ["gif"],
               each: { try Img.convert($0, to: .gif, ext: "gif", quality: nil) }),
        Action(id: "img.bmp", title: "BMP", symbol: "square.grid.3x3", detail: "Convert to BMP", kinds: [.image], hideFor: ["bmp"],
               each: { try Img.convert($0, to: .bmp, ext: "bmp", quality: nil) }),
        Action(id: "img.ico", title: "ICO", symbol: "app.dashed", detail: "Windows icon, 256 px square", kinds: [.image], hideFor: ["ico"],
               each: { try ImgX.icon($0, type: UTType("com.microsoft.ico")!, ext: "ico", side: 256) }),
        Action(id: "img.icns", title: "ICNS", symbol: "app", detail: "macOS icon, 1024 px square", kinds: [.image], hideFor: ["icns"],
               each: { try ImgX.icon($0, type: .icns, ext: "icns", side: 1024) }),
        Action(id: "img.favicon", title: "Favicon", symbol: "globe.badge.chevron.backward", detail: "Website icon set: .ico, PNGs, manifest",
               kinds: [.image], each: ImgX.favicon),
        Action(id: "img.pdf", title: "PDF", symbol: "doc.richtext", detail: "Images into one PDF", kinds: [.image], batch: Img.toPDF),
    ]

    static let videoConvert: [Action] = [
        Action(id: "vid.mp4", title: "MP4", symbol: "film", detail: "MP4 · H.264", kinds: [.video], hideFor: ["mp4"],
               each: ff("mp4", h264)),
        Action(id: "vid.mov", title: "MOV", symbol: "film.stack", detail: "QuickTime · H.264", kinds: [.video], hideFor: ["mov"],
               each: ff("mov", h264)),
        Action(id: "vid.hevc", title: "HEVC", symbol: "bolt.horizontal", detail: "MP4 · H.265, half the size", kinds: [.video],
               each: ff("mp4", suffix: "hevc", ["-c:v", "hevc_videotoolbox", "-q:v", "62", "-tag:v", "hvc1",
                                                "-c:a", "aac", "-b:a", "160k", "-movflags", "+faststart"])),
        Action(id: "vid.prores", title: "ProRes", symbol: "camera.aperture", detail: "ProRes 422 HQ for editing", kinds: [.video],
               each: ff("mov", suffix: "prores", ["-c:v", "prores_ks", "-profile:v", "3", "-pix_fmt", "yuv422p10le",
                                                  "-c:a", "pcm_s16le"])),
        Action(id: "vid.webm", title: "WebM", symbol: "globe", detail: "WebM · VP9 + Opus", kinds: [.video], hideFor: ["webm"],
               each: ff("webm", ["-c:v", "libvpx-vp9", "-crf", "32", "-b:v", "0", "-row-mt", "1", "-deadline", "good",
                                 "-cpu-used", "4", "-c:a", "libopus", "-b:a", "128k"])),
        Action(id: "vid.mkv", title: "MKV", symbol: "shippingbox", detail: "Matroska, streams copied (instant)", kinds: [.video],
               hideFor: ["mkv"], each: ff("mkv", ["-map", "0:v?", "-map", "0:a?", "-c", "copy"])),
        Action(id: "vid.gif", title: "GIF", symbol: "photo.on.rectangle", detail: "Animated GIF · 640 px, 12 fps", kinds: [.video],
               each: ff("gif", ["-vf", "fps=12,scale='min(640,iw)':-2:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse",
                                "-loop", "0"])),
        Action(id: "vid.mp3", title: "MP3", symbol: "music.note", detail: "Audio only · MP3", kinds: [.video],
               each: ff("mp3", ["-vn", "-c:a", "libmp3lame", "-q:a", "2"])),
        Action(id: "vid.m4a", title: "M4A", symbol: "waveform", detail: "Audio only · AAC", kinds: [.video],
               each: ff("m4a", ["-vn", "-c:a", "aac", "-b:a", "192k"])),
        Action(id: "vid.wav", title: "WAV", symbol: "waveform.path", detail: "Audio only · WAV", kinds: [.video],
               each: ff("wav", ["-vn", "-c:a", "pcm_s24le"])),
    ]

    static let audioConvert: [Action] = [
        Action(id: "aud.mp3", title: "MP3", symbol: "music.note", detail: "MP3 · V2 VBR", kinds: [.audio], hideFor: ["mp3"],
               each: ff("mp3", ["-vn", "-c:a", "libmp3lame", "-q:a", "2", "-id3v2_version", "3"])),
        Action(id: "aud.aac", title: "AAC", symbol: "music.note.list", detail: "AAC 256k (.m4a)", kinds: [.audio], hideFor: ["m4a", "aac"],
               each: ff("m4a", ["-vn", "-c:a", "aac", "-b:a", "256k"])),
        Action(id: "aud.alac", title: "ALAC", symbol: "applelogo", detail: "Apple Lossless (.m4a)", kinds: [.audio],
               each: ff("m4a", suffix: "alac", ["-vn", "-c:a", "alac"])),
        Action(id: "aud.wav", title: "WAV", symbol: "waveform.path", detail: "WAV · 24-bit", kinds: [.audio], hideFor: ["wav"],
               each: ff("wav", ["-vn", "-c:a", "pcm_s24le"])),
        Action(id: "aud.aiff", title: "AIFF", symbol: "waveform.path.ecg", detail: "AIFF · 24-bit", kinds: [.audio], hideFor: ["aif", "aiff"],
               each: ff("aiff", ["-vn", "-c:a", "pcm_s24be"])),
        Action(id: "aud.flac", title: "FLAC", symbol: "waveform.circle", detail: "Lossless FLAC", kinds: [.audio], hideFor: ["flac"],
               each: ff("flac", ["-vn", "-c:a", "flac"])),
        Action(id: "aud.opus", title: "Opus", symbol: "dot.radiowaves.right", detail: "Opus 160k (tiny, great quality)", kinds: [.audio],
               hideFor: ["opus"], each: ff("opus", ["-vn", "-c:a", "libopus", "-b:a", "160k"])),
    ]

    static let pdfConvert: [Action] = [
        Action(id: "pdf.png", title: "PNG", symbol: "photo", detail: "Each page as PNG", kinds: [.pdf],
               each: { try PDFOps.pages($0, type: .png, ext: "png") }),
        Action(id: "pdf.jpeg", title: "JPEG", symbol: "photo.fill", detail: "Each page as JPEG", kinds: [.pdf],
               each: { try PDFOps.pages($0, type: .jpeg, ext: "jpg") }),
        Action(id: "pdf.tiff", title: "TIFF", symbol: "square.stack.3d.up", detail: "Each page as TIFF", kinds: [.pdf],
               each: { try PDFOps.pages($0, type: .tiff, ext: "tiff") }),
        Action(id: "pdf.txt", title: "Text", symbol: "text.alignleft", detail: "Plain text", kinds: [.pdf],
               each: { try PDFX.text($0, type: nil, ext: "txt") }),
        Action(id: "pdf.docx", title: "Word", symbol: "doc.text", detail: "Word document (text + styling)", kinds: [.pdf],
               each: { try PDFX.text($0, type: .officeOpenXML, ext: "docx") }),
        Action(id: "pdf.pages", title: "Pages", symbol: "doc.append", detail: "Pages document (text + styling)", kinds: [.pdf],
               each: PDFX.toPages),
        Action(id: "pdf.rtf", title: "RTF", symbol: "doc.plaintext", detail: "Rich text", kinds: [.pdf],
               each: { try PDFX.text($0, type: .rtf, ext: "rtf") }),
        Action(id: "pdf.html", title: "HTML", symbol: "chevron.left.forwardslash.chevron.right", detail: "Web page", kinds: [.pdf],
               each: { try PDFX.text($0, type: .html, ext: "html") }),
    ]

    static let docConvert: [Action] = [
        Action(id: "doc.pdf", title: "PDF", symbol: "doc.richtext", detail: "PDF via Pages", kinds: [.document],
               each: { try Doc.viaPages($0, format: "PDF", ext: "pdf") }),
        Action(id: "doc.docx", title: "Word", symbol: "doc.text", detail: "Word document", kinds: [.document], hideFor: ["docx"],
               each: { try Doc.convert($0, type: .officeOpenXML, ext: "docx") }),
        Action(id: "doc.pages", title: "Pages", symbol: "doc.append", detail: "Pages document", kinds: [.document], hideFor: ["pages"],
               each: { try Doc.viaPages($0, format: nil, ext: "pages") }),
        Action(id: "doc.rtf", title: "RTF", symbol: "doc.plaintext", detail: "Rich text", kinds: [.document], hideFor: ["rtf"],
               each: { try Doc.convert($0, type: .rtf, ext: "rtf") }),
        Action(id: "doc.txt", title: "Text", symbol: "text.alignleft", detail: "Plain text", kinds: [.document], hideFor: ["txt", "text"],
               each: { try Doc.convert($0, type: nil, ext: "txt") }),
        Action(id: "doc.html", title: "HTML", symbol: "chevron.left.forwardslash.chevron.right", detail: "Web page", kinds: [.document],
               hideFor: ["html", "htm"], each: { try Doc.convert($0, type: .html, ext: "html") }),
        Action(id: "doc.odt", title: "ODT", symbol: "doc.badge.gearshape", detail: "OpenDocument text", kinds: [.document], hideFor: ["odt"],
               each: { try Doc.convert($0, type: .openDocument, ext: "odt") }),
        Action(id: "doc.epub", title: "EPUB", symbol: "book", detail: "E-book via Pages", kinds: [.document],
               each: { try Doc.viaPages($0, format: "EPUB", ext: "epub") }),
    ]

    static let slideConvert: [Action] = [
        Action(id: "slides.pdf", title: "PDF", symbol: "doc.richtext", detail: "PDF via Keynote", kinds: [.slides],
               each: { try IWork.out("Keynote", $0, ext: "pdf", as: "PDF") }),
        Action(id: "slides.pptx", title: "PowerPoint", symbol: "rectangle.on.rectangle", detail: "PowerPoint .pptx", kinds: [.slides],
               hideFor: ["pptx"], each: { try IWork.out("Keynote", $0, ext: "pptx", as: "Microsoft PowerPoint") }),
        Action(id: "slides.key", title: "Keynote", symbol: "play.rectangle", detail: "Keynote presentation", kinds: [.slides],
               hideFor: ["key"], each: { try IWork.out("Keynote", $0, ext: "key", as: nil) }),
        Action(id: "slides.png", title: "Slides", symbol: "photo.on.rectangle.angled", detail: "Every slide as PNG", kinds: [.slides],
               each: { try IWork.out("Keynote", $0, ext: "", suffix: "slides", as: "slide images", props: " with properties {image format:PNG}") }),
        Action(id: "slides.movie", title: "Movie", symbol: "film", detail: "Self-playing movie", kinds: [.slides],
               each: { try IWork.out("Keynote", $0, ext: "m4v", as: "QuickTime movie") }),
    ]

    static let sheetConvert: [Action] = [
        Action(id: "sheet.pdf", title: "PDF", symbol: "doc.richtext", detail: "PDF via Numbers", kinds: [.sheet],
               each: { try IWork.out("Numbers", $0, ext: "pdf", as: "PDF") }),
        Action(id: "sheet.xlsx", title: "Excel", symbol: "tablecells", detail: "Excel .xlsx", kinds: [.sheet], hideFor: ["xlsx"],
               each: { try IWork.out("Numbers", $0, ext: "xlsx", as: "Microsoft Excel") }),
        Action(id: "sheet.csv", title: "CSV", symbol: "list.bullet.rectangle", detail: "CSV (one per table)", kinds: [.sheet],
               hideFor: ["csv"], each: { try IWork.out("Numbers", $0, ext: "csv", as: "CSV") }),
        Action(id: "sheet.numbers", title: "Numbers", symbol: "chart.bar.doc.horizontal", detail: "Numbers spreadsheet", kinds: [.sheet],
               hideFor: ["numbers"], each: { try IWork.out("Numbers", $0, ext: "numbers", as: nil) }),
    ]

    // MARK: ⌘ Tools

    static let imageTools: [Action] = [
        Action(id: "img.compress", title: "Compress", symbol: "arrow.down.right.and.arrow.up.left", detail: "Smaller file, same format",
               kinds: [.image], each: Img.compress),
        Action(id: "img.half", title: "50%", symbol: "arrow.down.forward.square", detail: "Half size", kinds: [.image],
               each: { try Img.resize($0, maxEdge: nil, scale: 0.5) }),
        Action(id: "img.1920", title: "1920px", symbol: "rectangle.compress.vertical", detail: "Long edge 1920 px", kinds: [.image],
               each: { try Img.resize($0, maxEdge: 1920, scale: nil) }),
        Action(id: "img.rotate", title: "Rotate", symbol: "rotate.right", detail: "Rotate 90° clockwise", kinds: [.image],
               each: { try ImgX.rotate($0) }),
        Action(id: "img.flip", title: "Flip", symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right", detail: "Mirror horizontally",
               kinds: [.image], each: { try ImgX.flip($0) }),
        Action(id: "img.mono", title: "B&W", symbol: "circle.lefthalf.filled", detail: "Black & white", kinds: [.image],
               each: { try ImgX.mono($0) }),
        Action(id: "img.cutout", title: "Cut Out", symbol: "person.crop.rectangle", detail: "Remove background → PNG", kinds: [.image],
               each: { try ImgX.removeBackground($0) }),
        Action(id: "img.ocr", title: "Text", symbol: "text.viewfinder", detail: "Recognise text → .txt", kinds: [.image],
               each: { try ImgX.ocr($0) }),
        Action(id: "img.qr", title: "QR", symbol: "qrcode.viewfinder", detail: "Read QR / barcodes → clipboard", kinds: [.image],
               batch: ImgX.readCodes),
        Action(id: "img.collage", title: "Collage", symbol: "square.grid.2x2", detail: "Grid collage of all images", kinds: [.image],
               minFiles: 2, batch: ImgX.collage),
        Action(id: "img.strip", title: "Clean", symbol: "eye.slash", detail: "Remove GPS & camera data (lossless)", kinds: [.image],
               each: Img.strip),
    ]

    static let videoTools: [Action] = [
        Action(id: "vid.compress", title: "Compress", symbol: "arrow.down.right.and.arrow.up.left", detail: "Smaller MP4, max 1080p",
               kinds: [.video], each: { src in
                   let o = Out.url(for: src, ext: "mp4", suffix: "compressed")
                   try Tools.ffmpeg(src, ["-vf", "scale=-2:'min(1080,ih)'", "-c:v", "libx264", "-preset", "slow", "-crf", "28",
                                          "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "128k", "-movflags", "+faststart"], o)
                   try Out.requireSmaller(o, than: src); return [o] }),
        Action(id: "vid.1080", title: "1080p", symbol: "rectangle.compress.vertical", detail: "Scale to 1080p", kinds: [.video],
               each: ff("mp4", suffix: "1080p", ["-vf", "scale=-2:'min(1080,ih)'"] + h264)),
        Action(id: "vid.720", title: "720p", symbol: "rectangle.compress.vertical", detail: "Scale to 720p", kinds: [.video],
               each: ff("mp4", suffix: "720p", ["-vf", "scale=-2:'min(720,ih)'"] + h264)),
        Action(id: "vid.fast", title: "2×", symbol: "hare", detail: "Double speed", kinds: [.video],
               each: { try AV.speed($0, 2) }),
        Action(id: "vid.slow", title: "½×", symbol: "tortoise", detail: "Half speed", kinds: [.video],
               each: { try AV.speed($0, 0.5) }),
        Action(id: "vid.rotate", title: "Rotate", symbol: "rotate.right", detail: "Rotate 90° clockwise", kinds: [.video],
               each: ff("mp4", suffix: "rotated", ["-vf", "transpose=1"] + h264)),
        Action(id: "vid.mute", title: "Mute", symbol: "speaker.slash", detail: "Remove the audio", kinds: [.video],
               each: ff("", suffix: "muted", ["-map", "0:v", "-c", "copy", "-an"])),
        Action(id: "vid.loud", title: "Loudness", symbol: "speaker.wave.3", detail: "Normalise audio to −14 LUFS", kinds: [.video],
               each: ff("mp4", suffix: "normalized", ["-c:v", "copy", "-af", "loudnorm=I=-14:TP=-1:LRA=11", "-ar", "48000",
                                                       "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart"])),
        Action(id: "vid.thumb", title: "Poster", symbol: "photo", detail: "Best frame as PNG", kinds: [.video],
               each: ff("png", suffix: "poster", ["-vf", "thumbnail=300", "-frames:v", "1"])),
        Action(id: "vid.frames", title: "Frames", symbol: "film.stack", detail: "One PNG per second", kinds: [.video],
               each: AV.frames),
        Action(id: "vid.sheet", title: "Sheet", symbol: "square.grid.4x3.fill", detail: "Contact sheet of 16 frames", kinds: [.video],
               each: AV.contactSheet),
        Action(id: "vid.join", title: "Join", symbol: "link", detail: "Join clips in name order", kinds: [.video], minFiles: 2,
               batch: AV.joinVideo),
        Action(id: "vid.strip", title: "Clean", symbol: "eye.slash", detail: "Remove location & device data", kinds: [.video],
               each: ff("", suffix: "clean", ["-map", "0", "-map_metadata", "-1", "-map_chapters", "-1", "-c", "copy"])),
    ]

    static let audioTools: [Action] = [
        Action(id: "aud.normalize", title: "Normalize", symbol: "slider.horizontal.3", detail: "Loudness to −14 LUFS", kinds: [.audio],
               each: { src in
                   let o = Out.url(for: src, ext: src.ext, suffix: "normalized")
                   var args = ["-vn", "-af", "loudnorm=I=-14:TP=-1:LRA=11"] + AV.codec(for: src.ext)
                   if let rate = try? Probe.sampleRate(src) { args += ["-ar", rate] }
                   try Tools.ffmpeg(src, args, o); return [o] }),
        Action(id: "aud.trim", title: "Trim", symbol: "scissors", detail: "Cut silence at both ends", kinds: [.audio],
               each: ffDyn("", suffix: "trimmed") { src in
                   ["-vn", "-af", "silenceremove=start_periods=1:start_threshold=-50dB,areverse,silenceremove=start_periods=1:start_threshold=-50dB,areverse"]
                       + AV.codec(for: src.ext) }),
        Action(id: "aud.fade", title: "Fade", symbol: "chart.line.uptrend.xyaxis", detail: "1 s fade in, 2 s fade out", kinds: [.audio],
               each: ffDyn("", suffix: "faded") { src in
                   let d = try Probe.duration(src)
                   return ["-vn", "-af", "afade=t=in:d=1,afade=t=out:st=\(max(0, d - 2)):d=2"] + AV.codec(for: src.ext) }),
        Action(id: "aud.mono", title: "Mono", symbol: "circle", detail: "Mix down to mono", kinds: [.audio],
               each: ffDyn("", suffix: "mono") { src in ["-vn", "-ac", "1"] + AV.codec(for: src.ext) }),
        Action(id: "aud.join", title: "Join", symbol: "link", detail: "Join tracks in name order", kinds: [.audio], minFiles: 2,
               batch: AV.joinAudio),
        Action(id: "aud.wave", title: "Waveform", symbol: "waveform", detail: "Waveform image (PNG)", kinds: [.audio],
               each: ff("png", suffix: "waveform", ["-filter_complex", "showwavespic=s=2400x480:colors=0x12C2E9|0x5CF2B0",
                                                    "-frames:v", "1"])),
        Action(id: "aud.visual", title: "Visualiser", symbol: "play.rectangle", detail: "Waveform video (MP4) for socials", kinds: [.audio],
               each: ff("mp4", suffix: "visualiser", ["-filter_complex",
                   "[0:a]showwaves=s=1280x720:mode=cline:rate=30:colors=0x12C2E9|0x5CF2B0,format=yuv420p[v]",
                   "-map", "[v]", "-map", "0:a", "-c:v", "libx264", "-preset", "fast", "-crf", "22",
                   "-c:a", "aac", "-b:a", "192k", "-shortest", "-movflags", "+faststart"])),
        Action(id: "aud.strip", title: "Clean", symbol: "eye.slash", detail: "Remove tags & artwork", kinds: [.audio],
               each: ff("", suffix: "clean", ["-map", "0:a", "-map_metadata", "-1", "-c", "copy"])),
    ]

    static let pdfTools: [Action] = [
        Action(id: "pdf.compress", title: "Compress", symbol: "arrow.down.right.and.arrow.up.left", detail: "Smaller PDF (150 dpi images)",
               kinds: [.pdf], each: PDFX.compress),
        Action(id: "pdf.merge", title: "Merge", symbol: "doc.on.doc", detail: "Merge in name order", kinds: [.pdf], minFiles: 2,
               batch: PDFOps.merge),
        Action(id: "pdf.split", title: "Split", symbol: "rectangle.split.3x1", detail: "One PDF per page", kinds: [.pdf],
               each: PDFX.split),
        Action(id: "pdf.rotate", title: "Rotate", symbol: "rotate.right", detail: "Rotate all pages 90°", kinds: [.pdf],
               each: { src in let o = Out.url(for: src, ext: "pdf", suffix: "rotated")
                   try Tools.run("qpdf", [src.path, "--rotate=+90", o.path]); return [o] }),
        Action(id: "pdf.reverse", title: "Reverse", symbol: "arrow.up.arrow.down", detail: "Reverse page order", kinds: [.pdf],
               each: { src in let o = Out.url(for: src, ext: "pdf", suffix: "reversed")
                   try Tools.run("qpdf", [src.path, "--pages", ".", "z-1", "--", o.path]); return [o] }),
        Action(id: "pdf.ocr", title: "OCR", symbol: "text.viewfinder", detail: "Make scans searchable", kinds: [.pdf],
               each: PDFX.ocr),
        Action(id: "pdf.pdfa", title: "PDF/A", symbol: "archivebox", detail: "Archival PDF/A-2", kinds: [.pdf],
               each: { try PDFX.gs($0, suffix: "PDF-A", ["-dPDFA=2", "-dPDFACompatibilityPolicy=1", "-sColorConversionStrategy=RGB"]) }),
        Action(id: "pdf.mono", title: "B&W", symbol: "circle.lefthalf.filled", detail: "Greyscale", kinds: [.pdf],
               each: { try PDFX.gs($0, suffix: "greyscale", ["-sColorConversionStrategy=Gray", "-dProcessColorModel=/DeviceGray"]) }),
        Action(id: "pdf.strip", title: "Clean", symbol: "eye.slash", detail: "Remove author & title data", kinds: [.pdf],
               each: PDFOps.strip),
    ]

    // MARK: ⌃ Share & functions

    static let share: [Action] = [
        Action(id: "share.airdrop", title: "AirDrop", symbol: "dot.radiowaves.left.and.right", detail: "Send to a nearby Apple device",
               kinds: anyKind, batch: { try Share.service(.sendViaAirDrop, $0, "AirDrop") }, onMain: true),
        Action(id: "share.messages", title: "Messages", symbol: "message", detail: "Send in Messages",
               kinds: anyKind, batch: { try Share.service(.composeMessage, $0, "Messages") }, onMain: true),
        Action(id: "share.mail", title: "Mail", symbol: "envelope", detail: "Attach to a new email",
               kinds: anyKind, batch: { try Share.service(.composeEmail, $0, "Mail") }, onMain: true),
        Action(id: "share.copy", title: "Copy", symbol: "doc.on.clipboard", detail: "Copy files — paste anywhere",
               kinds: anyKind, batch: Share.copyFiles),
        Action(id: "share.path", title: "Path", symbol: "link", detail: "Copy full paths",
               kinds: anyKind, batch: FileOps.copyPaths),
        Action(id: "share.duplicate", title: "Duplicate", symbol: "plus.square.on.square", detail: "Make a copy next to it",
               kinds: anyKind, batch: Share.duplicate),
        Action(id: "share.zip", title: "Zip", symbol: "archivebox", detail: "Compress into a .zip",
               kinds: anyKind, batch: Archive.zip),
        Action(id: "share.extract", title: "Extract", symbol: "archivebox.circle", detail: "Unpack the archive here",
               kinds: [.archive], each: Share.extract),
        Action(id: "share.quicklook", title: "Look", symbol: "eye", detail: "Quick Look preview",
               kinds: anyKind, batch: Share.quickLook),
        Action(id: "share.terminal", title: "Terminal", symbol: "terminal", detail: "Open Terminal in this folder",
               kinds: anyKind, batch: FileOps.terminal),
        Action(id: "share.openwith", title: "Open With", symbol: "square.grid.2x2", detail: "Open with an app you choose",
               kinds: anyKind, batch: Share.openWith, onMain: true),
    ]
}

import AppKit
import QuartzCore

/// Polls mouse/modifier state (no Accessibility permission needed). Tapping ⇧ ⌃ ⌘ or ⌥ during a
/// file drag opens that key's wheel; tapping a different key swaps it.
final class DragWatcher {
    /// urls is non-nil on the first key of a drag.
    var onKey: ((WheelKey, [URL]?, NSPoint) -> Void)?
    var onMouseUp: (() -> Void)?

    private var timer: Timer?
    private let dragPB = NSPasteboard(name: .drag)
    private var baseChange = 0
    private var wasDown = false
    private var lastFlags: NSEvent.ModifierFlags = []
    private var fired = false
    private var current: WheelKey?

    func start() {
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        let down = NSEvent.pressedMouseButtons & 1 != 0
        if down && !wasDown { baseChange = dragPB.changeCount; fired = false; current = nil }
        if !down && wasDown { onMouseUp?(); fired = false; current = nil }
        wasDown = down

        let flags = NSEvent.modifierFlags.intersection([.shift, .control, .option, .command])
        defer { lastFlags = flags }
        guard down, flags != lastFlags, dragPB.changeCount != baseChange,
              let key = WheelKey.allCases.first(where: { $0.flags == flags }), key != current else { return }

        if !fired {
            let urls = dragPB.readObjects(forClasses: [NSURL.self],
                                          options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            guard !urls.isEmpty else { return }
            fired = true
            current = key
            onKey?(key, urls, NSEvent.mouseLocation)
        } else {
            current = key
            onKey?(key, nil, NSEvent.mouseLocation)
        }
    }
}

// MARK: - Look

enum Palette {
    static func hex(_ v: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
    /// Gradient pair per file kind.
    static func colors(for urls: [URL]) -> (NSColor, NSColor) {
        let kinds = Set(urls.map(\.fileKind))
        switch kinds.count == 1 ? kinds.first! : .other {
        case .image: return (hex(0xFF5E62), hex(0xFFB15C))   // coral → apricot
        case .video: return (hex(0x7B61FF), hex(0xE85CFF))   // violet → orchid
        case .audio: return (hex(0x12C2E9), hex(0x5CF2B0))   // cyan → mint
        case .pdf:   return (hex(0xFF3D6E), hex(0xFF8A5C))   // crimson → tangelo
        case .document: return (hex(0x3A7BFF), hex(0x5CC8FF)) // ink blue → sky
        case .slides: return (hex(0xFF8A00), hex(0xFFD15C))   // amber → gold
        case .sheet: return (hex(0x1FB36B), hex(0xA6E35C))    // green → lime
        case .archive: return (hex(0xA77B5C), hex(0xE0B98A))  // walnut → sand
        case .other: return (hex(0x4F8CFF), hex(0x9C7BFF))   // azure → iris
        }
    }
    static let glass = NSColor(srgbRed: 0.075, green: 0.075, blue: 0.09, alpha: 0.88).cgColor
    static let hairline = NSColor(white: 1, alpha: 0.09).cgColor
}

// MARK: - Panel

final class WheelPanel: NSPanel {
    let wheel = WheelView(frame: NSRect(x: 0, y: 0, width: WheelView.size, height: WheelView.size))

    init() {
        super.init(contentRect: wheel.frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isReleasedWhenClosed = false
        contentView = wheel
    }

    func show(page: WheelPage, key: WheelKey, urls: [URL], at p: NSPoint) {
        let s = WheelView.size
        var origin = NSPoint(x: p.x - s / 2, y: p.y - s / 2)
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(p, $0.frame, false) }) {
            let f = screen.frame
            origin.x = min(max(origin.x, f.minX - 60), f.maxX - s + 60)
            origin.y = min(max(origin.y, f.minY - 60), f.maxY - s + 60)
        }
        setFrameOrigin(origin)
        alphaValue = 1
        orderFrontRegardless()
        wheel.present(page: page, key: key, colors: Palette.colors(for: urls), count: urls.count)
    }

    func hide(picked: Bool = false) {
        guard isVisible, !wheel.leaving else { return }
        wheel.dismiss(picked: picked) { [weak self] in self?.orderOut(nil) }
    }
}

// MARK: - Wheel

final class WheelView: NSView {
    static let size: CGFloat = 600
    static let band: CGFloat = 32      // half the ring thickness
    static let ringGap: CGFloat = 5
    static let slice: CGFloat = 70     // arc length per slice at the ring's mid radius

    struct Slot: Equatable { let ring: Int; let index: Int }

    var onPick: ((Action, [URL]) -> Void)?
    private(set) var leaving = false

    private var page = WheelPage(title: "", rings: [])
    private var key: WheelKey = .convert
    private var rings: [[Action]] { page.rings.filter { !$0.isEmpty } }
    private var colors: (NSColor, NSColor) = (.systemBlue, .systemPurple)
    private var fileCount = 0
    private var hovered: Slot? { didSet { if hovered != oldValue { updateHover(from: oldValue) } } }

    /// Mid radius of each ring (always two values; the outer one collapses when unused).
    private var mids: [CGFloat] = [121, 121]
    private var diskR: CGFloat = 82

    private let root = CALayer()
    private let ring = CAShapeLayer()
    private let sheen = CAGradientLayer()
    private let sheenMask = CAShapeLayer()
    private let rim = CAShapeLayer()
    private let disk = CAShapeLayer()
    private let accentRim = CAShapeLayer()
    private let highlight = CALayer()
    private let hiGradient = CAGradientLayer()
    private let hiMask = CAShapeLayer()
    private var pageLayer = CALayer()
    private var labels: [[CALayer]] = []
    private let titleLayer = CATextLayer()
    private let detailLayer = CATextLayer()
    private let legend = CATextLayer()
    private var hiAngle: CGFloat = 0

    private var c: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }
    private func step(_ r: Int) -> CGFloat { 360 / CGFloat(max(rings.indices.contains(r) ? rings[r].count : 1, 1)) }
    private var scale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        registerForDraggedTypes([.fileURL])
        buildLayers()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func circle(_ r: CGFloat) -> CGPath {
        CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2), transform: nil)
    }

    /// Four circles: inner annulus + outer annulus (zero-width when there's one ring), so
    /// the shape can animate smoothly between one and two rings.
    private func ringsPath() -> CGPath {
        let p = CGMutablePath()
        let o0 = mids[0] + Self.band, i0 = mids[0] - Self.band
        let two = rings.count > 1
        let o1 = two ? mids[1] + Self.band : o0 + 0.01
        let i1 = two ? mids[1] - Self.band : o0
        for r in [o1, i1, o0, i0] { p.addPath(circle(r)) }
        return p
    }

    private func buildLayers() {
        root.frame = bounds
        layer?.addSublayer(root)
        for l in [ring, sheen, sheenMask, rim, disk, accentRim, highlight, hiGradient, hiMask] { l.frame = bounds }

        ring.fillRule = .evenOdd
        ring.fillColor = Palette.glass
        ring.shadowColor = NSColor.black.cgColor
        ring.shadowOpacity = 0.4
        ring.shadowRadius = 22
        ring.shadowOffset = CGSize(width: 0, height: -8)

        sheen.colors = [NSColor(white: 1, alpha: 0.07).cgColor, NSColor(white: 1, alpha: 0).cgColor]
        sheen.startPoint = CGPoint(x: 0.5, y: 1)
        sheen.endPoint = CGPoint(x: 0.5, y: 0.35)
        sheenMask.fillRule = .evenOdd
        sheen.mask = sheenMask

        rim.fillColor = nil
        rim.strokeColor = Palette.hairline
        rim.lineWidth = 1

        disk.fillColor = Palette.glass
        disk.strokeColor = Palette.hairline
        disk.lineWidth = 1
        disk.shadowColor = NSColor.black.cgColor
        disk.shadowOpacity = 0.3
        disk.shadowRadius = 12

        accentRim.fillColor = nil
        accentRim.lineWidth = 1.5
        accentRim.opacity = 0.55

        hiGradient.type = .axial
        hiGradient.startPoint = CGPoint(x: 0.3, y: 1)
        hiGradient.endPoint = CGPoint(x: 0.7, y: 0.55)
        hiMask.fillColor = NSColor.black.cgColor
        hiMask.strokeColor = NSColor.black.cgColor
        hiMask.lineJoin = .round
        hiGradient.mask = hiMask
        highlight.addSublayer(hiGradient)
        highlight.shadowOpacity = 0.7
        highlight.shadowRadius = 16
        highlight.shadowOffset = .zero
        highlight.opacity = 0

        for l in [titleLayer, detailLayer, legend] {
            l.alignmentMode = .center
            l.isWrapped = true
            l.truncationMode = .end
        }
        titleLayer.frame = CGRect(x: c.x - 60, y: c.y + 18, width: 120, height: 14)
        detailLayer.frame = CGRect(x: c.x - 62, y: c.y - 24, width: 124, height: 40)
        legend.frame = CGRect(x: c.x - 60, y: c.y - 50, width: 120, height: 16)

        [ring, sheen, rim, disk, accentRim, highlight, pageLayer, titleLayer, detailLayer, legend].forEach(root.addSublayer)
        applyGeometry(animated: false)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        [titleLayer, detailLayer, legend].forEach { $0.contentsScale = scale }
    }

    private func fitRadii() {
        let n0 = CGFloat(rings.first?.count ?? 0)
        let m0 = min(max(126, n0 * Self.slice / (2 * .pi)), 205)
        var m1 = m0
        if rings.count > 1 {
            m1 = min(max(m0 + 2 * Self.band + Self.ringGap, CGFloat(rings[1].count) * Self.slice / (2 * .pi)), 240)
        }
        mids = [m0, m1]
        diskR = min(m0 - Self.band - 12, 96)
    }

    private func applyGeometry(animated: Bool) {
        fitRadii()
        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(0.26)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1))
        } else {
            CATransaction.setDisableActions(true)
        }
        let p = ringsPath()
        ring.path = p
        sheenMask.path = p
        rim.path = p
        disk.path = circle(diskR)
        accentRim.path = circle(diskR - 0.5)
        CATransaction.commit()
    }

    // MARK: Presenting

    func present(page: WheelPage, key: WheelKey, colors: (NSColor, NSColor), count: Int) {
        self.page = page
        self.key = key
        self.colors = colors
        self.fileCount = count
        leaving = false

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.removeAllAnimations()
        root.opacity = 1
        root.transform = CATransform3DIdentity
        hiGradient.colors = [colors.0.cgColor, colors.1.cgColor]
        highlight.shadowColor = colors.0.cgColor
        accentRim.strokeColor = colors.1.cgColor
        [titleLayer, detailLayer, legend].forEach { $0.contentsScale = scale }
        hovered = nil
        highlight.opacity = 0
        applyGeometry(animated: false)
        installPage(replacing: nil, direction: 1)
        CATransaction.commit()

        let pop = CASpringAnimation(keyPath: "transform.scale")
        pop.fromValue = 0.78; pop.toValue = 1
        pop.damping = 17; pop.stiffness = 320; pop.mass = 0.8
        pop.duration = pop.settlingDuration
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0; fade.toValue = 1; fade.duration = 0.14
        root.add(pop, forKey: "pop")
        root.add(fade, forKey: "fade")
        staggerLabels()
    }

    /// Another key was tapped mid-drag: the ring re-sizes while its contents turn over.
    func swap(to newPage: WheelPage, key newKey: WheelKey) {
        guard !leaving, newKey != key else { return }
        let order = WheelKey.allCases
        let dir: CGFloat = (order.firstIndex(of: newKey)! > order.firstIndex(of: key)!) ? 1 : -1
        page = newPage
        key = newKey
        hovered = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        highlight.opacity = 0
        CATransaction.commit()
        applyGeometry(animated: true)
        installPage(replacing: pageLayer, direction: dir)
    }

    func dismiss(picked: Bool, completion: @escaping () -> Void) {
        leaving = true
        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)
        let s = CABasicAnimation(keyPath: "transform.scale")
        s.toValue = picked ? 1.07 : 0.9
        let o = CABasicAnimation(keyPath: "opacity")
        o.toValue = 0
        let g = CAAnimationGroup()
        g.animations = [s, o]
        g.duration = picked ? 0.22 : 0.13
        g.timingFunction = CAMediaTimingFunction(name: .easeIn)
        g.fillMode = .forwards
        g.isRemovedOnCompletion = false
        if picked {
            let flash = CABasicAnimation(keyPath: "opacity")
            flash.fromValue = 1; flash.toValue = 0.35; flash.duration = 0.09; flash.autoreverses = true
            highlight.add(flash, forKey: "flash")
            g.beginTime = CACurrentMediaTime() + 0.08
        }
        root.add(g, forKey: "out")
        CATransaction.commit()
    }

    /// A label sized to the room it has: on the sides of the ring horizontal text runs across
    /// the band, at the top and bottom along it, so the allowed width depends on the angle.
    private func makeLabel(_ a: Action, at p: CGPoint, angle: CGFloat, ring r: Int) -> CALayer {
        let usableBand = 2 * Self.band - 12
        let n = CGFloat(max(rings[r].count, 1))
        let chord = n > 1 ? 2 * mids[r] * sin(.pi / n) - 8 : 140
        let cosA = abs(cos(angle))
        let maxW = max(30, min(chord, cosA < 0.08 ? chord : usableBand / cosA, 88))

        var size: CGFloat = 9
        func styled(_ t: String, _ s: CGFloat) -> NSAttributedString {
            NSAttributedString(string: t, attributes: [
                .font: NSFont.systemFont(ofSize: s, weight: .semibold), .foregroundColor: NSColor.white, .kern: s * 0.07])
        }
        var title = a.title.uppercased()
        var str = styled(title, size)
        while str.size().width > maxW && size > 7 { size -= 0.5; str = styled(title, size) }
        while str.size().width > maxW && title.count > 3 {
            title = String(title.dropLast(title.hasSuffix("…") ? 2 : 1)) + "…"
            str = styled(title, size)
        }

        let w = max(maxW, 40)
        let item = CALayer()
        item.bounds = CGRect(x: 0, y: 0, width: w, height: 40)
        item.position = p
        let icon = CALayer()
        icon.frame = CGRect(x: (w - 20) / 2, y: 18, width: 20, height: 18)
        icon.contentsGravity = .resizeAspect
        icon.contents = NSImage(systemSymbolName: a.symbol, accessibilityDescription: a.title)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular).applying(.init(paletteColors: [.white])))
            ?? NSImage(systemSymbolName: "circle", accessibilityDescription: nil)
        icon.contentsScale = scale
        let text = CATextLayer()
        text.frame = CGRect(x: 0, y: 2, width: w, height: 13)
        text.alignmentMode = .center
        text.contentsScale = scale
        text.string = str
        item.addSublayer(icon)
        item.addSublayer(text)
        item.opacity = 0.78
        return item
    }

    /// Builds the slices and swaps them in. The old set turns away before the new one
    /// sweeps in, so two wheels' contents never overlap.
    private func installPage(replacing old: CALayer?, direction dir: CGFloat) {
        if old == nil {
            root.sublayers?.filter { $0.name == "page" }.forEach { $0.removeAllAnimations(); $0.removeFromSuperlayer() }
        } else {
            root.sublayers?.filter { $0.name == "page" && $0 !== old }.forEach { $0.removeFromSuperlayer() }
        }
        let page = CALayer()
        page.name = "page"
        page.frame = bounds
        labels = []
        for (r, acts) in rings.enumerated() {
            let st = step(r)
            var row: [CALayer] = []
            for (i, a) in acts.enumerated() {
                let ang = (90 - CGFloat(i) * st) * .pi / 180
                let l = makeLabel(a, at: CGPoint(x: c.x + mids[r] * cos(ang), y: c.y + mids[r] * sin(ang)), angle: ang, ring: r)
                page.addSublayer(l)
                row.append(l)
            }
            labels.append(row)
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.insertSublayer(page, above: highlight)
        pageLayer = page
        updateCentre()
        CATransaction.commit()

        guard let old else { return }
        let out = CAAnimationGroup()
        let rot = CABasicAnimation(keyPath: "transform.rotation.z"); rot.toValue = 0.4 * dir
        let sc = CABasicAnimation(keyPath: "transform.scale"); sc.toValue = 0.9
        let op = CABasicAnimation(keyPath: "opacity"); op.toValue = 0
        out.animations = [rot, sc, op]
        out.duration = 0.11
        out.timingFunction = CAMediaTimingFunction(name: .easeIn)
        out.fillMode = .forwards
        out.isRemovedOnCompletion = false
        CATransaction.begin()
        CATransaction.setCompletionBlock { old.removeFromSuperlayer() }
        old.add(out, forKey: "out")
        CATransaction.commit()

        let t0 = CACurrentMediaTime() + 0.09
        let inRot = CASpringAnimation(keyPath: "transform.rotation.z")
        inRot.fromValue = -0.5 * dir; inRot.toValue = 0
        inRot.damping = 18; inRot.stiffness = 260; inRot.mass = 0.8
        inRot.duration = inRot.settlingDuration
        let inOp = CABasicAnimation(keyPath: "opacity")
        inOp.fromValue = 0; inOp.toValue = 1; inOp.duration = 0.16
        for a in [inRot, inOp] as [CAAnimation] { a.beginTime = t0; a.fillMode = .backwards }
        page.add(inRot, forKey: "inRot")
        page.add(inOp, forKey: "inOp")

        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 0.15; pulse.toValue = 0.55; pulse.duration = 0.35
        accentRim.add(pulse, forKey: "pulse")
    }

    private func staggerLabels() {
        let now = CACurrentMediaTime()
        for (i, l) in labels.flatMap({ $0 }).enumerated() {
            let sc = CASpringAnimation(keyPath: "transform.scale")
            sc.fromValue = 0.55; sc.toValue = 1
            sc.damping = 15; sc.stiffness = 300; sc.mass = 0.7
            sc.duration = sc.settlingDuration
            let op = CABasicAnimation(keyPath: "opacity")
            op.fromValue = 0; op.toValue = 0.78; op.duration = 0.18
            for a in [sc, op] as [CAAnimation] { a.beginTime = now + 0.03 + Double(i) * 0.012; a.fillMode = .backwards }
            l.add(sc, forKey: "in"); l.add(op, forKey: "inOp")
        }
    }

    /// One slice of ring r centred at 12 o'clock, inset so the stroked mask gives rounded corners.
    private func segmentPath(ring r: Int) -> CGPath {
        let ro = mids[r] + Self.band - 8, ri = mids[r] - Self.band + 8
        let n = rings[r].count
        if n <= 1 {
            hiMask.fillRule = .evenOdd
            hiMask.lineWidth = 0
            let p = CGMutablePath(); p.addPath(circle(ro + 4)); p.addPath(circle(ri - 4)); return p
        }
        hiMask.fillRule = .nonZero
        hiMask.lineWidth = 10
        let st = step(r)
        let gap = min(2.2, st / 6) + 5 / (mids[r] * .pi / 180)
        let a0 = (90 + st / 2 - gap) * .pi / 180, a1 = (90 - st / 2 + gap) * .pi / 180
        let p = CGMutablePath()
        p.addArc(center: c, radius: ro, startAngle: a0, endAngle: a1, clockwise: true)
        p.addArc(center: c, radius: ri, startAngle: a1, endAngle: a0, clockwise: false)
        p.closeSubpath()
        return p
    }

    // MARK: Hover

    private func updateHover(from old: Slot?) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.16)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1))
        if let h = hovered, rings.indices.contains(h.ring), h.index < rings[h.ring].count {
            let target = -CGFloat(h.index) * step(h.ring) * .pi / 180
            if highlight.opacity < 0.01 || old?.ring != h.ring {
                // New ring (or first hover): reshape and appear in place.
                CATransaction.begin(); CATransaction.setDisableActions(true)
                hiMask.path = segmentPath(ring: h.ring)
                highlight.setValue(target, forKeyPath: "transform.rotation.z")
                CATransaction.commit()
                hiAngle = target
            } else {
                var d = (target - hiAngle).truncatingRemainder(dividingBy: 2 * .pi)
                if d > .pi { d -= 2 * .pi }
                if d < -.pi { d += 2 * .pi }
                let to = hiAngle + d
                let spin = CASpringAnimation(keyPath: "transform.rotation.z")
                spin.fromValue = hiAngle; spin.toValue = to
                spin.damping = 22; spin.stiffness = 420; spin.mass = 0.6
                spin.duration = spin.settlingDuration
                CATransaction.begin(); CATransaction.setDisableActions(true)
                highlight.setValue(to, forKeyPath: "transform.rotation.z")
                CATransaction.commit()
                highlight.add(spin, forKey: "spin")
                hiAngle = to
            }
            highlight.opacity = 1
            for (r, row) in labels.enumerated() {
                for (i, l) in row.enumerated() {
                    let on = r == h.ring && i == h.index
                    l.opacity = on ? 1 : 0.5
                    l.transform = on ? CATransform3DMakeScale(1.1, 1.1, 1) : CATransform3DIdentity
                }
            }
        } else {
            highlight.opacity = 0
            labels.flatMap { $0 }.forEach { $0.opacity = 0.78; $0.transform = CATransform3DIdentity }
        }
        CATransaction.commit()
        updateCentre()
    }

    private func action(at s: Slot?) -> Action? {
        guard let s, rings.indices.contains(s.ring), s.index < rings[s.ring].count else { return nil }
        return rings[s.ring][s.index]
    }

    private func updateCentre() {
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineSpacing = 1
        titleLayer.string = NSAttributedString(string: page.title.uppercased(), attributes: [
            .font: NSFont.systemFont(ofSize: 9.5, weight: .bold), .foregroundColor: colors.1, .kern: 2.2,
            .paragraphStyle: para])

        let detail = NSMutableAttributedString()
        if let a = action(at: hovered) {
            detail.append(NSAttributedString(string: a.detail, attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white,
                .paragraphStyle: para]))
        } else {
            detail.append(NSAttributedString(string: fileCount == 1 ? "1 file" : "\(fileCount) files", attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.white,
                .paragraphStyle: para]))
            detail.append(NSAttributedString(string: rings.isEmpty ? "\nnothing here — try another key" : "\nrelease here to cancel",
                                             attributes: [.font: NSFont.systemFont(ofSize: 10, weight: .regular),
                                                          .foregroundColor: NSColor(white: 1, alpha: 0.5), .paragraphStyle: para]))
        }
        detailLayer.string = detail

        let lg = NSMutableAttributedString()
        for (i, k) in WheelKey.allCases.enumerated() {
            if i > 0 { lg.append(NSAttributedString(string: "   ")) }
            lg.append(NSAttributedString(string: k.glyph, attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: k == key ? .bold : .regular),
                .foregroundColor: k == key ? colors.1 : NSColor(white: 1, alpha: 0.3)]))
        }
        lg.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: lg.length))
        legend.string = lg
    }

    // MARK: Hit testing & drop

    private func slot(at p: NSPoint) -> Slot? {
        let dx = p.x - c.x, dy = p.y - c.y
        let r = hypot(dx, dy)
        guard !rings.isEmpty, r >= diskR + 6 else { return nil }
        let ringIndex: Int
        if rings.count > 1 {
            let boundary = (mids[0] + Self.band + mids[1] - Self.band) / 2
            guard r <= mids[1] + Self.band + 40 else { return nil }
            ringIndex = r < boundary ? 0 : 1
        } else {
            guard r <= mids[0] + Self.band + 40 else { return nil }
            ringIndex = 0
        }
        let deg = atan2(dy, dx) * 180 / .pi
        var theta = (90 - deg).truncatingRemainder(dividingBy: 360)
        if theta < 0 { theta += 360 }
        let st = step(ringIndex)
        return Slot(ring: ringIndex, index: Int((theta + st / 2) / st) % rings[ringIndex].count)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !leaving else { return [] }
        hovered = slot(at: convert(sender.draggingLocation, from: nil))
        return hovered == nil ? [] : .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { hovered = nil }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard !leaving, let a = action(at: slot(at: convert(sender.draggingLocation, from: nil))) else { return false }
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                         options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        DispatchQueue.main.async { self.onPick?(a, urls) }
        return true
    }
}

// MARK: - HUD

/// Small transient status pill.
final class HUD {
    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")
    private var hideWork: DispatchWorkItem?

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 40), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let bg = NSView()
        bg.wantsLayer = true
        bg.layer?.backgroundColor = Palette.glass
        bg.layer?.cornerRadius = 20
        bg.layer?.borderWidth = 1
        bg.layer?.borderColor = Palette.hairline
        label.font = .systemFont(ofSize: 12.5, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.lineBreakMode = .byTruncatingMiddle
        bg.addSubview(label)
        panel.contentView = bg
    }

    func show(_ text: String, for seconds: Double = 2.5) {
        label.stringValue = text
        let w = min(max(label.intrinsicContentSize.width + 40, 150), 560)
        let p = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(p, $0.frame, false) }) ?? NSScreen.main!
        let f = screen.visibleFrame
        let wasVisible = panel.isVisible && panel.alphaValue > 0.5
        panel.setFrame(NSRect(x: f.midX - w / 2, y: f.minY + 72, width: w, height: 40), display: true)
        label.frame = NSRect(x: 14, y: 11, width: w - 28, height: 18)
        if !wasVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }
        }
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; self?.panel.animator().alphaValue = 0 },
                                                 completionHandler: { self?.panel.orderOut(nil) })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}

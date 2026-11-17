import AppKit
import QuartzCore

/// Polls mouse/modifier state (no Accessibility permission needed). During a file drag, holding the
/// gate (Settings > General, Fn by default) and tapping a wheel key opens that wheel; tapping another
/// key swaps it. Idle, it only glances at the mouse button 4 times a second; it polls at 60 Hz only
/// while the button is down.
final class DragWatcher {
    /// urls is non-nil on the first key of a drag.
    var onKey: ((WheelKey, [URL]?, NSPoint) -> Void)?
    var onMouseUp: (() -> Void)?

    static let idleInterval = 0.25, dragInterval = 1.0 / 60
    private var timer: Timer?
    private let dragPB = NSPasteboard(name: .drag)
    private var state = DragState()

    func start() { schedule(Self.idleInterval) }

    private func schedule(_ interval: TimeInterval) {
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = interval / 5
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        let wasDown = state.down
        let t = state.step(down: NSEvent.pressedMouseButtons & 1 != 0, flags: NSEvent.modifierFlags,
                           dragCount: { dragPB.changeCount }, gate: { Gate.current }, keys: { WheelKey.keys })
        if state.down != wasDown {
            schedule(state.down ? Self.dragInterval : Self.idleInterval)
            if !state.down { onMouseUp?() }
        }
        switch t {
        case .none: break
        case .swap(let key): onKey?(key, nil, NSEvent.mouseLocation)
        case .open(let key):
            let urls = dragPB.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            guard !urls.isEmpty else { return }
            state.current = key
            onKey?(key, urls, NSEvent.mouseLocation)
        }
    }
}

/// What the watcher remembers between polls. Pure, so `Rota --selftest` can replay whole drags.
struct DragState {
    var down = false
    var lastFlags: NSEvent.ModifierFlags = []
    /// The drag pasteboard's change count while the button was up: a file drag changes it.
    var baseCount = 0
    /// The wheel showing in this drag; the caller sets it once the drag's files are read.
    var current: WheelKey?

    /// One poll. Keys already held when the button goes down, or changed before the drag starts, are
    /// spent: only a change during a file drag opens or swaps a wheel, as before the gate.
    mutating func step(down now: Bool, flags: NSEvent.ModifierFlags, dragCount: () -> Int,
                       gate: () -> Gate, keys: () -> [WheelKey: Modifier]) -> Trigger {
        guard now else {
            down = false; current = nil; lastFlags = flags
            baseCount = dragCount()
            return .none
        }
        guard down else { down = true; lastFlags = flags; return .none }
        guard Trigger.held(flags) != Trigger.held(lastFlags) else { return .none }
        defer { lastFlags = flags }
        guard dragCount() != baseCount else { return .none }
        let t = Trigger.decide(flags, previous: lastFlags, gate: gate(), keys: keys(), current: current)
        if case .swap(let k) = t { current = k }
        return t
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
        case .pdf:   return (hex(0xFF3B5C), hex(0xFF7EB0))   // crimson → rose
        case .document: return (hex(0x3A7BFF), hex(0x5CC8FF)) // ink blue → sky
        case .slides: return (hex(0xFF8A00), hex(0xFFD15C))   // amber → gold
        case .sheet: return (hex(0x1FB36B), hex(0xA6E35C))    // green → lime
        case .archive: return (hex(0xA77B5C), hex(0xE0B98A))  // walnut → sand
        case .other: return (hex(0x4F8CFF), hex(0x9C7BFF))   // azure → iris
        }
    }
    static let glass = NSColor(srgbRed: 0.07, green: 0.07, blue: 0.085, alpha: 0.9).cgColor
    static let hairline = NSColor(white: 1, alpha: 0.11).cgColor
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
        // Room for the largest wheel, so a swap mid-drag stays on screen too. Places is left out unless
        // it is the one showing: building it checks every folder on disk.
        let pages = [page] + WheelKey.allCases.filter { $0 != .places && $0 != key }.map { Actions.page(for: $0, urls: urls) }
        let r = pages.map(WheelView.outerRadius).max() ?? 0
        let screen = NSScreen.screens.first(where: { NSMouseInRect(p, $0.frame, false) }) ?? NSScreen.main
        setFrameOrigin(screen.map { Self.origin(centre: p, radius: r, in: $0.visibleFrame) }
                       ?? NSPoint(x: p.x - WheelView.size / 2, y: p.y - WheelView.size / 2))
        alphaValue = 1
        orderFrontRegardless()
        wheel.present(page: page, key: key, colors: Palette.colors(for: urls), count: urls.count)
    }

    /// Panel origin that centres the wheel on p, moved in just enough that a wheel of radius r stays
    /// inside the screen's visible frame (clear of the menu bar, the notch and the Dock).
    static func origin(centre p: NSPoint, radius r: CGFloat, in f: NSRect) -> NSPoint {
        let m = r + 6, s = WheelView.size
        return NSPoint(x: min(max(p.x, f.minX + m), f.maxX - m) - s / 2,
                       y: min(max(p.y, f.minY + m), f.maxY - m) - s / 2)
    }

    func hide(picked: Bool = false) {
        guard isVisible, !wheel.leaving else { return }
        wheel.dismiss(picked: picked) { [weak self] in self?.orderOut(nil) }
    }
}

// MARK: - Wheel

final class WheelView: NSView {
    static let size: CGFloat = 620
    static let band: CGFloat = 34      // half the ring thickness
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
        accentRim.lineWidth = 1.25
        accentRim.opacity = 0.6

        hiGradient.type = .axial
        hiGradient.startPoint = CGPoint(x: 0.3, y: 1)
        hiGradient.endPoint = CGPoint(x: 0.7, y: 0.55)
        hiMask.fillColor = NSColor.black.cgColor
        hiMask.strokeColor = NSColor.black.cgColor
        hiMask.lineJoin = .round
        hiGradient.mask = hiMask
        highlight.addSublayer(hiGradient)
        highlight.shadowOpacity = 0.55
        highlight.shadowRadius = 14
        highlight.shadowOffset = .zero
        highlight.opacity = 0

        for l in [titleLayer, detailLayer, legend] {
            l.alignmentMode = .center
            l.isWrapped = true
            l.truncationMode = .end
        }
        titleLayer.frame = CGRect(x: c.x - 60, y: c.y + 22, width: 120, height: 14)
        detailLayer.frame = CGRect(x: c.x - 62, y: c.y - 30, width: 124, height: 48)
        legend.frame = CGRect(x: c.x - 60, y: c.y - 52, width: 120, height: 16)

        [ring, sheen, rim, disk, accentRim, highlight, pageLayer, titleLayer, detailLayer, legend].forEach(root.addSublayer)
        applyGeometry(animated: false)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        [titleLayer, detailLayer, legend].forEach { $0.contentsScale = scale }
    }

    /// Mid radius of each ring and the centre disk's radius for these rings.
    static func radii(_ rings: [[Action]]) -> (mids: [CGFloat], disk: CGFloat) {
        let n0 = CGFloat(rings.first?.count ?? 0)
        let m0 = min(max(126, n0 * slice / (2 * .pi)), 205)
        var m1 = m0
        if rings.count > 1 {
            m1 = min(max(m0 + 2 * band + ringGap, CGFloat(rings[1].count) * slice / (2 * .pi)), 240)
        }
        return ([m0, m1], min(m0 - band - 8, 96))
    }

    static func outerRadius(_ page: WheelPage) -> CGFloat {
        let rings = page.rings.filter { !$0.isEmpty }
        return radii(rings).mids[rings.count > 1 ? 1 : 0] + band
    }

    private func fitRadii() { (mids, diskR) = Self.radii(rings) }

    private func applyGeometry(animated: Bool) {
        fitRadii()
        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(0.2)
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
        pop.damping = 26; pop.stiffness = 480; pop.mass = 0.6
        pop.duration = pop.settlingDuration
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0; fade.toValue = 1; fade.duration = 0.1
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
        g.duration = picked ? 0.18 : 0.1
        g.timingFunction = CAMediaTimingFunction(name: .easeIn)
        g.fillMode = .forwards
        g.isRemovedOnCompletion = false
        if picked {
            let flash = CABasicAnimation(keyPath: "opacity")
            flash.fromValue = 1; flash.toValue = 0.35; flash.duration = 0.07; flash.autoreverses = true
            highlight.add(flash, forKey: "flash")
            g.beginTime = CACurrentMediaTime() + 0.06
        }
        root.add(g, forKey: "out")
        CATransaction.commit()
    }

    // MARK: Labels

    /// A label is an icon over one line of text.
    static let iconSide: CGFloat = 16, textHeight: CGFloat = 12, labelHeight: CGFloat = 29
    /// Ink keeps this far inside its ring.
    static let labelInset: CGFloat = 3

    static func styled(_ t: String, _ s: CGFloat) -> NSAttributedString {
        NSAttributedString(string: t, attributes: [
            .font: NSFont.systemFont(ofSize: s, weight: .semibold), .foregroundColor: NSColor.white, .kern: s * 0.05])
    }

    static func textWidth(_ t: String, _ s: CGFloat) -> CGFloat { ceil(styled(t, s).size().width) + 2 }

    private func angle(ring r: Int, index i: Int) -> CGFloat { (90 - CGFloat(i) * step(r)) * .pi / 180 }

    /// A label's ink at slot (r, i), relative to the centre: the text line and the icon above it,
    /// slid up or down so the ink sits evenly about the ring's mid line.
    private func ink(ring r: Int, index i: Int, width w: CGFloat) -> [CGRect] {
        let a = angle(ring: r, index: i), m = mids[r]
        let x = m * cos(a), y = m * sin(a)
        func rects(_ dy: CGFloat) -> [CGRect] {
            let y0 = y + dy - Self.labelHeight / 2
            return [CGRect(x: x - w / 2, y: y0, width: w, height: Self.textHeight),
                    CGRect(x: x - Self.iconSide / 2, y: y0 + Self.labelHeight - Self.iconSide, width: Self.iconSide, height: Self.iconSide)]
        }
        // Near 3 and 9 o'clock height barely moves the ink radially: keep the stack centred there.
        guard abs(sin(a)) > 0.25 else { return rects(0) }
        var lo: CGFloat = -12, hi: CGFloat = 12
        for _ in 0..<16 {
            let mid = (lo + hi) / 2, (near, far) = Self.radialSpan(rects(mid))
            if (near + far > 2 * m) == (sin(a) > 0) { hi = mid } else { lo = mid }
        }
        return rects((lo + hi) / 2)
    }

    /// The nearest and farthest any of the rects comes to the centre.
    private static func radialSpan(_ rects: [CGRect]) -> (near: CGFloat, far: CGFloat) {
        (rects.map { b in hypot(min(max(0, b.minX), b.maxX), min(max(0, b.minY), b.maxY)) }.min()!,
         rects.flatMap { b in [b.minX, b.maxX].flatMap { x in [b.minY, b.maxY].map { hypot(x, $0) } } }.max()!)
    }

    /// How far the ink pokes out of ring r (inset included), or nil if it sits inside.
    private func spill(_ rects: [CGRect], ring r: Int) -> String? {
        let lo = mids[r] - Self.band + Self.labelInset, hi = mids[r] + Self.band - Self.labelInset
        let (near, far) = Self.radialSpan(rects)
        if near < lo { return String(format: "%.1f pt over the inner edge", lo - near) }
        if far > hi { return String(format: "%.1f pt over the outer edge", far - hi) }
        return nil
    }

    private static func overlap(_ a: [CGRect], _ b: [CGRect]) -> Bool {
        a.contains { x in b.contains { x.insetBy(dx: -1.5, dy: -1.5).intersects($0) } }
    }

    /// One type size per ring, the largest (9 down to 7.5 pt) at which every label fits inside the ring
    /// and clear of its neighbours; labels that still don't fit at 7.5 pt are shortened with "…".
    private func fittedTitles(ring r: Int) -> (size: CGFloat, titles: [String]) {
        let n = rings[r].count
        func clash(_ i: Int, _ ws: [CGFloat]) -> Bool {
            let me = ink(ring: r, index: i, width: ws[i])
            if spill(me, ring: r) != nil { return true }
            return Set([(i + n - 1) % n, (i + 1) % n]).subtracting([i])
                .contains { Self.overlap(me, ink(ring: r, index: $0, width: ws[$0])) }
        }
        var titles = rings[r].map { $0.title.uppercased() }
        for size in stride(from: CGFloat(9), through: 7.5, by: -0.5) {
            var ws = titles.map { Self.textWidth($0, size) }
            if !ws.indices.contains(where: { clash($0, ws) }) { return (size, titles) }
            guard size == 7.5 else { continue }
            while let i = ws.indices.filter({ clash($0, ws) && titles[$0].count > 3 }).max(by: { ws[$0] < ws[$1] }) {
                titles[i] = String(titles[i].dropLast(titles[i].hasSuffix("…") ? 2 : 1)) + "…"
                ws[i] = Self.textWidth(titles[i], size)
            }
            return (size, titles)
        }
        return (7.5, titles)
    }

    private func makeLabel(_ a: Action, title: String, size: CGFloat, ring r: Int, index i: Int) -> CALayer {
        let tw = Self.textWidth(title, size), w = max(tw, Self.iconSide)
        let t = ink(ring: r, index: i, width: tw)[0]
        let item = CALayer()
        item.bounds = CGRect(x: 0, y: 0, width: w, height: Self.labelHeight)
        item.position = CGPoint(x: c.x + t.midX, y: c.y + t.minY + Self.labelHeight / 2)
        item.name = title
        let icon = CALayer()
        icon.frame = CGRect(x: (w - Self.iconSide) / 2, y: Self.labelHeight - Self.iconSide, width: Self.iconSide, height: Self.iconSide)
        icon.contentsGravity = .resizeAspect
        icon.contents = NSImage(systemSymbolName: a.symbol, accessibilityDescription: a.title)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular).applying(.init(paletteColors: [.white])))
            ?? NSImage(systemSymbolName: "circle", accessibilityDescription: nil)
        icon.contentsScale = scale
        let text = CATextLayer()
        text.frame = CGRect(x: (w - tw) / 2, y: 0, width: tw, height: Self.textHeight)
        text.alignmentMode = .center
        text.contentsScale = scale
        text.string = Self.styled(title, size)
        item.addSublayer(icon)
        item.addSublayer(text)
        item.opacity = Self.labelRest
        return item
    }

    static let labelRest: Float = 0.8

    /// Every label that spills out of its ring or overlaps another, as text; empty when the layout is
    /// clean. `Rota --selftest` runs this over every wheel.
    func layoutProblems() -> [String] {
        var out: [String] = [], all: [(String, [CGRect])] = []
        for (r, row) in labels.enumerated() {
            for l in row {
                // Measured from the layers as drawn (icon and text), not from the layout's own maths.
                let rects = (l.sublayers ?? []).map { l.convert($0.frame, to: root).offsetBy(dx: -c.x, dy: -c.y) }
                if let s = spill(rects, ring: r) { out.append("\(page.title) ring \(r + 1) \(l.name ?? "?"): \(s)") }
                all.append((l.name ?? "?", rects))
            }
        }
        for i in all.indices { for j in all.indices where j > i && Self.overlap(all[i].1, all[j].1) {
            out.append("\(page.title): \(all[i].0) overlaps \(all[j].0)")
        } }
        return out
    }

    /// Labels drawn shortened ("…") or below the 9 pt default, for the selftest's notes.
    var labelNotes: [String] {
        labels.flatMap { $0 }.compactMap { l in
            guard let t = l.sublayers?.compactMap({ $0 as? CATextLayer }).first?.string as? NSAttributedString,
                  let f = t.attribute(.font, at: 0, effectiveRange: nil) as? NSFont else { return nil }
            return f.pointSize < 9 || t.string.hasSuffix("…") ? "\(t.string) \(f.pointSize) pt" : nil
        }
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
            let (size, titles) = fittedTitles(ring: r)
            let row = acts.indices.map { makeLabel(acts[$0], title: titles[$0], size: size, ring: r, index: $0) }
            row.forEach(page.addSublayer)
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
        out.duration = 0.09
        out.timingFunction = CAMediaTimingFunction(name: .easeIn)
        out.fillMode = .forwards
        out.isRemovedOnCompletion = false
        CATransaction.begin()
        CATransaction.setCompletionBlock { old.removeFromSuperlayer() }
        old.add(out, forKey: "out")
        CATransaction.commit()

        let t0 = CACurrentMediaTime() + 0.07
        let inRot = CASpringAnimation(keyPath: "transform.rotation.z")
        inRot.fromValue = -0.5 * dir; inRot.toValue = 0
        inRot.damping = 26; inRot.stiffness = 420; inRot.mass = 0.6
        inRot.duration = inRot.settlingDuration
        let inOp = CABasicAnimation(keyPath: "opacity")
        inOp.fromValue = 0; inOp.toValue = 1; inOp.duration = 0.12
        for a in [inRot, inOp] as [CAAnimation] { a.beginTime = t0; a.fillMode = .backwards }
        page.add(inRot, forKey: "inRot")
        page.add(inOp, forKey: "inOp")

        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 0.15; pulse.toValue = 0.55; pulse.duration = 0.28
        accentRim.add(pulse, forKey: "pulse")
    }

    private func staggerLabels() {
        let now = CACurrentMediaTime()
        for (i, l) in labels.flatMap({ $0 }).enumerated() {
            let sc = CASpringAnimation(keyPath: "transform.scale")
            sc.fromValue = 0.55; sc.toValue = 1
            sc.damping = 24; sc.stiffness = 420; sc.mass = 0.6
            sc.duration = sc.settlingDuration
            let op = CABasicAnimation(keyPath: "opacity")
            op.fromValue = 0; op.toValue = Self.labelRest; op.duration = 0.12
            for a in [sc, op] as [CAAnimation] { a.beginTime = now + 0.02 + Double(i) * 0.008; a.fillMode = .backwards }
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
        CATransaction.setAnimationDuration(0.12)
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
                spin.damping = 28; spin.stiffness = 560; spin.mass = 0.5
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
            labels.flatMap { $0 }.forEach { $0.opacity = Self.labelRest; $0.transform = CATransform3DIdentity }
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
            .font: NSFont.systemFont(ofSize: 9, weight: .bold), .foregroundColor: colors.1, .kern: 1.8,
            .paragraphStyle: para])

        let detail = NSMutableAttributedString()
        if let a = action(at: hovered) {
            detail.append(NSAttributedString(string: a.detail, attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white,
                .paragraphStyle: para]))
        } else {
            detail.append(NSAttributedString(string: fileCount == 1 ? "1 file" : "\(fileCount) files", attributes: [
                .font: NSFont.systemFont(ofSize: 14, weight: .semibold), .foregroundColor: NSColor.white,
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
                .font: NSFont.systemFont(ofSize: 11, weight: k == key ? .bold : .regular),
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

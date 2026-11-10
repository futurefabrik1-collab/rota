import AppKit
import ServiceManagement
import SwiftUI

// CLI:  Rota --list <files…> | --run <action-id> <files…> | --login-on | --login-off
let args = CommandLine.arguments
if args.count == 2, args[1] == "--login-on" || args[1] == "--login-off" {
    do {
        if args[1] == "--login-on" { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        print("login item:", SMAppService.mainApp.status == .enabled ? "enabled" : "disabled (\(SMAppService.mainApp.status.rawValue))")
        exit(0)
    } catch { print("error:", error.localizedDescription); exit(1) }
}
// Rota --render <convert|tools|share|places> <out.png> <files…> — draws the wheel offscreen.
if args.count >= 4, args[1] == "--render" {
    let key = WheelKey(rawValue: args[2]) ?? .convert
    let files = args.dropFirst(4).map { URL(fileURLWithPath: $0) }
    let v = WheelView(frame: NSRect(x: 0, y: 0, width: WheelView.size, height: WheelView.size))
    v.present(page: Actions.page(for: key, urls: Array(files)), key: key, colors: Palette.colors(for: Array(files)), count: files.count)
    let px = Int(WheelView.size * 2)
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(NSColor(white: 0.93, alpha: 1).cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: px, height: px))
    ctx.scaleBy(x: 2, y: 2)
    v.layer!.render(in: ctx)
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[3]))
    exit(0)
}
// Rota --settings-shot <tab 0-2> <out.png> — renders the Settings window offscreen.
if args.count == 4, args[1] == "--settings-shot" {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let host = NSHostingController(rootView: SettingsView(model: SettingsModel(onChange: {}), tab: Int(args[2]) ?? 0))
    let w = NSWindow(contentViewController: host)
    w.styleMask = [.titled]
    w.setContentSize(NSSize(width: 680, height: 560))
    w.setFrameOrigin(NSPoint(x: -6000, y: -6000))
    w.orderFrontRegardless()
    RunLoop.main.run(until: Date().addingTimeInterval(1.0))
    let v = w.contentView!
    let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
    v.cacheDisplay(in: v.bounds, to: rep)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[3]))
    exit(0)
}
if args.count >= 3, args[1] == "--list" || args[1] == "--run" {
    let isRun = args[1] == "--run"
    let files = Array(args.dropFirst(isRun ? 3 : 2).map { URL(fileURLWithPath: $0) })
    if !isRun {
        for k in WheelKey.allCases {
            print("\(k.glyph) \(k.title):", Actions.page(for: k, urls: files).actions.map(\.id).joined(separator: " "))
        }
        exit(0)
    }
    guard let a = Actions.all.first(where: { $0.id == args[2] })
            ?? Actions.page(for: .places, urls: files).actions.first(where: { $0.id == args[2] }) else { print("unknown action \(args[2])"); exit(2) }
    let r = Runner.run(a, files)
    r.outputs.forEach { print("OUT  \($0.path)") }
    r.notes.forEach { print("NOTE \($0)") }
    r.skipped.forEach { print("SKIP \($0)") }
    r.errors.forEach { print("ERR  \($0)") }
    exit(r.errors.isEmpty ? 0 : 1)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let watcher = DragWatcher()
    let panel = WheelPanel()
    let hud = HUD()
    var status: NSStatusItem!
    var busy = 0
    var dragURLs: [URL] = []
    let work = DispatchQueue(label: "rota.work", qos: .userInitiated)

    func applicationDidFinishLaunching(_ n: Notification) {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.image = NSImage(systemSymbolName: "circle.dashed.inset.filled", accessibilityDescription: "Rota")
        buildMenu()

        watcher.onKey = { [weak self] key, urls, p in
            guard let self else { return }
            if let urls { self.dragURLs = urls }
            let page = Actions.page(for: key, urls: self.dragURLs)
            if self.panel.isVisible && !self.panel.wheel.leaving {
                self.panel.wheel.swap(to: page, key: key)
            } else {
                self.panel.show(page: page, key: key, urls: self.dragURLs, at: p)
            }
        }
        watcher.onMouseUp = { [weak self] in
            // Give performDragOperation time to land before hiding.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self?.panel.hide() }
        }
        panel.wheel.onPick = { [weak self] a, urls in self?.perform(a, urls) }
        watcher.start()

        if !UserDefaults.standard.bool(forKey: "welcomed2") {
            UserDefaults.standard.set(true, forKey: "welcomed2")
            hud.show("Rota: drag files, tap ⇧ ⌃ ⌘ or ⌥", for: 5)
        }
    }

    func perform(_ a: Action, _ urls: [URL]) {
        panel.hide(picked: true)
        if a.onMain {
            // Let the wheel finish leaving before a picker or share sheet appears.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.report(Runner.run(a, urls), a) }
            return
        }
        busy += 1
        updateStatus(nil)
        if !a.quiet { hud.show("\(a.detail) — \(urls.count) file\(urls.count == 1 ? "" : "s")…", for: 30) }
        work.async {
            let r = Runner.run(a, urls) { i, n in
                DispatchQueue.main.async { self.updateStatus(n > 1 ? "\(i + 1)/\(n)" : nil) }
            }
            DispatchQueue.main.async {
                self.busy -= 1
                self.updateStatus(nil)
                self.report(r, a)
            }
        }
    }

    func report(_ r: Runner.Report, _ a: Action) {
        var parts: [String] = r.notes
        if !r.outputs.isEmpty {
            parts.append("✓ \(r.outputs.count == 1 ? r.outputs[0].lastPathComponent : "\(r.outputs.count) files")")
        }
        if !r.skipped.isEmpty { parts.append(r.skipped.count == 1 && r.outputs.isEmpty ? r.skipped[0] : "\(r.skipped.count) skipped") }
        if !r.errors.isEmpty { parts.append(r.errors.count == 1 ? "⚠︎ \(r.errors[0])" : "⚠︎ \(r.errors.count) failed — see log") }
        if !parts.isEmpty { hud.show(parts.joined(separator: " · "), for: r.errors.isEmpty ? 2.5 : 6) }
        if UserDefaults.standard.bool(forKey: "reveal"), !r.outputs.isEmpty, !a.quiet {
            NSWorkspace.shared.activateFileViewerSelecting(r.outputs)
        }
    }

    func updateStatus(_ text: String?) {
        status.button?.title = busy > 0 ? " \(text ?? "…")" : ""
    }

    // MARK: Menu

    func buildMenu() {
        let m = NSMenu()
        m.addItem(withTitle: "Drag files, then tap a key:", action: nil, keyEquivalent: "").isEnabled = false
        for k in WheelKey.allCases {
            m.addItem(withTitle: "   \(k.glyph)  \(k.title)", action: nil, keyEquivalent: "").isEnabled = false
        }
        m.addItem(.separator())
        m.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        m.addItem(withTitle: "Show Log", action: #selector(showLog), keyEquivalent: "")
        m.addItem(.separator())
        m.addItem(withTitle: "Quit Rota", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        m.items.forEach { if $0.action != #selector(NSApplication.terminate(_:)) { $0.target = self } }
        status.menu = m
    }

    /// Opening the app again (Finder, Spotlight, Launchpad) brings up Settings — handy when the
    /// menu-bar icon is hidden behind the notch.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return false
    }

    @objc func openSettings() {
        SettingsWindow.shared.onChange = { [weak self] in self?.buildMenu() }
        SettingsWindow.shared.show()
    }

    @objc func showLog() {
        if !FileManager.default.fileExists(atPath: Log.url.path) { Log.write("log created") }
        NSWorkspace.shared.open(Log.url)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

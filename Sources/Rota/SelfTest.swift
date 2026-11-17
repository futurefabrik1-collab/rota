import AppKit

/// `Rota --selftest`: the activation gate, every wheel's layout and the screen-edge placement, checked
/// headless. It reads settings (for Places) but never writes them, and touches no mouse or keyboard.
enum SelfTest {
    static func run() -> Bool {
        var failed = 0
        func check(_ ok: Bool, _ what: String) {
            print(ok ? "ok   " : "FAIL ", what)
            if !ok { failed += 1 }
        }

        // MARK: Gate
        let keys: [WheelKey: Modifier] = [.convert: .shift, .tools: .command, .share: .control, .places: .option]
        func d(_ f: NSEvent.ModifierFlags, _ p: NSEvent.ModifierFlags, _ g: Gate, open: WheelKey? = nil,
               keys k: [WheelKey: Modifier]? = nil) -> Trigger {
            Trigger.decide(f, previous: p, gate: g, keys: k ?? keys, current: open)
        }
        check(d([.shift], [], .function) == .none, "fn gate: a plain ⇧ drag opens nothing")
        check(d([.command], [], .function) == .none, "fn gate: a plain ⌘ drag opens nothing")
        check(d([.option], [], .function) == .none, "fn gate: a ⌥ copy-drag opens nothing")
        check(d([.function, .shift], [.function], .function) == .open(.convert), "fn held, then ⇧ → Convert")
        check(d([.function, .shift], [.shift], .function) == .open(.convert), "⇧ held, then fn → Convert")
        check(d([.function, .shift], [], .function) == .open(.convert), "fn and ⇧ together → Convert")
        check(d([.function, .command], [.function], .function, open: .convert) == .swap(.tools),
              "fn held with Convert open, then ⌘ → swap to Tools")
        check(d([.shift], [.function, .shift], .function, open: .convert) == .none,
              "fn released mid-drag: Convert stays (until mouse-up)")
        check(d([], [.shift], .function, open: .convert) == .none, "every key released: the wheel stays until mouse-up")
        check(d([.command], [], .function, open: .convert) == .swap(.tools), "a wheel is open: ⌘ alone swaps, no gate needed")
        check(d([.function], [], .function) == .none, "fn alone opens nothing")
        check(d([.function, .shift, .command], [.function, .shift], .function) == .none, "fn with two wheel keys: nothing")
        check(d([.function, .shift, .capsLock], [.function], .function) == .open(.convert), "caps lock is ignored")
        check(d([.function, .numericPad, .shift], [.shift], .function) == .none,
              "an arrow key's .function (it comes with .numericPad) is not the fn key")
        check(d([.function, .shift], [.function, .shift], .function) == .none, "no change in the keys: nothing")
        for (k, f) in [(WheelKey.convert, NSEvent.ModifierFlags.shift), (.tools, .command), (.share, .control), (.places, .option)] {
            check(d(f, [], .none) == .open(k), "no gate: \(k.modifier.glyph) alone → \(k.title), as before")
        }
        check(d([.shift, .command], [.shift], .none) == .none, "no gate: ⇧⌘ together → nothing")
        let opt = Gate.reassigned(keys, gate: .option)
        check(opt[.places] == .function && opt[.convert] == .shift && opt[.tools] == .command && opt[.share] == .control,
              "⌥ gate: Places moves from ⌥ to fn, the others keep their keys")
        check(d([.option], [], .option, keys: opt) == .none, "⌥ gate: ⌥ alone (a copy-drag) opens nothing")
        check(d([.option, .shift], [.option], .option, keys: opt) == .open(.convert), "⌥ gate: ⌥ then ⇧ → Convert")
        check(d([.option, .function], [.option], .option, keys: opt) == .open(.places), "⌥ gate: ⌥ then fn → Places")
        check(Gate.reassigned(opt, gate: .function)[.places] == .option, "back to the fn gate: Places returns to ⌥")
        check(Gate.reassigned(keys, gate: .none) == keys && Gate.reassigned(keys, gate: .function) == keys,
              "fn or no gate: the default keys stay")

        // MARK: Whole drags: DragState over a run of polls (button down, keys, drag pasteboard count;
        // the count moves from 0 to 1 when a file drag starts)
        func replay(_ gate: Gate, _ polls: [(Bool, NSEvent.ModifierFlags, Int)]) -> [Trigger] {
            var st = DragState()
            return polls.compactMap { down, f, n in
                let t = st.step(down: down, flags: f, dragCount: { n }, gate: { gate }, keys: { keys })
                if case .open(let k) = t { st.current = k }  // the watcher does this once it has the files
                return t == .none ? nil : t
            }
        }
        check(replay(.none, [(false, [.option], 0), (true, [.option], 0), (true, [.option], 1), (true, [.option], 1)]).isEmpty,
              "no gate: ⌥ held before the button goes down (a copy-drag) opens nothing, as before")
        check(replay(.none, [(false, [], 0), (true, [], 0), (true, [.command], 0), (true, [.command], 1)]).isEmpty,
              "no gate: ⌘ pressed before the drag starts is spent, as before")
        check(replay(.none, [(false, [], 0), (true, [], 0), (true, [], 1), (true, [.shift], 1)]) == [.open(.convert)],
              "no gate: ⇧ tapped during the drag → Convert")
        check(replay(.function, [(false, [], 0), (true, [], 0), (true, [], 1), (true, [.function], 1),
                                 (true, [.function, .shift], 1), (true, [.function, .command], 1)]) == [.open(.convert), .swap(.tools)],
              "fn gate: drag, hold fn, tap ⇧ → Convert, then ⌘ → Tools")
        check(replay(.function, [(false, [], 0), (true, [], 0), (true, [.function, .shift], 0), (true, [.function, .command], 0)]).isEmpty,
              "fn gate: holding the button without a file drag opens nothing")
        check(replay(.function, [(false, [], 0), (true, [], 0), (true, [], 1), (true, [.function, .shift], 1), (true, [.shift], 1),
                                 (true, [], 1)]) == [.open(.convert)],
              "fn gate: letting go of fn, then ⇧, leaves Convert open")
        check(replay(.function, [(false, [], 0), (true, [], 0), (true, [], 1), (true, [.function, .shift], 1), (false, [], 1),
                                 (true, [], 1), (true, [], 2), (true, [.command], 2)]) == [.open(.convert)],
              "after mouse-up the next drag starts closed: ⌘ alone opens nothing")

        // MARK: Layout
        let v = WheelView(frame: NSRect(x: 0, y: 0, width: WheelView.size, height: WheelView.size))
        var notes = Set<String>()
        func layout(_ page: WheelPage, _ key: WheelKey, _ urls: [URL], _ what: String) {
            v.present(page: page, key: key, colors: Palette.colors(for: urls), count: urls.count)
            let p = v.layoutProblems()
            check(p.isEmpty, "\(what): \(page.actions.count) labels inside their rings, none overlapping"
                  + (p.isEmpty ? "" : ": " + p.joined(separator: "; ")))
            notes.formUnion(v.labelNotes)
        }
        let samples = [["a.jpg"], ["a.png"], ["a.heic"], ["a.mp4"], ["a.wav"], ["a.mp3"], ["a.pdf"], ["a.docx"], ["a.md"],
                       ["a.key"], ["a.numbers"], ["a.zip"], ["a.jpg", "b.jpg"], ["a.mp4", "b.mp4"], ["a.wav", "b.wav"],
                       ["a.pdf", "b.pdf"], ["a.jpg", "b.mp4"], ["a.xyz"]]
        for files in samples {
            let urls = files.map { URL(fileURLWithPath: "/nonexistent/rota-selftest/\($0)") }
            for k in WheelKey.allCases {
                layout(Actions.page(for: k, urls: urls), k, urls, "\(k.title) · \(files.joined(separator: " + "))")
            }
        }
        // Long custom place names on two full rings.
        let names = ["Client Projects 2026", "Downloads", "Very Long Folder Name", "Desktop", "Archive", "Music", "Photos", "Invoices"]
        func place(_ t: String) -> Action { Action(id: "place:\(t)", title: t, symbol: "folder", detail: t, kinds: Actions.anyKind) }
        let png = [URL(fileURLWithPath: "/nonexistent/a.png")]
        layout(WheelPage(title: "Places", rings: [names.map(place), names.reversed().map(place) + [place("Choose…")]]), .places, png,
               "Places · 8 long favourites and 8 recents")

        // MARK: Screen edges
        let screens = [NSRect(x: 0, y: 0, width: 1440, height: 875), NSRect(x: -1920, y: 40, width: 1920, height: 1015)]
        let jpg = WheelView.outerRadius(Actions.page(for: .convert, urls: [URL(fileURLWithPath: "/nonexistent/a.jpg")]))
        for r in [jpg, 240 + WheelView.band] { for f in screens {
            for p in [NSPoint(x: f.minX, y: f.minY), NSPoint(x: f.maxX, y: f.maxY), NSPoint(x: f.minX, y: f.maxY),
                      NSPoint(x: f.maxX, y: f.minY), NSPoint(x: f.midX, y: f.minY + 3)] {
                let o = WheelPanel.origin(centre: p, radius: r, in: f)
                let c = NSPoint(x: o.x + WheelView.size / 2, y: o.y + WheelView.size / 2)
                check(c.x - r >= f.minX && c.x + r <= f.maxX && c.y - r >= f.minY && c.y + r <= f.maxY,
                      String(format: "a %.0f pt wheel at (%.0f, %.0f) stays on screen", r, p.x, p.y))
            }
            let mid = NSPoint(x: f.midX, y: f.midY), o = WheelPanel.origin(centre: mid, radius: r, in: f)
            check(o.x + WheelView.size / 2 == mid.x && o.y + WheelView.size / 2 == mid.y, "mid-screen: centred on the pointer")
        } }

        if !notes.isEmpty { print("note  smaller or shortened labels:", notes.sorted().joined(separator: ", ")) }
        print(failed == 0 ? "selftest passed" : "selftest FAILED: \(failed)")
        return failed == 0
    }
}

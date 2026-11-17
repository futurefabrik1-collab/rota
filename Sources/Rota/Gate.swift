import AppKit

/// The key held during a drag so that a wheel key opens a wheel. Plain ⇧ ⌘ ⌃ ⌥ drags (copy, alias,
/// multi-select) then never pop a wheel. None keeps the old behaviour: a wheel key alone opens it.
enum Gate: String, CaseIterable, Identifiable {
    case function, option, control, none
    var id: String { rawValue }

    var modifier: Modifier? {
        switch self { case .function: return .function; case .option: return .option
                      case .control: return .control; case .none: return nil }
    }
    var label: String { modifier.map { "\($0.glyph)  \($0.name)" } ?? "None" }

    static var current: Gate {
        get { Gate(rawValue: UserDefaults.standard.string(forKey: "activationGate") ?? "") ?? .function }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "activationGate")
            for (w, m) in reassigned(WheelKey.keys, gate: newValue) where m != w.modifier {
                UserDefaults.standard.set(m.rawValue, forKey: "modifier.\(w.rawValue)")
            }
        }
    }

    /// The gate key can't also open a wheel: the wheel on it moves to the key no wheel uses.
    static func reassigned(_ keys: [WheelKey: Modifier], gate: Gate) -> [WheelKey: Modifier] {
        guard let g = gate.modifier, let w = keys.first(where: { $0.value == g })?.key,
              let free = Modifier.allCases.first(where: { m in m != g && !keys.values.contains(m) }) else { return keys }
        var k = keys
        k[w] = free
        return k
    }

    /// One line for the HUD and the menu: how to open a wheel.
    var hint: String {
        let keys = WheelKey.allCases.map(\.glyph).joined(separator: " ")
        return modifier.map { "Drag files, hold \($0.glyph) and tap \(keys)" } ?? "Drag files, tap \(keys)"
    }
}

/// What a change in the held keys does during a file drag. Pure, so `Rota --selftest` can prove it.
enum Trigger: Equatable {
    case none, open(WheelKey), swap(WheelKey)

    /// - current: the wheel already showing in this drag, if any.
    /// Closed: the gate must be held together with exactly one wheel key. Open: any wheel key swaps,
    /// gate or not. Nothing here closes a wheel: it stays until the mouse button comes up.
    static func decide(_ flags: NSEvent.ModifierFlags, previous: NSEvent.ModifierFlags, gate: Gate,
                       keys: [WheelKey: Modifier], current: WheelKey?) -> Trigger {
        let now = held(flags)
        guard now != held(previous) else { return .none }
        let g = gate.modifier?.flags ?? []
        if current == nil, !now.contains(g) { return .none }
        let rest = now.subtracting(g)
        guard let key = WheelKey.allCases.first(where: { keys[$0]?.flags == rest }), key != current else { return .none }
        return current == nil ? .open(key) : .swap(key)
    }

    /// The modifiers that count. Arrow keys report .function together with .numericPad: that isn't Fn.
    static func held(_ f: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        var h = f.intersection([.shift, .control, .option, .command, .function])
        if f.contains(.numericPad) { h.remove(.function) }
        return h
    }
}

import AppKit
import ServiceManagement
import SwiftUI

// MARK: - Window

final class SettingsWindow {
    static let shared = SettingsWindow()
    private var window: NSWindow?
    var onChange: (() -> Void)?

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: SettingsView(model: SettingsModel(onChange: { [weak self] in self?.onChange?() })))
            let w = NSWindow(contentViewController: host)
            w.title = "Hot Wheel Settings"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.setContentSize(NSSize(width: 680, height: 560))
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Model

final class SettingsModel: ObservableObject {
    let onChange: () -> Void
    init(onChange: @escaping () -> Void) { self.onChange = onChange }

    private func changed() { objectWillChange.send(); onChange() }

    // Wheels
    func actions(for wheel: WheelKey, kind: Kind) -> [Action] {
        let list: [Action]
        switch wheel {
        case .convert: list = Actions.convert + Actions.social
        case .tools: list = Actions.tools
        case .share: list = Actions.share
        case .places: list = []
        }
        return Prefs.sorted(list.filter { wheel == .share || $0.kinds.contains(kind) })
    }

    func isShown(_ a: Action) -> Bool { !Prefs.hidden.contains(a.id) }

    func setShown(_ a: Action, _ on: Bool) {
        var h = Prefs.hidden
        if on { h.remove(a.id) } else { h.insert(a.id) }
        Prefs.hidden = h
        changed()
    }

    func move(_ list: [Action], from: IndexSet, to: Int) {
        var ids = list.map(\.id)
        ids.move(fromOffsets: from, toOffset: to)
        Prefs.reorder(subset: ids)
        changed()
    }

    func setAll(_ list: [Action], shown: Bool) {
        var h = Prefs.hidden
        for a in list { if shown { h.remove(a.id) } else { h.insert(a.id) } }
        Prefs.hidden = h
        changed()
    }

    func resetWheels() { Prefs.resetWheels(); changed() }

    // Places
    var favourites: [URL] { Places.favourites }

    func movePlaces(from: IndexSet, to: Int) {
        var f = Places.favourites
        f.move(fromOffsets: from, toOffset: to)
        Places.favourites = f
        changed()
    }

    func removePlace(_ u: URL) {
        Places.favourites = Places.favourites.filter { $0.path != u.path }
        changed()
    }

    func addPlaces() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = true
        p.prompt = "Add to Places"
        guard p.runModal() == .OK else { return }
        let existing = Set(Places.favourites.map(\.path))
        Places.favourites += p.urls.filter { !existing.contains($0.path) }
        changed()
    }

    func title(for u: URL) -> String { Places.titles[u.path] ?? "" }

    func setTitle(_ t: String, for u: URL) {
        var all = Places.titles
        all[u.path] = t.isEmpty ? nil : t
        Places.titles = all
        changed()
    }

    var recentCount: Int {
        get { Places.recentCount }
        set { Places.recentCount = newValue; changed() }
    }

    var mode: Places.Mode {
        get { Places.mode }
        set { Places.mode = newValue; changed() }
    }

    var recents: [URL] { Places.recents }
    func clearRecents() { Places.clearRecents(); changed() }

    func resetPlaces() {
        UserDefaults.standard.removeObject(forKey: "favouritePlaces")
        UserDefaults.standard.removeObject(forKey: "placeTitles")
        changed()
    }

    // General
    func modifier(for w: WheelKey) -> Modifier { w.modifier }
    func assign(_ m: Modifier, to w: WheelKey) { w.assign(m); changed() }
    func resetKeys() {
        WheelKey.allCases.forEach { UserDefaults.standard.removeObject(forKey: "modifier.\($0.rawValue)") }
        changed()
    }

    var blurFit: Bool {
        get { Social.blurFit }
        set { Social.blurFit = newValue; changed() }
    }

    var reveal: Bool {
        get { UserDefaults.standard.bool(forKey: "reveal") }
        set { UserDefaults.standard.set(newValue, forKey: "reveal"); changed() }
    }

    var openAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do { if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
            catch { NSSound.beep() }
            changed()
        }
    }
}

// MARK: - Views

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @State var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            WheelsTab(model: model).tabItem { Label("Wheels", systemImage: "circle.dashed.inset.filled") }.tag(0)
            PlacesTab(model: model).tabItem { Label("Places", systemImage: "folder") }.tag(1)
            GeneralTab(model: model).tabItem { Label("General", systemImage: "gearshape") }.tag(2)
        }
        .padding(16)
        .frame(width: 680, height: 560)
    }
}

struct WheelsTab: View {
    @ObservedObject var model: SettingsModel
    @State private var wheel: WheelKey = .convert
    @State private var kind: Kind = .image

    private let kindsFor: [WheelKey: [Kind]] = [
        .convert: [.image, .video, .audio, .pdf, .document, .slides, .sheet],
        .tools: [.image, .video, .audio, .pdf],
    ]

    private func kindName(_ k: Kind) -> String {
        switch k {
        case .image: return "Images"; case .video: return "Video"; case .audio: return "Audio"; case .pdf: return "PDF"
        case .document: return "Documents"; case .slides: return "Slides"; case .sheet: return "Spreadsheets"
        case .archive: return "Archives"; case .other: return "Other"
        }
    }

    var body: some View {
        let list = model.actions(for: wheel, kind: kind)
        VStack(alignment: .leading, spacing: 12) {
            Picker("Wheel", selection: $wheel) {
                ForEach([WheelKey.convert, .tools, .share]) { w in Text("\(w.modifier.glyph)  \(w.title)").tag(w) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: wheel) { _, w in if let ks = kindsFor[w], !ks.contains(kind) { kind = ks[0] } }

            if let ks = kindsFor[wheel] {
                Picker("File type", selection: $kind) {
                    ForEach(ks, id: \.self) { Text(kindName($0)).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            Text("Switch options off to hide them from the wheel. Drag to change their order — the first ones sit at 12 o'clock.")
                .font(.callout).foregroundStyle(.secondary)

            List {
                ForEach(list, id: \.id) { a in
                    HStack(spacing: 10) {
                        Image(systemName: a.symbol).frame(width: 22).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(a.title).fontWeight(.medium)
                                if a.id.hasPrefix("social.") {
                                    Text("SOCIAL").font(.system(size: 9, weight: .bold)).padding(.horizontal, 5).padding(.vertical, 1)
                                        .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                                }
                            }
                            Text(a.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(get: { model.isShown(a) }, set: { model.setShown(a, $0) }))
                            .toggleStyle(.switch).labelsHidden().controlSize(.small)
                    }
                    .padding(.vertical, 2)
                    .opacity(model.isShown(a) ? 1 : 0.5)
                }
                .onMove { model.move(list, from: $0, to: $1) }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))

            HStack {
                Button("Show All") { model.setAll(list, shown: true) }
                Button("Hide All") { model.setAll(list, shown: false) }
                Spacer()
                Button("Restore Default Wheels") { model.resetWheels() }
            }
        }
    }
}

struct PlacesTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Favourite places fill the inner ring of the \(WheelKey.places.modifier.glyph) Places wheel. Drag to reorder; give any of them a short name.")
                .font(.callout).foregroundStyle(.secondary)

            List {
                ForEach(model.favourites, id: \.path) { u in
                    HStack(spacing: 10) {
                        Image(systemName: Places.symbol(for: u)).frame(width: 22).foregroundStyle(.secondary)
                        TextField(Places.defaultName(for: u), text: Binding(get: { model.title(for: u) },
                                                                             set: { model.setTitle($0, for: u) }))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 150)
                        Text(Places.pretty(u)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button { model.removePlace(u) } label: { Image(systemName: "minus.circle.fill") }
                            .buttonStyle(.borderless).foregroundStyle(.secondary).help("Remove")
                    }
                    .padding(.vertical, 2)
                }
                .onMove { model.movePlaces(from: $0, to: $1) }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .frame(minHeight: 200)

            HStack {
                Button { model.addPlaces() } label: { Label("Add Folder…", systemImage: "plus") }
                Spacer()
                Button("Reset to Defaults") { model.resetPlaces() }
            }

            Divider()

            Form {
                Picker("When you drop on a place", selection: Binding(get: { model.mode }, set: { model.mode = $0 })) {
                    ForEach(Places.Mode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Stepper(value: Binding(get: { model.recentCount }, set: { model.recentCount = $0 }), in: 0...8) {
                    Text("Recent places on the outer ring: \(model.recentCount == 0 ? "none" : "\(model.recentCount)")")
                }
                HStack {
                    Text(model.recents.isEmpty ? "No recent places yet." :
                            "Recent: " + model.recents.prefix(model.recentCount).map { Places.name(for: $0) }.joined(separator: ", "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Button("Clear Recents") { model.clearRecents() }.disabled(model.recents.isEmpty)
                }
            }
            .formStyle(.columns)
        }
    }
}

struct GeneralTab: View {
    @ObservedObject var model: SettingsModel

    private let tools: [(String, String)] = [
        ("ffmpeg", "video & audio"), ("cwebp", "WebP"), ("pngquant", "PNG compression"),
        ("qpdf", "PDF split/rotate"), ("gs", "PDF compress, PDF/A, OCR"), ("tesseract", "OCR"),
    ]

    var body: some View {
        Form {
            Section("Keys — tap while dragging files") {
                ForEach(WheelKey.allCases) { w in
                    Picker(w.title, selection: Binding(get: { model.modifier(for: w) }, set: { model.assign($0, to: w) })) {
                        ForEach(Modifier.allCases) { m in Text("\(m.glyph)  \(m.name)").tag(m) }
                    }
                }
                HStack { Spacer(); Button("Default Keys") { model.resetKeys() } }
            }
            Section("Results") {
                Toggle("Reveal results in Finder", isOn: Binding(get: { model.reveal }, set: { model.reveal = $0 }))
                Toggle("Social formats: fit the whole picture over a blurred background (instead of cropping)",
                       isOn: Binding(get: { model.blurFit }, set: { model.blurFit = $0 }))
            }
            Section("System") {
                Toggle("Open Hot Wheel at login", isOn: Binding(get: { model.openAtLogin }, set: { model.openAtLogin = $0 }))
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(tools, id: \.0) { t in
                        HStack(spacing: 6) {
                            Image(systemName: Tools.has(t.0) ? "checkmark.circle.fill" : "xmark.circle")
                                .foregroundStyle(Tools.has(t.0) ? .green : .orange)
                            Text(t.0).font(.system(.body, design: .monospaced))
                            Text("— \(t.1)").foregroundStyle(.secondary)
                        }
                        .font(.callout)
                    }
                    Text("Missing tools: install with Homebrew, e.g. brew install ffmpeg webp pngquant qpdf ghostscript tesseract")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

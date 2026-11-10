# Rota

A free, open-source radial file wheel for macOS. Start dragging files, tap a modifier key, drop onto a slice.

| Key | Wheel |
|-----|-------|
| ⇧ Shift | **Convert** — formats, social-media sizes (1:1, 4:5, 9:16, 16:9 …), favicon, ICNS, PDF ↔ Pages/Word, Keynote, Numbers |
| ⌘ Command | **Tools** — compress, resize, rotate, cut out background, OCR, QR, join, trim, loudness, contact sheets, PDF merge/split/OCR |
| ⌃ Control | **Share** — AirDrop, Messages, Mail, copy path, zip/extract, Quick Look, Terminal, Open With |
| ⌥ Option | **Places** — favourite and recent folders: drop to move or copy |

Every wheel, key, option and place is configurable in **Settings** (menu-bar icon → Settings…, or open the app again).

No Accessibility permission needed. Lives in the menu bar.

## Install

Download the DMG from [Releases](../../releases), drag **Rota** to Applications.
The build is ad-hoc signed, not notarized: on first launch right-click the app → **Open**, or allow it under System Settings → Privacy & Security.

Optional helpers for the full set of conversions (via [Homebrew](https://brew.sh)):

```bash
brew install ffmpeg webp pngquant qpdf ghostscript tesseract tesseract-lang
```

Settings → General shows which helpers were found.

## Build from source

Requires macOS 14+ and Xcode / Swift 5.9+.

```bash
./build.sh            # builds build/Rota.app
./build.sh --install  # also installs to ~/Applications and launches
```

## Licence

MIT. See [LICENSE](LICENSE).

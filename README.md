# Offline Translate for Mac

[![Build](https://github.com/asimon655/offline-translate-mac/actions/workflows/build.yml/badge.svg)](https://github.com/asimon655/offline-translate-mac/actions/workflows/build.yml)
[![Latest release](https://img.shields.io/github/v/release/asimon655/offline-translate-mac?include_prereleases)](https://github.com/asimon655/offline-translate-mac/releases)

> **Beta.** This is an early release. Expect rough edges, and please
> [open an issue](https://github.com/asimon655/offline-translate-mac/issues) if something breaks.

A menu-bar app: select text anywhere, press **⌥⇧T**, and a popup next to the selection shows the
translation. Translation runs entirely on your Mac with Google Translate's offline language packs,
through the [offline-translate](https://github.com/asimon655/offline-translate) Python library.

- **Popup:** doesn't take focus from the app you're in. You can change languages, swap, pin, copy,
  or replace the selection with the translation.
- **Other shortcuts:** translate the clipboard with **⌥⇧V**, or drag over text on screen with
  **⌥⇧O** to read it with OCR.
- **Languages:** the Settings → Languages tab downloads (with progress and cancel), updates and
  removes language packs, about 55 MB each.
- **Speed:** about 30 ms per sentence once a language is loaded. Models you haven't used for a
  while are unloaded to free memory.
- **Distribution:** Apple Silicon, macOS 14 or later. The app is 113 MB with Python bundled, and
  the DMG is 49 MB.

## Install

**Requirements:** a Mac with Apple Silicon (M1 or later) and macOS 14 Sonoma or later.

1. Download the latest `OfflineTranslate-*.dmg` from the
   [Releases page](https://github.com/asimon655/offline-translate-mac/releases) and drag
   **Offline Translate** into Applications.
2. The app isn't notarized by Apple yet, so macOS blocks it the first time you open it. Run this once
   in Terminal:
   ```bash
   xattr -dr com.apple.quarantine "/Applications/Offline Translate.app"
   ```
   Or open the app, then allow it under System Settings → Privacy & Security → **Open Anyway**.
3. Open the app and follow the Welcome window.

When you install a new version, macOS may ask for the Accessibility permission again. If the
shortcut stops working, remove the old entry in System Settings → Privacy & Security →
Accessibility and add the app again.

## Using it

On first launch the Welcome window walks through three steps:

1. **Accessibility permission.** It's needed to read the selection and to post ⌘C/⌘V.
2. **The shortcut.**
3. **A first language,** followed by a test sentence.

After that the app lives in the menu bar.

- **Choosing the target language:** text in a foreign language is translated into your language,
  set under *Translate Into* in the menu or Settings. Text already in your language goes to the
  last other language you picked. A language you choose in the popup is remembered for that
  source language.
- **Apps that hide their selection:** some Electron and Java apps don't expose the selected text
  through Accessibility. For those the app sends ⌘C and restores the clipboard afterwards. You can
  turn this off in Settings.
- **Password fields:** they're skipped, because macOS keeps secure input private.
- **On-screen text:** OCR uses Apple's Vision framework, which reads about 30 languages. Hebrew
  isn't one of them.
- **Where things are stored:**
  - Language packs: `~/Library/Application Support/OfflineTranslate/models`
  - History: `~/Library/Application Support/OfflineTranslate/history.json`
  - Bytecode cache: `~/Library/Caches/OfflineTranslate`
- **Different models folder:** run `defaults write com.asimon655.OfflineTranslate modelsDir /path`.

## Build from source

You need the Xcode **Command Line Tools** and [uv](https://docs.astral.sh/uv/). Xcode itself isn't
required. The [offline-translate](https://github.com/asimon655/offline-translate) library is
expected in a sibling folder:

```bash
git clone https://github.com/asimon655/offline-translate ../offline-translate
cd ../offline-translate && uv venv -p 3.14 && uv pip install -e . && cd -
```

Then:

```bash
scripts/build-app.sh --dev     # quick: the app runs the helper from ../offline-translate/.venv
scripts/build-app.sh           # release: bundles Python 3.14 + offline-translate into the app
scripts/build-app.sh --dmg     # release + dist/OfflineTranslate-<version>.dmg + Homebrew cask
open "build/Offline Translate.app"
```

The release build gets a relocatable Python
([python-build-standalone](https://github.com/astral-sh/python-build-standalone)) through `uv`.
It installs the library from `LIB_DIR` (default `../offline-translate`), trims the result and
signs every nested binary.

Signing and notarization:

```bash
SIGN_ID="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=notary scripts/build-app.sh --dmg
```

`NOTARY_PROFILE` is a profile created with
`xcrun notarytool store-credentials notary --apple-id … --team-id …`. Without `SIGN_ID` the app is
ad-hoc signed, which is fine on your own Mac.

macOS ties the Accessibility permission to the app's signature, and an ad-hoc signature changes on
every build. To keep the permission while developing, create a self-signed code-signing
certificate named **OfflineTranslate Dev** in your login keychain (Keychain Access → Certificate
Assistant → Create a Certificate…, type "Code Signing"). `build-app.sh` uses it automatically when
it's there.

### Tests

```bash
scripts/swift test
OT_TEST_PYTHON=../offline-translate/.venv/bin/python OT_TEST_MODELS=../offline-translate/models scripts/swift test
```

The second form adds an end-to-end test against the real helper and models. The helper protocol
itself is tested in the library repo (`tests/test_helper.py`).

### Why `scripts/swift` and not `swift`?

Two workarounds for building without Xcode:

- **Stale manifest files.** Some Command Line Tools installs still contain 2024
  `*.private.swiftinterface` files, which break every `Package.swift` with Swift 6.4
  ("Undefined symbols … PackageDescription.Package.__allocating_init"). `scripts/swift` runs SwiftPM
  with a cleaned copy of those libraries. The permanent fix is
  `sudo rm /Library/Developer/CommandLineTools/usr/lib/swift/pm/*/*.swiftmodule/*.private.swiftinterface`.
- **No `@State`.** In the macOS 27 SDK, SwiftUI's `@State` is a macro whose compiler plugin ships
  only with Xcode. Views keep their local state in small `ObservableObject` classes held with
  `@StateObject` instead.

### Releases

GitHub Actions (`.github/workflows/build.yml`) runs the tests and builds the app on every push. To
publish a release, bump `packaging/version` if needed and push a tag:

```bash
git tag v0.1.0-beta.2 && git push origin v0.1.0-beta.2
```

The workflow builds the DMG and the Homebrew cask and attaches them to a new GitHub release. Tags
with a suffix like `-beta.2` are marked as pre-releases. CI builds are ad-hoc signed and not
notarized.

## How it's built

```
Sources/TranslateCore/      testable, no UI
  HelperClient.swift        JSON lines over stdin/stdout, (re)starts the Python helper
  HelperLocator.swift       finds the bundled Python (or the dev venv)
  LanguageRules.swift       target choice, locale → catalog codes, RTL
  History.swift, TextRecognition.swift (Vision OCR), Models.swift
Sources/OfflineTranslate/   the app (AppKit + SwiftUI)
  AppDelegate.swift         wiring; --popup/--settings/--welcome/--snapshot debug flags
  AppModel.swift            shared state: languages, downloads, history, hotkeys, login item
  Popup.swift               non-activating NSPanel + SwiftUI popup
  SelectionReader.swift     AX selected text → ⌘C fallback; ⌘V paste for "Replace"
  Shortcut.swift            Carbon RegisterEventHotKey, key names
  StatusMenu.swift, Settings.swift, Languages.swift, Onboarding.swift, ScreenText.swift
scripts/                    build-app.sh, make-icon.swift, swift (SwiftPM wrapper)
packaging/                  Info.plist, entitlements, Homebrew cask template, version, release notes
.github/workflows/build.yml CI: tests, build, DMG and GitHub release on tags
```

The app starts `offline-translate-helper` once and keeps it running. The helper's JSON-lines
protocol is the only contract between the Swift app and Python, so a native engine could replace
the helper later without touching the UI.

`OfflineTranslate --snapshot DIR` renders the popup, every Settings tab and the Welcome window to
PNGs, then quits. It's a visual check that needs no screen-recording permission.

## Not done yet

- **Sparkle auto-updates:** they need a hosted appcast and EdDSA signing keys. Until then, check the
  Releases page for updates.
- **Notarization:** it needs a paid Apple Developer ID. The script supports it, but releases
  are ad-hoc signed for now, so macOS shows a warning on first launch (see [Install](#install)).
- **Unsupported languages:** the 15 languages that still use the older WordPiece model format are
  listed as "not supported yet".

## Disclaimer

This app was written with [Claude Code](https://claude.com/claude-code), Anthropic's AI coding
tool.

Not affiliated with Google. Language packs are downloaded from Google's servers at runtime and are
subject to Google's terms.

## License

MIT. See [LICENSE](LICENSE).

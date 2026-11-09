import AppKit
import SwiftUI
import TranslateCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let prefs = Preferences()
    private var app: AppModel!
    private var popup: PopupController!
    private var menu: StatusMenu!
    private let settingsSelection = SettingsSelection()
    private var settings: WindowPresenter<SettingsView>!
    private var onboarding: WindowPresenter<OnboardingView>!
    private var busy = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        app = AppModel(prefs: prefs)
        popup = PopupController(app: app)
        popup.model.onReplace = { [weak self] _ in self?.popup.replaceSelection() }
        popup.model.onOpenLanguages = { [weak self] in self?.open(.languages) }

        settings = WindowPresenter(title: "Offline Translate Settings") { [unowned self] in
            SettingsView(app: app, prefs: prefs, selection: settingsSelection)
        }
        onboarding = WindowPresenter(title: "Welcome") { [unowned self] in
            OnboardingView(app: app, prefs: prefs) { [weak self] in self?.onboarding.close() }
        }

        menu = StatusMenu(app: app)
        menu.translateSelection = { [weak self] in self?.translateSelection() }
        menu.translateClipboard = { [weak self] in self?.translateClipboard() }
        menu.translateScreen = { [weak self] in self?.translateScreen() }
        menu.openSettings = { [weak self] tab in self?.open(tab) }
        menu.showHistoryEntry = { [weak self] e in self?.popup.show(text: e.original, near: nil) }

        app.onTranslateSelection = { [weak self] in self?.translateSelection() }
        app.onTranslateClipboard = { [weak self] in self?.translateClipboard() }
        app.onTranslateScreen = { [weak self] in self?.translateScreen() }
        app.registerHotkeys()

        Task { await app.warmUp() }
        if !prefs.onboardingDone || !SelectionReader.isTrusted { onboarding.show() }
        handleDebugArguments()
    }

    func applicationWillTerminate(_ notification: Notification) {
        app.shutdown()
    }

    /// Opening the app again (e.g. from Finder or Spotlight) shows Settings, since there is no Dock icon.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        open(.general)
        return false
    }

    private func open(_ tab: SettingsTab) {
        if tab == .welcome {
            onboarding.show()
            return
        }
        settingsSelection.tab = tab
        settings.show()
    }

    // MARK: actions

    private func translateSelection() {
        guard !busy else { return }
        if SelectionReader.secureInputActive {
            popup.show(error: "A password field has focus, so macOS keeps its text private.", near: nil)
            return
        }
        guard SelectionReader.isTrusted else {
            popup.show(error: "Allow Accessibility access to read the selected text.", near: nil)
            onboarding.show()
            return
        }
        busy = true
        Task {
            defer { busy = false }
            let sel = await SelectionReader.read(clipboardFallback: prefs.clipboardFallback)
            if let text = sel.text {
                popup.show(text: text, near: sel.rect)
            } else {
                popup.show(error: "No text is selected. Select some text, or copy it and use Translate Clipboard (\(prefs.clipboardShortcut.display)).",
                           near: sel.rect)
            }
        }
    }

    private func translateClipboard() {
        let text = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if text.isEmpty {
            popup.show(error: "The clipboard has no text.", near: nil)
        } else {
            popup.show(text: text, near: nil)
        }
    }

    private func translateScreen() {
        guard !busy else { return }
        busy = true
        popup.close()
        Task {
            defer { busy = false }
            switch await ScreenText.capture() {
            case .success(let text): popup.show(text: text, near: nil)
            case .failure(.cancelled): break
            case .failure(.noText): popup.show(error: "No text found in that area.", near: nil)
            case .failure(.failed(let why)): popup.show(error: why, near: nil)
            }
        }
    }

    // MARK: development

    /// `OfflineTranslate --popup "text"` shows the popup for a text; `--settings <tab>` / `--welcome` open windows.
    private func handleDebugArguments() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--popup"), i + 1 < args.count {
            popup.show(text: args[i + 1], near: nil)
        }
        if let i = args.firstIndex(of: "--settings") {
            open(i + 1 < args.count ? SettingsTab(rawValue: args[i + 1]) ?? .general : .general)
        }
        if args.contains("--welcome") { onboarding.show() }
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            Task { await snapshots(to: URL(fileURLWithPath: args[i + 1], isDirectory: true)) }
        }
    }

    /// Renders every window to PNGs and quits: a visual check that needs no screen-recording permission.
    private func snapshots(to dir: URL) async {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func wait(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }
        func save(_ view: NSView?, _ name: String) {
            guard let view, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name + ".png"))
        }
        onboarding.close()
        await wait(3)
        popup.show(text: "Please bring the signed contract and your ID.", near: nil)
        await wait(3)
        save(popup.view, "popup-en-iw")
        popup.show(text: "שלום, מה שלומך? נתראה מחר בבוקר.", near: nil)
        await wait(3)
        save(popup.view, "popup-iw-en")
        popup.model.setTarget("fr")
        popup.model.phase = .notInstalled(["fr"])
        await wait(1)
        save(popup.view, "popup-missing")
        popup.show(error: "No text is selected. Select some text, or copy it and use Translate Clipboard (⌥⇧V).", near: nil)
        await wait(1)
        save(popup.view, "popup-error")
        popup.close()
        for tab in [SettingsTab.general, .shortcuts, .languages, .history, .about] {
            open(tab)
            await wait(2)
            save(settings.window?.contentView?.superview, "settings-\(tab.rawValue)")
        }
        settings.close()
        onboarding.show()
        await wait(2)
        save(onboarding.window?.contentView?.superview, "welcome")
        try? menu.dump().write(to: dir.appendingPathComponent("menu.txt"), atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }
}

import AppKit
import Combine
import TranslateCore

/// The menu-bar item. The menu is rebuilt each time it opens, so it always shows current state.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let app: AppModel
    private var sink: AnyCancellable?

    var translateSelection: () -> Void = {}
    var translateClipboard: () -> Void = {}
    var translateScreen: () -> Void = {}
    var openSettings: (SettingsTab) -> Void = { _ in }
    var showHistoryEntry: (HistoryEntry) -> Void = { _ in }

    init(app: AppModel) {
        self.app = app
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        updateButton()
        sink = app.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.updateButton() } }
    }

    private func updateButton() {
        guard let button = item.button else { return }
        let busy = !app.downloads.isEmpty
        let symbol = app.helperProblem != nil ? "exclamationmark.bubble" : busy ? "arrow.down.circle" : "character.bubble"
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Offline Translate")
        button.image?.isTemplate = true
        if busy {
            let p = app.downloads.values
            let total = p.reduce(0) { $0 + $1.total }, done = p.reduce(0) { $0 + $1.done }
            button.title = total > 0 ? " \(Int(Double(done) / Double(total) * 100))%" : ""
            button.imagePosition = .imageLeading
        } else {
            button.title = ""
            button.imagePosition = .imageOnly
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let prefs = app.prefs
        add(menu, "Translate Selection", prefs.translateShortcut) { [weak self] in self?.translateSelection() }
        add(menu, "Translate Clipboard", prefs.clipboardShortcut) { [weak self] in self?.translateClipboard() }
        add(menu, "Translate Text on Screen…", prefs.screenShortcut) { [weak self] in self?.translateScreen() }
        menu.addItem(.separator())

        let mine = NSMenuItem(title: "Translate Into: \(app.name(prefs.mainLanguage))", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for code in app.installed {
            let i = ActionItem(app.name(code)) { [weak self] in self?.app.prefs.mainLanguage = code }
            i.state = code == prefs.mainLanguage ? .on : .off
            sub.addItem(i)
        }
        sub.addItem(.separator())
        sub.addItem(ActionItem("Text already in this language goes to your last other language.") {})
        sub.items.last?.isEnabled = false
        mine.submenu = sub
        menu.addItem(mine)

        if prefs.keepHistory && !app.historyEntries.isEmpty {
            let recent = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")
            let rsub = NSMenu()
            for e in app.historyEntries.prefix(10) {
                let title = e.original.replacingOccurrences(of: "\n", with: " ")
                let i = ActionItem(String(title.prefix(48)) + (title.count > 48 ? "…" : "")) { [weak self] in
                    self?.showHistoryEntry(e)
                }
                i.toolTip = e.translation
                rsub.addItem(i)
            }
            rsub.addItem(.separator())
            rsub.addItem(ActionItem("Show All…") { [weak self] in self?.openSettings(.history) })
            recent.submenu = rsub
            menu.addItem(recent)
        }
        menu.addItem(.separator())

        menu.addItem(ActionItem("Languages…") { [weak self] in self?.openSettings(.languages) })
        let settings = ActionItem("Settings…") { [weak self] in self?.openSettings(.general) }
        settings.keyEquivalent = ","
        menu.addItem(settings)

        let status = NSMenuItem(title: statusLine, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        if app.helperProblem != nil {
            menu.addItem(ActionItem("Restart Translation Engine") { [weak self] in self?.app.restartHelper() })
        }
        if !app.accessibilityTrusted {
            menu.addItem(ActionItem("Allow Accessibility Access…") { [weak self] in self?.openSettings(.welcome) })
        }
        menu.addItem(.separator())
        let quit = ActionItem("Quit Offline Translate") { NSApp.terminate(nil) }
        quit.keyEquivalent = "q"
        menu.addItem(quit)
    }

    /// Menu titles as text, for `--snapshot`.
    func dump() -> String {
        let menu = NSMenu()
        menuNeedsUpdate(menu)
        func lines(_ m: NSMenu, _ indent: String) -> [String] {
            m.items.flatMap { i -> [String] in
                if i.isSeparatorItem { return [indent + "———"] }
                var t = indent + i.title
                if !i.keyEquivalent.isEmpty {
                    t += "    " + Shortcut.symbols(i.keyEquivalentModifierMask) + i.keyEquivalent.uppercased()
                }
                if i.state == .on { t = "✓ " + t }
                return [t] + (i.submenu.map { lines($0, indent + "    ") } ?? [])
            }
        }
        return lines(menu, "").joined(separator: "\n")
    }

    private var statusLine: String {
        if let problem = app.helperProblem { return String(problem.prefix(60)) }
        if let (code, p) = app.downloads.first {
            return "Downloading \(app.name(code))… \(Int(p.fraction * 100))%"
        }
        let n = app.installed.count
        var s = "\(n) language\(n == 1 ? "" : "s") installed"
        if let v = app.catalogVersion { s += " · catalog \(v)" }
        return s
    }

    private func add(_ menu: NSMenu, _ title: String, _ shortcut: Shortcut, _ action: @escaping () -> Void) {
        let i = ActionItem(title, action)
        i.keyEquivalent = shortcut.menuKeyEquivalent
        i.keyEquivalentModifierMask = shortcut.modifierFlags
        menu.addItem(i)
    }
}

/// NSMenuItem with a closure.
final class ActionItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }
}

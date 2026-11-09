import AppKit
import Combine
import ServiceManagement
import TranslateCore

struct DownloadProgress: Equatable {
    var done: Int64
    var total: Int64
    var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }
}

/// App-wide state shared by the popup, the menu and Settings: the helper process, languages and downloads.
@MainActor
final class AppModel: ObservableObject {
    let prefs: Preferences
    let history: History
    private(set) var helper: HelperClient?

    @Published private(set) var languages: [LanguageInfo] = []
    @Published private(set) var installed: [String] = ["en"]
    @Published private(set) var catalogVersion: String?
    @Published private(set) var downloads: [String: DownloadProgress] = [:]
    @Published private(set) var checkingForUpdates = false
    @Published var lastError: String?
    @Published private(set) var helperProblem: String?
    @Published private(set) var historyEntries: [HistoryEntry] = []
    @Published private(set) var hotkeyErrors: [String: String] = [:]
    @Published private(set) var accessibilityTrusted = SelectionReader.isTrusted

    /// Names for codes, from the catalog; falls back to the system's names.
    private var names: [String: String] = ["en": "English"]
    private var cancellables: Set<AnyCancellable> = []
    private var hotkeyIDs: [String: UInt32] = [:]

    var onTranslateSelection: (() -> Void)?
    var onTranslateClipboard: (() -> Void)?
    var onTranslateScreen: (() -> Void)?

    init(prefs: Preferences) {
        self.prefs = prefs
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        history = History(file: support.appendingPathComponent("OfflineTranslate/history.json"))
        historyEntries = history.entries
        startHelper()
        prefs.$idleUnloadMinutes.dropFirst().removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.restartHelper() }
        }.store(in: &cancellables)
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let trusted = SelectionReader.isTrusted
                if trusted != self.accessibilityTrusted { self.accessibilityTrusted = trusted }
            }
        }
    }

    // MARK: helper

    private func startHelper() {
        guard let python = HelperLocator.python() else {
            helper = nil
            helperProblem = "The translation engine is missing from the app. Rebuild it with scripts/build-app.sh."
            return
        }
        try? FileManager.default.createDirectory(at: prefs.modelsDir, withIntermediateDirectories: true)
        let client = HelperClient(launch: HelperLocator.launch(python: python, modelsDir: prefs.modelsDir,
                                                               idleUnloadSeconds: prefs.idleUnloadMinutes * 60))
        client.onStateChange = { [weak self] state in
            Task { @MainActor in
                if case .crashed(let why) = state { self?.helperProblem = "Translation engine stopped: \(why)" }
                if state == .running { self?.helperProblem = nil }
            }
        }
        helper = client
        helperProblem = nil
    }

    func restartHelper() {
        helper?.stop()
        startHelper()
        Task { await warmUp() }
    }

    func shutdown() {
        helper?.stop()
    }

    private func requireHelper() throws -> HelperClient {
        guard let helper else { throw HelperError.unavailable(helperProblem ?? "The translation engine is missing.") }
        return helper
    }

    /// Start the helper and load the most recently used direction, so the first shortcut press is instant.
    func warmUp() async {
        await refreshLanguages()
        let pair = prefs.lastPair ?? [prefs.mainLanguage, prefs.target(for: prefs.mainLanguage, installed: installed)]
        if pair.count == 2, pair[0] != pair[1], installed.contains(pair[0]), installed.contains(pair[1]) {
            try? await helper?.preload(source: pair[0], target: pair[1])
        }
        await checkCatalogIfDue()
    }

    // MARK: languages

    func name(_ code: String) -> String {
        if let n = names[code] { return n }
        let systemCode = code == "iw" ? "he" : code == "jw" ? "jv" : code
        return Locale(identifier: "en").localizedString(forIdentifier: systemCode) ?? code
    }

    func language(_ code: String) -> LanguageInfo? { languages.first { $0.code == code } }

    func refreshLanguages() async {
        guard let helper else { return }
        do {
            let list = try await helper.languages()
            languages = list.languages
            catalogVersion = list.catalogVersion
            for l in list.languages { names[l.code] = l.name }
            installed = list.languages.filter(\.installed).map(\.code)
        } catch {
            // No cached catalog and no network: still show what's installed.
            if let codes = try? await helper.installed() { installed = codes }
            if languages.isEmpty { lastError = error.localizedDescription }
        }
    }

    private func checkCatalogIfDue() async {
        if let last = prefs.lastCatalogCheck, Date().timeIntervalSince(last) < 24 * 3600 { return }
        do {
            try await helper?.updateCatalog()
            prefs.lastCatalogCheck = Date()
            await refreshLanguages()
        } catch {}  // offline: try again next launch
    }

    func checkForUpdates() async {
        guard let helper else { return }
        checkingForUpdates = true
        defer { checkingForUpdates = false }
        do {
            try await helper.updateCatalog()
            prefs.lastCatalogCheck = Date()
            lastError = nil
        } catch {
            lastError = "Couldn't check for updates: \(error.localizedDescription)"
        }
        await refreshLanguages()
    }

    func download(_ code: String) {
        guard downloads[code] == nil, let helper else { return }
        downloads[code] = DownloadProgress(done: 0, total: language(code)?.downloadSize ?? 0)
        Task {
            do {
                try await helper.download(code) { done, total in
                    Task { @MainActor in
                        if self.downloads[code] != nil { self.downloads[code] = DownloadProgress(done: done, total: total) }
                    }
                }
            } catch let e as HelperError where e.code == "cancelled" {
            } catch {
                lastError = "Couldn't download \(name(code)): \(error.localizedDescription)"
            }
            downloads[code] = nil
            await refreshLanguages()
        }
    }

    func cancelDownload(_ code: String) {
        Task { try? await helper?.cancel(code) }
    }

    func remove(_ code: String) async {
        do {
            try await requireHelper().remove(code)
        } catch {
            lastError = "Couldn't remove \(name(code)): \(error.localizedDescription)"
        }
        await refreshLanguages()
        if !installed.contains(prefs.mainLanguage) && prefs.mainLanguage != "en" { prefs.mainLanguage = "en" }
    }

    // MARK: translation

    func detect(_ text: String) async throws -> String {
        try await requireHelper().detect(text)
    }

    func translate(_ text: String, source: String, target: String, record: Bool = true) async throws -> TranslationResult {
        let r = try await requireHelper().translate(text, target: target, source: source)
        prefs.lastPair = [r.source, r.target]
        if record && prefs.keepHistory {
            history.add(HistoryEntry(original: text, translation: r.text, source: r.source, target: r.target))
            historyEntries = history.entries
        }
        return r
    }

    func clearHistory() {
        history.clear()
        historyEntries = []
    }

    // MARK: hotkeys

    func registerHotkeys() {
        let entries: [(String, Shortcut, () -> Void)] = [
            ("translate", prefs.translateShortcut, { [weak self] in self?.onTranslateSelection?() }),
            ("clipboard", prefs.clipboardShortcut, { [weak self] in self?.onTranslateClipboard?() }),
            ("screen", prefs.screenShortcut, { [weak self] in self?.onTranslateScreen?() }),
        ]
        var errors: [String: String] = [:]
        for (key, shortcut, action) in entries {
            let (id, error) = HotKeyCenter.shared.register(shortcut, id: hotkeyIDs[key], handler: action)
            hotkeyIDs[key] = id
            if let error { errors[key] = error }
        }
        hotkeyErrors = errors
    }

    // MARK: launch at login

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                lastError = nil
            } catch {
                lastError = "Couldn't change Launch at Login: \(error.localizedDescription)"
            }
            objectWillChange.send()
        }
    }
}

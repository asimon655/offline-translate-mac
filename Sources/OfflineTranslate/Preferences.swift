import Foundation
import TranslateCore

/// User settings, stored in UserDefaults.
final class Preferences: ObservableObject {
    private let d: UserDefaults

    init(defaults: UserDefaults = .standard) {
        d = defaults
        mainLanguage = d.string(forKey: "mainLanguage") ?? LanguageRules.systemLanguage()
        lastOther = d.string(forKey: "lastOther")
        targetBySource = d.dictionary(forKey: "targetBySource") as? [String: String] ?? [:]
        clipboardFallback = d.object(forKey: "clipboardFallback") as? Bool ?? true
        idleUnloadMinutes = d.object(forKey: "idleUnloadMinutes") as? Int ?? 10
        keepHistory = d.object(forKey: "keepHistory") as? Bool ?? true
        onboardingDone = d.bool(forKey: "onboardingDone")
        lastCatalogCheck = d.object(forKey: "lastCatalogCheck") as? Date
        lastPair = d.stringArray(forKey: "lastPair")
        translateShortcut = Self.shortcut(d, "translateShortcut") ?? .translateDefault
        clipboardShortcut = Self.shortcut(d, "clipboardShortcut") ?? .clipboardDefault
        screenShortcut = Self.shortcut(d, "screenShortcut") ?? .screenDefault
    }

    /// Text in another language is translated into this one.
    @Published var mainLanguage: String { didSet { d.set(mainLanguage, forKey: "mainLanguage") } }
    /// Last target chosen for text that was already in the main language.
    @Published var lastOther: String? { didSet { d.set(lastOther, forKey: "lastOther") } }
    /// Target picked by hand for a given source language.
    @Published var targetBySource: [String: String] { didSet { d.set(targetBySource, forKey: "targetBySource") } }
    @Published var clipboardFallback: Bool { didSet { d.set(clipboardFallback, forKey: "clipboardFallback") } }
    /// Free models unused this long; 0 = keep them loaded.
    @Published var idleUnloadMinutes: Int { didSet { d.set(idleUnloadMinutes, forKey: "idleUnloadMinutes") } }
    @Published var keepHistory: Bool { didSet { d.set(keepHistory, forKey: "keepHistory") } }
    @Published var onboardingDone: Bool { didSet { d.set(onboardingDone, forKey: "onboardingDone") } }
    @Published var lastCatalogCheck: Date? { didSet { d.set(lastCatalogCheck, forKey: "lastCatalogCheck") } }
    /// [source, target] of the last translation; preloaded at launch.
    @Published var lastPair: [String]? { didSet { d.set(lastPair, forKey: "lastPair") } }
    @Published var translateShortcut: Shortcut { didSet { Self.save(d, "translateShortcut", translateShortcut) } }
    @Published var clipboardShortcut: Shortcut { didSet { Self.save(d, "clipboardShortcut", clipboardShortcut) } }
    @Published var screenShortcut: Shortcut { didSet { Self.save(d, "screenShortcut", screenShortcut) } }

    /// Overridable for development: `defaults write <bundle id> modelsDir /path`.
    var modelsDir: URL {
        if let p = d.string(forKey: "modelsDir"), !p.isEmpty {
            return URL(fileURLWithPath: (p as NSString).expandingTildeInPath, isDirectory: true)
        }
        return HelperLocator.defaultModelsDir
    }

    func target(for source: String, installed: [String]) -> String {
        LanguageRules.chooseTarget(source: source, main: mainLanguage, perSource: targetBySource,
                                   lastOther: lastOther, installed: installed)
    }

    /// Remember a target the user picked by hand.
    func remember(source: String, target: String) {
        targetBySource[source] = target
        if source == mainLanguage { lastOther = target }
    }

    private static func shortcut(_ d: UserDefaults, _ key: String) -> Shortcut? {
        d.data(forKey: key).flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) }
    }

    private static func save(_ d: UserDefaults, _ key: String, _ s: Shortcut) {
        d.set(try? JSONEncoder().encode(s), forKey: key)
    }
}

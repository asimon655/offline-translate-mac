import Foundation

/// Language-code helpers and the rule for picking a translation target.
public enum LanguageRules {
    /// Scripts written right to left (catalog codes).
    public static let rightToLeft: Set<String> = ["ar", "fa", "iw", "ps", "sd", "ug", "ur", "yi"]

    public static func isRightToLeft(_ code: String) -> Bool { rightToLeft.contains(code) }

    /// Map a BCP-47 tag such as "he-IL", "zh-Hant-TW" or "en-US" to the catalog's code ("iw", "zh-Hant", "en").
    public static func catalogCode(forLocale tag: String) -> String {
        let parts = tag.replacingOccurrences(of: "_", with: "-").split(separator: "-").map(String.init)
        guard let lang = parts.first?.lowercased() else { return "en" }
        let rest = parts.dropFirst().map { $0.lowercased() }
        switch lang {
        case "he": return "iw"
        case "jv": return "jw"
        case "fil": return "tl"
        case "nb", "nn": return "no"
        case "zh":
            if rest.contains("hant") || rest.contains("tw") || rest.contains("hk") || rest.contains("mo") { return "zh-Hant" }
            return "zh"
        default: return lang
        }
    }

    /// The user's main language from the Mac's preferred languages, e.g. "iw" for a Hebrew system.
    public static func systemLanguage(_ preferred: [String] = Locale.preferredLanguages) -> String {
        preferred.first.map(catalogCode(forLocale:)) ?? "en"
    }

    /// Pick the target for text detected as `source`.
    ///
    /// Text in a foreign language goes into your main language. Text already in your main language goes to the
    /// language you last chose for it, or the last other language you used, or any other installed language.
    public static func chooseTarget(source: String, main: String, perSource: [String: String],
                                    lastOther: String?, installed: [String]) -> String {
        if let remembered = perSource[source], remembered != source { return remembered }
        if source != main { return main }
        if let lastOther, lastOther != main { return lastOther }
        if let other = installed.first(where: { $0 != main && $0 != "en" }) { return other }
        return main == "en" ? (installed.first { $0 != "en" } ?? "en") : "en"
    }

    /// "55 MB" style sizes.
    public static func formatBytes(_ n: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = n >= 1_000_000 ? [.useMB, .useGB] : [.useKB, .useMB]
        return f.string(fromByteCount: n)
    }
}

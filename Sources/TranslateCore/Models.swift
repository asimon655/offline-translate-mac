import Foundation

/// Result of a `translate` call. `via` lists the language hops, e.g. ["iw", "en", "fr"].
public struct TranslationResult: Decodable, Equatable, Sendable {
    public var text: String
    public var source: String
    public var target: String
    public var via: [String]
    public var ms: Int

    public init(text: String, source: String, target: String, via: [String], ms: Int) {
        self.text = text
        self.source = source
        self.target = target
        self.via = via
        self.ms = ms
    }

    /// True when the translation pivoted through English.
    public var pivoted: Bool { via.count > 2 }
}

/// One row of the language catalog (`languages` method).
public struct LanguageInfo: Decodable, Identifiable, Equatable, Sendable {
    public var code: String
    public var name: String
    public var installed: Bool
    public var downloadSize: Int64
    public var size: Int64
    public var updateAvailable: Bool
    public var builtin: Bool
    public var supported: Bool
    public var downloading: Bool

    public var id: String { code }

    public init(code: String, name: String, installed: Bool = false, downloadSize: Int64 = 0, size: Int64 = 0,
                updateAvailable: Bool = false, builtin: Bool = false, supported: Bool = true,
                downloading: Bool = false) {
        self.code = code
        self.name = name
        self.installed = installed
        self.downloadSize = downloadSize
        self.size = size
        self.updateAvailable = updateAvailable
        self.builtin = builtin
        self.supported = supported
        self.downloading = downloading
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        code = try c.decode(String.self, forKey: .code)
        name = try c.decode(String.self, forKey: .name)
        installed = try c.decode(Bool.self, forKey: .installed)
        downloadSize = try c.decode(Int64.self, forKey: .downloadSize)
        size = try c.decode(Int64.self, forKey: .size)
        updateAvailable = try c.decodeIfPresent(Bool.self, forKey: .updateAvailable) ?? false
        builtin = try c.decodeIfPresent(Bool.self, forKey: .builtin) ?? false
        supported = try c.decodeIfPresent(Bool.self, forKey: .supported) ?? true
        downloading = try c.decodeIfPresent(Bool.self, forKey: .downloading) ?? false
    }

    enum CodingKeys: String, CodingKey {
        case code, name, installed, downloadSize, size, updateAvailable, builtin, supported, downloading
    }
}

public struct LanguageList: Decodable, Sendable {
    public var languages: [LanguageInfo]
    public var catalogVersion: String?
}

public enum HelperError: LocalizedError, Equatable {
    /// The helper answered with an error object.
    case remote(code: String, message: String, missing: [String])
    /// The helper process exited; carries the tail of its stderr.
    case crashed(String)
    /// No Python/helper could be found or started.
    case unavailable(String)
    case badResponse(String)

    public var errorDescription: String? {
        switch self {
        case .remote(_, let message, _): return message
        case .crashed(let tail): return tail.isEmpty ? "The translation helper stopped." : "The translation helper stopped: \(tail)"
        case .unavailable(let why): return why
        case .badResponse(let why): return "Unexpected reply from the translation helper: \(why)"
        }
    }

    public var code: String? {
        if case .remote(let code, _, _) = self { return code }
        return nil
    }

    /// Languages a failed translation needs ("not_installed" errors).
    public var missing: [String] {
        if case .remote(_, _, let missing) = self { return missing }
        return []
    }
}

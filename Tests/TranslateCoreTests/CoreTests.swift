import Foundation
import Testing
@testable import TranslateCore

@Suite struct LanguageRulesTests {
    @Test(arguments: [("he-IL", "iw"), ("en-US", "en"), ("zh-Hant-TW", "zh-Hant"), ("zh-Hans-CN", "zh"),
                      ("zh-TW", "zh-Hant"), ("fr", "fr"), ("nb-NO", "no"), ("pt_BR", "pt"), ("fil-PH", "tl")])
    func catalogCodes(tag: String, code: String) {
        #expect(LanguageRules.catalogCode(forLocale: tag) == code)
    }

    @Test func systemLanguage() {
        #expect(LanguageRules.systemLanguage(["he-IL", "en-US"]) == "iw")
        #expect(LanguageRules.systemLanguage([]) == "en")
    }

    @Test func foreignTextGoesIntoMainLanguage() {
        #expect(LanguageRules.chooseTarget(source: "iw", main: "en", perSource: [:], lastOther: nil,
                                           installed: ["en", "iw"]) == "en")
    }

    @Test func mainLanguageTextGoesToLastOther() {
        #expect(LanguageRules.chooseTarget(source: "en", main: "en", perSource: [:], lastOther: "fr",
                                           installed: ["en", "fr", "iw"]) == "fr")
        #expect(LanguageRules.chooseTarget(source: "en", main: "en", perSource: [:], lastOther: nil,
                                           installed: ["en", "iw"]) == "iw")
        #expect(LanguageRules.chooseTarget(source: "iw", main: "iw", perSource: [:], lastOther: nil,
                                           installed: ["en", "iw"]) == "en")
    }

    @Test func rememberedChoiceWins() {
        #expect(LanguageRules.chooseTarget(source: "iw", main: "en", perSource: ["iw": "fr"], lastOther: nil,
                                           installed: ["en", "fr", "iw"]) == "fr")
        // a remembered choice equal to the source is ignored
        #expect(LanguageRules.chooseTarget(source: "iw", main: "en", perSource: ["iw": "iw"], lastOther: nil,
                                           installed: ["en", "iw"]) == "en")
    }

    @Test func rightToLeft() {
        #expect(LanguageRules.isRightToLeft("iw") && LanguageRules.isRightToLeft("ar"))
        #expect(!LanguageRules.isRightToLeft("en"))
    }

    @Test func bytes() {
        #expect(LanguageRules.formatBytes(55_000_000) == "55 MB")
    }
}

@Suite struct HistoryTests {
    func file() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ot-history-\(UUID().uuidString).json")
    }

    @Test func newestFirstDedupedLimitedAndPersisted() {
        let f = file()
        let h = History(file: f, limit: 3)
        for i in 0..<5 { h.add(HistoryEntry(original: "t\(i)", translation: "x", source: "en", target: "iw")) }
        h.add(HistoryEntry(original: "t3", translation: "y", source: "en", target: "iw"))
        #expect(h.entries.map(\.original) == ["t3", "t4", "t2"])
        #expect(History(file: f).entries.map(\.original) == ["t3", "t4", "t2"])
        h.clear()
        #expect(History(file: f).entries.isEmpty)
    }
}

@Suite struct HelperLocatorTests {
    let tmp: URL = {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("ot-loc-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: d.appendingPathComponent("helper/bin"), withIntermediateDirectories: true)
        return d
    }()

    func makeExecutable(_ url: URL) {
        FileManager.default.createFile(atPath: url.path, contents: Data("#!/bin/sh\n".utf8),
                                       attributes: [.posixPermissions: 0o755])
    }

    @Test func order() {
        let bundled = tmp.appendingPathComponent("helper/bin/python3")
        let dev = tmp.appendingPathComponent("dev-python")
        makeExecutable(dev)
        #expect(HelperLocator.python(environment: [:], resources: tmp, info: ["OTDevPython": dev.path]) == dev)
        makeExecutable(bundled)
        #expect(HelperLocator.python(environment: [:], resources: tmp, info: ["OTDevPython": dev.path]) == bundled)
        #expect(HelperLocator.python(environment: ["OFFLINE_TRANSLATE_PYTHON": dev.path], resources: tmp, info: nil) == dev)
        #expect(HelperLocator.python(environment: [:], resources: nil, info: nil) == nil)
    }

    @Test func launchArguments() {
        let l = HelperLocator.launch(python: URL(fileURLWithPath: "/py"), modelsDir: URL(fileURLWithPath: "/m"),
                                     idleUnloadSeconds: 60, cacheDir: URL(fileURLWithPath: "/c"))
        #expect(l.arguments == ["-s", "-X", "pycache_prefix=/c/pycache", "-m", "offline_translate.helper",
                                "--models", "/m", "--idle-unload", "60"])
    }
}

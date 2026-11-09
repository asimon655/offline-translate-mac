import Foundation
import Testing
@testable import TranslateCore

/// A stand-in for offline-translate-helper, written to a temp file and run with the system python3.
let fakeHelper = #"""
import json, sys, os
print(json.dumps({"event": "ready", "version": "fake", "pid": os.getpid()}), flush=True)
for line in sys.stdin:
    req = json.loads(line)
    rid, m, p = req.get("id"), req.get("method"), req.get("params") or {}
    def send(o): print(json.dumps(o, ensure_ascii=False), flush=True)
    if m == "translate":
        if p["target"] == "de":
            send({"id": rid, "error": {"code": "not_installed", "message": "download: de", "missing": ["de"]}})
        else:
            send({"id": rid, "result": {"text": "[" + p["target"] + "]" + p["text"], "source": p.get("source") or "en",
                                        "target": p["target"], "via": ["en", p["target"]], "ms": 3}})
    elif m == "download":
        for done in (10, 20, 30):
            send({"event": "progress", "id": rid, "lang": p["lang"], "done": done, "total": 30})
        send({"id": rid, "result": {"installed": True, "lang": p["lang"]}})
    elif m == "languages":
        send({"id": rid, "result": {"catalog_version": "8.5.0", "languages": [
            {"code": "en", "name": "English", "installed": True, "download_size": 0, "size": 0,
             "update_available": False, "builtin": True, "supported": True, "downloading": False},
            {"code": "iw", "name": "Hebrew", "installed": False, "download_size": 55000000, "size": 77000000,
             "update_available": False, "builtin": False, "supported": True, "downloading": False}]}})
    elif m == "crash":
        sys.stderr.write("boom\n"); sys.stderr.flush(); os._exit(3)
    elif m == "pid":
        send({"id": rid, "result": os.getpid()})
    elif m == "shutdown":
        send({"id": rid, "result": {"bye": True}}); break
    else:
        send({"id": rid, "error": {"code": "unknown_method", "message": "unknown method " + repr(m)}})
"""#

func makeClient() throws -> HelperClient {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ot-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let script = dir.appendingPathComponent("fake_helper.py")
    try fakeHelper.write(to: script, atomically: true, encoding: .utf8)
    return HelperClient(launch: HelperLaunch(executable: URL(fileURLWithPath: "/usr/bin/python3"),
                                             arguments: ["-u", script.path]))
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int64] = []
    func add(_ v: Int64) { lock.lock(); values.append(v); lock.unlock() }
    var all: [Int64] { lock.lock(); defer { lock.unlock() }; return values }
}

@Suite struct HelperClientTests {
    @Test func translateRoundTrip() async throws {
        let c = try makeClient()
        defer { c.stop() }
        let r = try await c.translate("שלום עולם", target: "iw", source: "en")
        #expect(r == TranslationResult(text: "[iw]שלום עולם", source: "en", target: "iw", via: ["en", "iw"], ms: 3))
        #expect(!r.pivoted)
    }

    @Test func remoteErrorsCarryCodeAndMissing() async throws {
        let c = try makeClient()
        defer { c.stop() }
        do {
            _ = try await c.translate("x", target: "de")
            Issue.record("expected an error")
        } catch let e as HelperError {
            #expect(e.code == "not_installed")
            #expect(e.missing == ["de"])
        }
        await #expect(throws: HelperError.self) { try await c.callRaw("nope") }
    }

    @Test func concurrentCallsMatchByID() async throws {
        let c = try makeClient()
        defer { c.stop() }
        let results = try await withThrowingTaskGroup(of: String.self) { group in
            for i in 0..<20 { group.addTask { try await c.translate("t\(i)", target: "fr").text } }
            return try await group.reduce(into: Set<String>()) { $0.insert($1) }
        }
        #expect(results == Set((0..<20).map { "[fr]t\($0)" }))
    }

    @Test func downloadReportsProgress() async throws {
        let c = try makeClient()
        defer { c.stop() }
        let seen = Counter()
        try await c.download("iw") { done, total in
            #expect(total == 30)
            seen.add(done)
        }
        #expect(seen.all == [10, 20, 30])
    }

    @Test func decodesLanguages() async throws {
        let c = try makeClient()
        defer { c.stop() }
        let list = try await c.languages()
        #expect(list.catalogVersion == "8.5.0")
        #expect(list.languages.map(\.code) == ["en", "iw"])
        #expect(list.languages[0].builtin && list.languages[1].downloadSize == 55_000_000)
    }

    @Test func crashFailsInFlightCallThenRestarts() async throws {
        let c = try makeClient()
        defer { c.stop() }
        let first = try await c.call("pid", as: Int.self)
        do {
            _ = try await c.callRaw("crash")
            Issue.record("expected crash")
        } catch let HelperError.crashed(tail) {
            #expect(tail.contains("boom"))
        }
        let second = try await c.call("pid", as: Int.self)
        #expect(first != second)
    }

    @Test func givesUpAfterRepeatedQuickCrashes() async throws {
        let c = try makeClient()
        defer { c.stop() }
        c.maxQuickCrashes = 2
        for _ in 0..<2 { _ = try? await c.callRaw("crash") }
        await #expect(throws: HelperError.self) { try await c.ping() }
        try c.start()  // a manual start resets the counter
        _ = try await c.call("pid", as: Int.self)
    }

    @Test func missingExecutable() async throws {
        let c = HelperClient(launch: HelperLaunch(executable: URL(fileURLWithPath: "/nonexistent/python3"), arguments: []))
        do {
            try await c.ping()
            Issue.record("expected an error")
        } catch let HelperError.unavailable(why) {
            #expect(why.contains("not found"))
        }
    }

    @Test func stopFailsPendingAndStops() async throws {
        let c = try makeClient()
        _ = try await c.call("pid", as: Int.self)
        #expect(c.isRunning)
        c.stop()
        #expect(!c.isRunning)
    }
}

/// End-to-end with the real Python helper. Runs only when both variables are set:
///   OT_TEST_PYTHON=/path/to/venv/bin/python OT_TEST_MODELS=/path/to/models scripts/swift test
@Suite struct RealHelperTests {
    static var env: (URL, URL)? {
        let e = ProcessInfo.processInfo.environment
        guard let py = e["OT_TEST_PYTHON"], let models = e["OT_TEST_MODELS"] else { return nil }
        return (URL(fileURLWithPath: py), URL(fileURLWithPath: models))
    }

    @Test(.enabled(if: env != nil)) func translatesHebrew() async throws {
        let (py, models) = Self.env!
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("ot-pycache")
        let c = HelperClient(launch: HelperLocator.launch(python: py, modelsDir: models, cacheDir: cache))
        defer { c.stop() }
        let r = try await c.translate("car", target: "iw")
        #expect(r.text == "מכונית")
        #expect(try await c.installed().contains("iw"))
        #expect(try await c.detect("שלום") == "iw")
    }
}

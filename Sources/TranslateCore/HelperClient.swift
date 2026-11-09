import Foundation

/// How to start the helper process.
public struct HelperLaunch: Equatable, Sendable {
    public var executable: URL
    public var arguments: [String]
    public var environment: [String: String]?

    public init(executable: URL, arguments: [String], environment: [String: String]? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
    }
}

/// Talks to `offline-translate-helper` over JSON lines on stdin/stdout.
///
/// The process starts on the first call and is restarted on the next call if it dies; calls that were in flight
/// fail with `HelperError.crashed`. All methods are safe to call from any thread.
public final class HelperClient: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case stopped, running, crashed(String)
    }

    private struct Pending {
        var continuation: CheckedContinuation<Data, Error>
        var progress: (@Sendable (Int64, Int64) -> Void)?
    }

    public let launch: HelperLaunch
    /// Called (on a background queue) for every event line, e.g. ["event": "unloaded", ...].
    public var onEvent: (@Sendable ([String: Any]) -> Void)?
    /// Called (on a background queue) when the process starts or stops.
    public var onStateChange: (@Sendable (State) -> Void)?

    private let lock = NSLock()
    private var process: Process?
    private var stdin: FileHandle?
    private var nextID = 1
    private var pending: [Int: Pending] = [:]
    private var stdoutBuffer = Data()
    private var stderrTail = ""
    private var quickCrashes = 0
    private var startedAt = Date.distantPast
    private(set) public var state: State = .stopped

    /// Give up auto-restarting after this many crashes within `quickCrashWindow` of starting.
    public var maxQuickCrashes = 3
    public var quickCrashWindow: TimeInterval = 5

    public init(launch: HelperLaunch) {
        self.launch = launch
    }

    deinit {
        stop()
    }

    // MARK: process

    /// Start the helper if it isn't running. Normally not needed: every call starts it.
    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        try startLocked(force: true)
    }

    private func startLocked(force: Bool) throws {
        if process != nil { return }
        if !force && quickCrashes >= maxQuickCrashes {
            throw HelperError.unavailable("The translation helper keeps crashing. \(stderrTail)")
        }
        if force { quickCrashes = 0 }
        guard FileManager.default.isExecutableFile(atPath: launch.executable.path) else {
            throw HelperError.unavailable("Translation helper not found at \(launch.executable.path)")
        }
        let p = Process()
        p.executableURL = launch.executable
        p.arguments = launch.arguments
        if let env = launch.environment { p.environment = env }
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            self?.received(h.availableData, from: p)
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            self?.receivedStderr(h.availableData)
        }
        p.terminationHandler = { [weak self] proc in
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            self?.terminated(proc)
        }
        stderrTail = ""
        stdoutBuffer = Data()
        do {
            try p.run()
        } catch {
            throw HelperError.unavailable("Couldn't start the translation helper: \(error.localizedDescription)")
        }
        process = p
        stdin = inPipe.fileHandleForWriting
        startedAt = Date()
        state = .running
        let cb = onStateChange
        DispatchQueue.global().async { cb?(.running) }
    }

    /// Ask the helper to exit and stop it. Pending calls fail.
    public func stop() {
        lock.lock()
        let p = process, input = stdin
        process = nil
        stdin = nil
        let failed = pending
        pending = [:]
        state = .stopped
        lock.unlock()
        if let input {
            try? input.write(contentsOf: Data("{\"id\":0,\"method\":\"shutdown\"}\n".utf8))
            try? input.close()
        }
        if let p, p.isRunning {
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if p.isRunning { p.terminate() } }
        }
        for (_, w) in failed { w.continuation.resume(throwing: HelperError.crashed("stopped")) }
    }

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return process != nil
    }

    private func terminated(_ proc: Process) {
        lock.lock()
        guard process === proc else { lock.unlock(); return }  // an old process we already replaced
        process = nil
        stdin = nil
        let failed = pending
        pending = [:]
        let tail = stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
        if Date().timeIntervalSince(startedAt) < quickCrashWindow { quickCrashes += 1 } else { quickCrashes = 1 }
        let reason = proc.terminationReason == .uncaughtSignal ? "signal \(proc.terminationStatus)" : "exit \(proc.terminationStatus)"
        let message = tail.isEmpty ? reason : String(tail.suffix(500))
        state = proc.terminationStatus == 0 && proc.terminationReason == .exit ? .stopped : .crashed(message)
        let newState = state
        lock.unlock()
        for (_, w) in failed { w.continuation.resume(throwing: HelperError.crashed(message)) }
        onStateChange?(newState)
    }

    private func receivedStderr(_ data: Data) {
        guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
        lock.lock()
        stderrTail = String((stderrTail + s).suffix(2000))
        lock.unlock()
    }

    private func received(_ data: Data, from proc: Process) {
        guard !data.isEmpty else { return }
        var lines: [Data] = []
        lock.lock()
        guard process === proc else { lock.unlock(); return }
        stdoutBuffer.append(data)
        while let nl = stdoutBuffer.firstIndex(of: 0x0A) {
            lines.append(stdoutBuffer.subdata(in: stdoutBuffer.startIndex..<nl))
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...nl)
        }
        lock.unlock()
        for line in lines { handle(line) }
    }

    private func handle(_ line: Data) {
        guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return }
        if let event = obj["event"] as? String {
            if event == "progress", let id = obj["id"] as? Int {
                lock.lock()
                let cb = pending[id]?.progress
                lock.unlock()
                if let cb, let done = (obj["done"] as? NSNumber)?.int64Value,
                   let total = (obj["total"] as? NSNumber)?.int64Value {
                    cb(done, total)
                }
            }
            onEvent?(obj)
            return
        }
        guard let id = obj["id"] as? Int else { return }
        lock.lock()
        let waiter = pending.removeValue(forKey: id)
        lock.unlock()
        guard let waiter else { return }
        if let err = obj["error"] as? [String: Any] {
            waiter.continuation.resume(throwing: HelperError.remote(
                code: err["code"] as? String ?? "internal",
                message: err["message"] as? String ?? "unknown error",
                missing: err["missing"] as? [String] ?? []))
        } else if let result = obj["result"],
                  let data = try? JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed]) {
            waiter.continuation.resume(returning: data)
        } else {
            waiter.continuation.resume(throwing: HelperError.badResponse("no result"))
        }
    }

    // MARK: calls

    /// Send one request; returns the raw JSON of `result`.
    public func callRaw(_ method: String, _ params: [String: Any] = [:],
                        progress: (@Sendable (Int64, Int64) -> Void)? = nil) async throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: params)
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            lock.lock()
            do {
                try startLocked(force: false)
            } catch {
                lock.unlock()
                cont.resume(throwing: error)
                return
            }
            let id = nextID
            nextID += 1
            pending[id] = Pending(continuation: cont, progress: progress)
            var line = Data("{\"id\":\(id),\"method\":".utf8)
            line.append(try! JSONSerialization.data(withJSONObject: method, options: [.fragmentsAllowed]))
            line.append(Data(",\"params\":".utf8))
            line.append(body)
            line.append(Data("}\n".utf8))
            let input = stdin
            lock.unlock()
            do {
                try input?.write(contentsOf: line)
            } catch {
                lock.lock()
                let w = pending.removeValue(forKey: id)
                lock.unlock()
                w?.continuation.resume(throwing: HelperError.crashed("couldn't write to the helper"))
            }
        }
    }

    public func call<T: Decodable>(_ method: String, _ params: [String: Any] = [:], as: T.Type = T.self,
                                   progress: (@Sendable (Int64, Int64) -> Void)? = nil) async throws -> T {
        let data = try await callRaw(method, params, progress: progress)
        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            throw HelperError.badResponse("\(method): \(error)")
        }
    }

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    // MARK: typed API

    public func ping() async throws {
        _ = try await callRaw("ping")
    }

    public func translate(_ text: String, target: String, source: String? = nil) async throws -> TranslationResult {
        var params: [String: Any] = ["text": text, "target": target]
        if let source { params["source"] = source }
        return try await call("translate", params)
    }

    public func detect(_ text: String) async throws -> String {
        struct R: Decodable { var lang: String }
        return try await call("detect", ["text": text], as: R.self).lang
    }

    public func languages(installedOnly: Bool = false) async throws -> LanguageList {
        try await call("languages", ["installed_only": installedOnly])
    }

    public func installed() async throws -> [String] {
        struct R: Decodable { var languages: [String] }
        return try await call("installed", as: R.self).languages
    }

    @discardableResult
    public func updateCatalog() async throws -> String {
        struct R: Decodable { var version: String }
        return try await call("update_catalog", as: R.self).version
    }

    public func download(_ lang: String, force: Bool = false,
                         progress: (@Sendable (Int64, Int64) -> Void)? = nil) async throws {
        _ = try await callRaw("download", ["lang": lang, "force": force], progress: progress)
    }

    @discardableResult
    public func cancel(_ lang: String) async throws -> Bool {
        struct R: Decodable { var cancelled: Bool }
        return try await call("cancel", ["lang": lang], as: R.self).cancelled
    }

    public func remove(_ lang: String) async throws {
        _ = try await callRaw("remove", ["lang": lang])
    }

    public func preload(source: String, target: String) async throws {
        _ = try await callRaw("preload", ["source": source, "target": target])
    }

    public func unload() async throws {
        _ = try await callRaw("unload")
    }
}

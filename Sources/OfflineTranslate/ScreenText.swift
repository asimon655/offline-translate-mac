import AppKit
import TranslateCore

/// Translate text in a screenshot: the user drags over an area (the system screenshot tool), Vision reads the text.
enum ScreenText {
    enum Failure: Error { case cancelled, noText, failed(String) }

    /// Lets the user drag over an area and returns the text in it.
    @MainActor
    static func capture() async -> Result<String, Failure> {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ot-capture-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: file) }
        let status: Int32 = await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-i", "-x", "-o", file.path]  // interactive area, no sound, no window shadow
            p.terminationHandler = { cont.resume(returning: $0.terminationStatus) }
            do { try p.run() } catch { cont.resume(returning: -1) }
        }
        guard status == 0, FileManager.default.fileExists(atPath: file.path) else { return .failure(.cancelled) }
        guard let image = NSImage(contentsOf: file)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return .failure(.failed("Couldn't read the screenshot."))
        }
        return await Task.detached { recognize(image) }.value
    }

    static func recognize(_ image: CGImage) -> Result<String, Failure> {
        do {
            guard let text = try TextRecognition.recognize(image) else { return .failure(.noText) }
            return .success(text)
        } catch {
            return .failure(.failed(error.localizedDescription))
        }
    }
}

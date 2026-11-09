import CoreGraphics
import Vision

/// Reads text in an image with the Vision framework (used for "Translate Text on Screen").
public enum TextRecognition {
    /// The recognised text, lines of a paragraph joined with spaces; nil if there is none.
    public static func recognize(_ image: CGImage) throws -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        let text = joinLines(lines)
        return text.isEmpty ? nil : text
    }

    /// Joins OCR lines with spaces, re-joining words hyphenated across a line break.
    /// The translator splits sentences itself, so line breaks inside a paragraph only hurt.
    public static func joinLines(_ lines: [String]) -> String {
        var out = ""
        for line in lines.map({ $0.trimmingCharacters(in: .whitespaces) }) where !line.isEmpty {
            if out.isEmpty {
                out = line
            } else if out.hasSuffix("-") {
                out.removeLast()
                out += line
            } else {
                out += " " + line
            }
        }
        return out
    }
}

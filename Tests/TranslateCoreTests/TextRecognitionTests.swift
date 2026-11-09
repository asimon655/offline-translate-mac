import AppKit
import Testing
@testable import TranslateCore

@Suite struct TextRecognitionTests {
    @Test func joinsLinesAndHyphenation() {
        #expect(TextRecognition.joinLines(["Please bring the", "signed con-", "tract.", "", "  Thanks "]) ==
                "Please bring the signed contract. Thanks")
        #expect(TextRecognition.joinLines([]) == "")
    }

    /// Renders text into an image and reads it back.
    func image(_ text: String) -> CGImage {
        let size = NSSize(width: 900, height: 160)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        (text as NSString).draw(in: NSRect(x: 20, y: 20, width: 860, height: 120),
                                withAttributes: [.font: NSFont.systemFont(ofSize: 40), .foregroundColor: NSColor.black])
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage!
    }

    @Test func readsRenderedEnglish() throws {
        let text = try TextRecognition.recognize(image("Please bring your ID tomorrow."))
        #expect(text == "Please bring your ID tomorrow.")
    }

    @Test func blankImageHasNoText() throws {
        #expect(try TextRecognition.recognize(image("")) == nil)
    }
}

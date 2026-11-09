import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// What was selected, and where on screen (Cocoa coordinates, origin bottom-left), if the app tells us.
struct Selection {
    var text: String?
    var rect: NSRect?
    var method: Method

    enum Method { case accessibility, copy, none }
}

/// Reads the selected text of the frontmost app.
///
/// First through the Accessibility API (kAXSelectedTextAttribute, then the selected range); if the app doesn't
/// expose its selection (some Electron/Java apps), by saving the clipboard, posting ⌘C and restoring it.
enum SelectionReader {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Show the system prompt that adds the app to Privacy & Security → Accessibility.
    static func requestTrust() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)
    }

    /// First time: the system prompt, which adds the app to the Accessibility list and has its own
    /// "Open System Settings" button. Later (the app is already listed): go straight to that settings pane.
    /// Doing both at once leaves the prompt hanging around after access is granted.
    static func requestAccess() {
        let key = "accessibilityPrompted"
        if UserDefaults.standard.bool(forKey: key) {
            openAccessibilitySettings()
        } else {
            UserDefaults.standard.set(true, forKey: key)
            requestTrust()
        }
    }

    static func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    /// A password field has focus: macOS hides keystrokes and selections from other apps.
    static var secureInputActive: Bool { IsSecureEventInputEnabled() }

    @MainActor
    static func read(clipboardFallback: Bool) async -> Selection {
        var rect: NSRect?
        if let element = focusedElement() {
            rect = selectionBounds(element)
            if let text = selectedText(element), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return Selection(text: text, rect: rect, method: .accessibility)
            }
        }
        if clipboardFallback, let text = await copyViaCommandC(),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Selection(text: text, rect: rect, method: .copy)
        }
        return Selection(text: nil, rect: rect, method: .none)
    }

    // MARK: Accessibility

    private static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.5)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func selectedText(_ element: AXUIElement) -> String? {
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value) == .success,
           let s = value as? String, !s.isEmpty {
            return s
        }
        guard let range = selectedRange(element), range.length > 0 else { return nil }
        var rangeValue = range
        guard let axRange = AXValueCreate(.cfRange, &rangeValue) else { return nil }
        var str: CFTypeRef?
        if AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString,
                                                      axRange, &str) == .success {
            return str as? String
        }
        return nil
    }

    private static func selectedRange(_ element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        return AXValueGetValue(value as! AXValue, .cfRange, &range) ? range : nil
    }

    private static func selectionBounds(_ element: AXUIElement) -> NSRect? {
        guard var range = selectedRange(element), range.length > 0,
              let axRange = AXValueCreate(.cfRange, &range) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                         axRange, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var r = CGRect.zero
        guard AXValueGetValue(value as! AXValue, .cgRect, &r), r.width > 0 || r.height > 0 else { return nil }
        // AX uses top-left origin on the primary screen; Cocoa uses bottom-left.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    // MARK: ⌘C fallback

    @MainActor
    private static func copyViaCommandC() async -> String? {
        let pb = NSPasteboard.general
        let saved = snapshot(pb)
        let before = pb.changeCount
        postKey(UInt16(kVK_ANSI_C), flags: .maskCommand)
        var text: String?
        for _ in 0..<25 {  // up to ~250 ms for the app to respond
            try? await Task.sleep(nanoseconds: 10_000_000)
            if pb.changeCount != before {
                text = pb.string(forType: .string)
                break
            }
        }
        if pb.changeCount != before { restore(pb, saved) }
        return text
    }

    /// Put text on the clipboard, paste it with ⌘V into the frontmost app, then restore the clipboard.
    @MainActor
    static func paste(_ text: String) async {
        let pb = NSPasteboard.general
        let saved = snapshot(pb)
        pb.clearContents()
        pb.setString(text, forType: .string)
        postKey(UInt16(kVK_ANSI_V), flags: .maskCommand)
        try? await Task.sleep(nanoseconds: 400_000_000)
        restore(pb, saved)
    }

    static func postKey(_ key: UInt16, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
        }
    }

    private static func snapshot(_ pb: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pb.pasteboardItems ?? []).map { item in
            var d: [NSPasteboard.PasteboardType: Data] = [:]
            for t in item.types { if let data = item.data(forType: t) { d[t] = data } }
            return d
        }
    }

    private static func restore(_ pb: NSPasteboard, _ items: [[NSPasteboard.PasteboardType: Data]]) {
        pb.clearContents()
        let objects = items.map { dict -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (t, data) in dict { item.setData(data, forType: t) }
            return item
        }
        if !objects.isEmpty { pb.writeObjects(objects) }
    }
}

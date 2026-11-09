import AppKit
import Carbon.HIToolbox

/// A global keyboard shortcut: a virtual key code plus Carbon modifier flags.
struct Shortcut: Codable, Equatable, Hashable {
    var keyCode: UInt32
    var modifiers: UInt32  // Carbon: cmdKey, optionKey, controlKey, shiftKey

    static let translateDefault = Shortcut(keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(optionKey | shiftKey))
    static let clipboardDefault = Shortcut(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(optionKey | shiftKey))
    static let screenDefault = Shortcut(keyCode: UInt32(kVK_ANSI_O), modifiers: UInt32(optionKey | shiftKey))

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        // Shift alone isn't enough: it would swallow normal typing.
        guard m & UInt32(cmdKey | optionKey | controlKey) != 0 else { return nil }
        self.init(keyCode: UInt32(event.keyCode), modifiers: m)
    }

    var modifierFlags: NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if modifiers & UInt32(cmdKey) != 0 { f.insert(.command) }
        if modifiers & UInt32(optionKey) != 0 { f.insert(.option) }
        if modifiers & UInt32(controlKey) != 0 { f.insert(.control) }
        if modifiers & UInt32(shiftKey) != 0 { f.insert(.shift) }
        return f
    }

    static func symbols(_ f: NSEvent.ModifierFlags) -> String {
        (f.contains(.control) ? "⌃" : "") + (f.contains(.option) ? "⌥" : "") + (f.contains(.shift) ? "⇧" : "")
            + (f.contains(.command) ? "⌘" : "")
    }

    /// "⌥⇧T"
    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + keyName
    }

    /// The character for NSMenuItem.keyEquivalent ("t"), empty for keys without one.
    var menuKeyEquivalent: String {
        let name = keyName
        return name.count == 1 ? name.lowercased() : ""
    }

    var keyName: String {
        let special: [Int: String] = [
            kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Delete: "⌫", kVK_Escape: "⎋",
            kVK_ForwardDelete: "⌦", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        ]
        if let s = special[Int(keyCode)] { return s }
        return Self.character(for: keyCode)?.uppercased() ?? "#\(keyCode)"
    }

    /// The character a key produces on the current (ASCII-capable) layout, so "T" shows as "T" on Dvorak too.
    private static func character(for keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        return data.withUnsafeBytes { raw -> String? in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var dead: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            let status = UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                                        UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                        &dead, chars.count, &length, &chars)
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: chars, count: length)
        }
    }
}

/// Registers global hotkeys with Carbon's RegisterEventHotKey: no permission needed, and the key press
/// is consumed so the frontmost app never sees it.
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var shortcuts: [UInt32: Shortcut] = [:]
    private var nextID: UInt32 = 1
    private var installed = false
    private var suspended = false

    /// Register a shortcut. Returns nil on success, or a message (e.g. another app already uses it).
    @discardableResult
    func register(_ shortcut: Shortcut, id existing: UInt32? = nil, handler: @escaping () -> Void) -> (UInt32, String?) {
        installHandler()
        let id = existing ?? nextID
        if existing == nil { nextID += 1 }
        unregister(id)
        handlers[id] = handler
        shortcuts[id] = shortcut
        return (id, suspended ? nil : activate(id))
    }

    func unregister(_ id: UInt32) {
        if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
        handlers[id] = nil
        shortcuts[id] = nil
    }

    /// Temporarily release all hotkeys (while the shortcut recorder listens for keys).
    func suspend() {
        suspended = true
        for (_, ref) in refs { UnregisterEventHotKey(ref) }
        refs = [:]
    }

    func resume() {
        suspended = false
        for id in shortcuts.keys { _ = activate(id) }
    }

    private func activate(_ id: UInt32) -> String? {
        guard let s = shortcuts[id] else { return nil }
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: OSType(0x4F54524E), id: id)  // 'OTRN'
        let status = RegisterEventHotKey(s.keyCode, s.modifiers, hkID, GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            refs[id] = ref
            return nil
        }
        return status == eventHotKeyExistsErr ? "\(s.display) is already used by another app." : "Couldn't register \(s.display) (error \(status))."
    }

    private func installHandler() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            DispatchQueue.main.async { HotKeyCenter.shared.handlers[id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

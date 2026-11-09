import AppKit
import SwiftUI
import TranslateCore

enum SettingsTab: String, CaseIterable {
    case general, shortcuts, languages, history, about
    case welcome  // the first-run window, not a tab

    var title: String { rawValue.capitalized }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .shortcuts: return "keyboard"
        case .languages: return "globe"
        case .history: return "clock.arrow.circlepath"
        case .about: return "info.circle"
        case .welcome: return "hand.wave"
        }
    }
}

final class SettingsSelection: ObservableObject {
    @Published var tab: SettingsTab = .general
}

/// A regular window hosting SwiftUI. The app has no Dock icon, so it activates itself when this opens.
@MainActor
final class WindowPresenter<Content: View>: NSObject, NSWindowDelegate {
    private(set) var window: NSWindow?
    private let title: String
    private let make: () -> Content
    var onClose: (() -> Void)?

    init(title: String, make: @escaping () -> Content) {
        self.title = title
        self.make = make
    }

    var isOpen: Bool { window != nil }

    func show() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: make()))
            w.title = title
            w.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func close() { window?.close() }

    func windowWillClose(_ notification: Notification) {
        window = nil
        onClose?()
    }
}

struct SettingsView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var prefs: Preferences
    @ObservedObject var selection: SettingsSelection

    var body: some View {
        TabView(selection: $selection.tab) {
            GeneralTab(app: app, prefs: prefs).tabItem { Label("General", systemImage: SettingsTab.general.symbol) }
                .tag(SettingsTab.general)
            ShortcutsTab(app: app, prefs: prefs).tabItem { Label("Shortcuts", systemImage: SettingsTab.shortcuts.symbol) }
                .tag(SettingsTab.shortcuts)
            LanguagesView(app: app).tabItem { Label("Languages", systemImage: SettingsTab.languages.symbol) }
                .tag(SettingsTab.languages)
            HistoryTab(app: app, prefs: prefs).tabItem { Label("History", systemImage: SettingsTab.history.symbol) }
                .tag(SettingsTab.history)
            AboutTab(app: app).tabItem { Label("About", systemImage: SettingsTab.about.symbol) }
                .tag(SettingsTab.about)
        }
        .frame(width: 620, height: 520)
        .safeAreaInset(edge: .bottom) { ErrorBanner(app: app) }
    }
}

struct ErrorBanner: View {
    @ObservedObject var app: AppModel

    var body: some View {
        if let error = app.lastError {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(error).lineLimit(2)
                Spacer()
                Button("Dismiss") { app.lastError = nil }.controlSize(.small)
            }
            .font(.callout)
            .padding(10)
            .background(.bar)
        }
    }
}

// MARK: General

struct GeneralTab: View {
    @ObservedObject var app: AppModel
    @ObservedObject var prefs: Preferences

    var body: some View {
        Form {
            Section {
                Picker("Translate into", selection: $prefs.mainLanguage) {
                    ForEach(app.installed, id: \.self) { Text(app.name($0)).tag($0) }
                }
                Text("Text in other languages is translated into this one. Text already in it goes to the last other language you picked.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Reading the selection") {
                LabeledContent("Accessibility access") {
                    if app.accessibilityTrusted {
                        Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Allow…") {
                            SelectionReader.requestAccess()
                        }
                    }
                }
                Toggle("Copy the selection with ⌘C when an app doesn't share it", isOn: $prefs.clipboardFallback)
                Text("Some apps hide their selection from macOS. The app then briefly uses the clipboard and puts back what was on it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Startup and memory") {
                Toggle("Launch at login", isOn: Binding(get: { app.launchAtLogin }, set: { app.launchAtLogin = $0 }))
                Picker("Free memory when idle for", selection: $prefs.idleUnloadMinutes) {
                    Text("5 minutes").tag(5)
                    Text("10 minutes").tag(10)
                    Text("30 minutes").tag(30)
                    Text("Never").tag(0)
                }
                Text("Each loaded language direction uses about 110 MB. The next translation after it's freed takes about half a second longer.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Shortcuts

struct ShortcutsTab: View {
    @ObservedObject var app: AppModel
    @ObservedObject var prefs: Preferences

    var body: some View {
        Form {
            Section {
                row("Translate selection", $prefs.translateShortcut, Shortcut.translateDefault, "translate")
                row("Translate clipboard", $prefs.clipboardShortcut, Shortcut.clipboardDefault, "clipboard")
                row("Translate text on screen", $prefs.screenShortcut, Shortcut.screenDefault, "screen")
            } footer: {
                Text("Click a shortcut, then press the new key combination. It needs ⌘, ⌥ or ⌃. Esc cancels.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func row(_ title: String, _ binding: Binding<Shortcut>, _ fallback: Shortcut, _ key: String) -> some View {
        LabeledContent(title) {
            VStack(alignment: .trailing, spacing: 4) {
                HStack {
                    ShortcutRecorder(shortcut: binding) { app.registerHotkeys() }
                    if binding.wrappedValue != fallback {
                        Button("Reset") {
                            binding.wrappedValue = fallback
                            app.registerHotkeys()
                        }
                        .controlSize(.small)
                    }
                }
                if let error = app.hotkeyErrors[key] {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
        }
    }
}

/// Click, then press a key combination. Global hotkeys are paused while recording so the current one can be re-pressed.
struct ShortcutRecorder: View {
    @Binding var shortcut: Shortcut
    var onChange: () -> Void
    @StateObject private var ui = UIState()

    /// View-local state (see LanguagesView.UIState for why this isn't @State).
    final class UIState: ObservableObject {
        @Published var recording = false
        var monitor: Any?
    }

    var body: some View {
        Button {
            ui.recording ? stop() : start()
        } label: {
            Text(ui.recording ? "Press keys…" : shortcut.display)
                .font(.system(.body, design: .rounded).monospaced())
                .frame(minWidth: 90)
        }
        .buttonStyle(.bordered)
        .tint(ui.recording ? .accentColor : nil)
        .onDisappear { stop() }
    }

    private func start() {
        ui.recording = true
        HotKeyCenter.shared.suspend()
        ui.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {  // Esc
                stop()
            } else if let s = Shortcut(event: event) {
                shortcut = s
                stop()
            } else {
                NSSound.beep()
            }
            return nil
        }
    }

    private func stop() {
        guard ui.recording else { return }
        ui.recording = false
        if let monitor = ui.monitor { NSEvent.removeMonitor(monitor) }
        ui.monitor = nil
        HotKeyCenter.shared.resume()
        onChange()
    }
}

// MARK: History

struct HistoryTab: View {
    @ObservedObject var app: AppModel
    @ObservedObject var prefs: Preferences

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Toggle("Keep a history of translations", isOn: $prefs.keepHistory)
                Spacer()
                Button("Clear History") { app.clearHistory() }.disabled(app.historyEntries.isEmpty)
            }
            .padding(12)
            Divider()
            if app.historyEntries.isEmpty {
                ContentUnavailableView("No translations yet", systemImage: "clock",
                                       description: Text("Translations stay on this Mac."))
            } else {
                List(app.historyEntries) { e in
                    HistoryRow(app: app, entry: e)
                }
            }
        }
    }
}

struct HistoryRow: View {
    let app: AppModel
    let entry: HistoryEntry

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.translation)
                    .frame(maxWidth: .infinity, alignment: LanguageRules.isRightToLeft(entry.target) ? .trailing : .leading)
                    .textSelection(.enabled)
                Text(entry.original)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: LanguageRules.isRightToLeft(entry.source) ? .trailing : .leading)
                    .lineLimit(2)
                Text("\(app.name(entry.source)) → \(app.name(entry.target)) · \(entry.date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.translation, forType: .string)
            } label: { Image(systemName: "doc.on.doc") }
            .buttonStyle(.borderless)
            .help("Copy translation")
        }
        .padding(.vertical, 4)
    }
}

// MARK: About

struct AboutTab: View {
    @ObservedObject var app: AppModel

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
            Text("Offline Translate").font(.title2.bold())
            Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")")
                .foregroundStyle(.secondary)
            Text("Translates on this Mac with Google Translate's offline language packs, through the offline-translate library. Text never leaves your computer; the app only goes online to download languages and check for updates.")
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            HStack {
                Button("Show Language Folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([app.prefs.modelsDir])
                }
                Button("Restart Translation Engine") { app.restartHelper() }
            }
            Link("github.com/asimon655/offline-translate", destination: URL(string: "https://github.com/asimon655/offline-translate")!)
            Text("Not affiliated with or endorsed by Google. Language packs are downloaded from Google's servers and are subject to Google's terms.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

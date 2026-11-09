import SwiftUI
import TranslateCore

/// First run: Accessibility access, the shortcut, and a first language with a test sentence.
struct OnboardingView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var prefs: Preferences
    var onDone: () -> Void

    @StateObject private var ui = UIState()

    /// View-local state (see LanguagesView.UIState for why this isn't @State).
    final class UIState: ObservableObject {
        @Published var step = 0
        @Published var choice = ""
        @Published var testResult: String?
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 48, height: 48)
                VStack(alignment: .leading) {
                    Text("Welcome to Offline Translate").font(.title2.bold())
                    Text("Select text anywhere, press a shortcut, read the translation. Everything runs on this Mac.")
                        .foregroundStyle(.secondary)
                }
            }
            stepRow(0, "Allow Accessibility", done: app.accessibilityTrusted) { accessibility }
            stepRow(1, "Pick a shortcut", done: ui.step > 1) { shortcut }
            stepRow(2, "Download a language", done: languageReady) { language }
            HStack {
                Spacer()
                Button(ui.step < 2 ? "Skip" : "Done") { finish() }
                    .keyboardShortcut(ui.step < 2 ? .cancelAction : .defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            if app.accessibilityTrusted { ui.step = max(ui.step, 1) }
            ui.choice = defaultChoice
        }
        .onChange(of: app.accessibilityTrusted) { _, trusted in if trusted && ui.step == 0 { ui.step = 1 } }
        .onChange(of: app.languages) { _, _ in if ui.choice.isEmpty || app.language(ui.choice) == nil { ui.choice = defaultChoice } }
    }

    private func finish() {
        prefs.onboardingDone = true
        onDone()
    }

    private var languageReady: Bool { app.installed.contains { $0 != "en" } }

    /// The Mac's language if it isn't English, otherwise Hebrew (or the first installed language).
    private var defaultChoice: String {
        let system = LanguageRules.systemLanguage()
        if system != "en", app.language(system)?.supported ?? true { return system }
        return app.installed.first { $0 != "en" } ?? "iw"
    }

    private func stepRow<C: View>(_ index: Int, _ title: String, done: Bool, @ViewBuilder content: () -> C) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(done ? Color.green : index == ui.step ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 26, height: 26)
                if done {
                    Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white)
                } else {
                    Text("\(index + 1)").font(.callout.bold()).foregroundStyle(.white)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                if index == ui.step || (index < ui.step && !done) { content() }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { if index <= max(ui.step, app.accessibilityTrusted ? 1 : 0) + 1 { ui.step = index } }
    }

    private var accessibility: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("The app reads only the selected text, and only when you press the shortcut. macOS asks you to allow this in Privacy & Security → Accessibility.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Open System Settings") {
                    SelectionReader.requestAccess()
                }
                .buttonStyle(.borderedProminent)
                if !app.accessibilityTrusted {
                    ProgressView().controlSize(.small)
                    Text("Waiting for access…").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var shortcut: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Translate selection:")
                ShortcutRecorder(shortcut: $prefs.translateShortcut) { app.registerHotkeys() }
            }
            if let error = app.hotkeyErrors["translate"] {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            Text("Click to record a different one. Clipboard and on-screen text shortcuts are in Settings.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Continue") { ui.step = 2 }.buttonStyle(.borderedProminent)
        }
    }

    private var language: some View {
        VStack(alignment: .leading, spacing: 10) {
            let options = app.languages.filter { !$0.builtin && $0.supported }
            if options.isEmpty {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Getting the list of languages…").foregroundStyle(.secondary)
                }
                .task { if app.languages.isEmpty { await app.checkForUpdates() } }
            } else {
                HStack {
                    Picker("Language", selection: $ui.choice) {
                        ForEach(options) { Text($0.name).tag($0.code) }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                    if let lang = app.language(ui.choice) {
                        if lang.installed {
                            Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        } else if let p = app.downloads[ui.choice] {
                            ProgressView(value: p.fraction).frame(width: 120)
                            Button("Cancel") { app.cancelDownload(ui.choice) }
                        } else {
                            Button("Download · \(LanguageRules.formatBytes(lang.downloadSize))") { app.download(ui.choice) }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                }
                Text("Every language translates to and from English, and between each other through English.")
                    .font(.caption).foregroundStyle(.secondary)
                if app.installed.contains(ui.choice) && ui.choice != "en" {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Try it: “Good morning! Thanks for your help.”").font(.callout)
                        Text(ui.testResult ?? "Translating…")
                            .font(.title3)
                            .frame(maxWidth: .infinity, alignment: LanguageRules.isRightToLeft(ui.choice) ? .trailing : .leading)
                    }
                    .padding(10)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                    .task(id: ui.choice) {
                        ui.testResult = nil
                        ui.testResult = (try? await app.translate("Good morning! Thanks for your help.", source: "en",
                                                               target: ui.choice, record: false).text) ?? "Couldn't translate."
                    }
                }
            }
        }
    }
}

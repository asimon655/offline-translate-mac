import SwiftUI
import TranslateCore

/// Settings → Languages: the catalog, downloads with progress, cancel, remove, updates.
struct LanguagesView: View {
    @ObservedObject var app: AppModel
    @StateObject private var ui = UIState()

    /// View-local state. (A class instead of @State: in the macOS 27 SDK @State is a macro whose plugin ships
    /// only with Xcode, and this project builds with the Command Line Tools alone.)
    final class UIState: ObservableObject {
        @Published var search = ""
        @Published var confirmRemove: LanguageInfo?
    }

    private var filtered: [LanguageInfo] {
        let q = ui.search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return app.languages }
        return app.languages.filter { $0.name.lowercased().contains(q) || $0.code.lowercased().hasPrefix(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                TextField("Search \(app.languages.count) languages", text: $ui.search)
                    .textFieldStyle(.roundedBorder)
                Button {
                    Task { await app.checkForUpdates() }
                } label: {
                    if app.checkingForUpdates {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Check for Updates")
                    }
                }
                .disabled(app.checkingForUpdates)
            }
            .padding(12)
            Divider()
            if app.languages.isEmpty {
                ContentUnavailableView {
                    Label("No language list yet", systemImage: "globe")
                } description: {
                    Text("The list of languages is downloaded from Google once (about 250 KB).")
                } actions: {
                    Button("Download List") { Task { await app.checkForUpdates() } }
                }
            } else {
                List {
                    section("Installed", filtered.filter { $0.installed && app.downloads[$0.code] == nil })
                    section("Downloading", filtered.filter { app.downloads[$0.code] != nil })
                    section("Available", filtered.filter { !$0.installed && $0.supported && app.downloads[$0.code] == nil })
                    section("Not supported yet", filtered.filter { !$0.installed && !$0.supported })
                }
            }
            HStack {
                Text(footer).font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .task { await app.refreshLanguages() }
        .confirmationDialog("Remove \(ui.confirmRemove?.name ?? "")?", isPresented: Binding(
            get: { ui.confirmRemove != nil }, set: { if !$0 { ui.confirmRemove = nil } }
        ), presenting: ui.confirmRemove) { lang in
            Button("Remove", role: .destructive) { Task { await app.remove(lang.code) } }
        } message: { lang in
            Text("This frees \(LanguageRules.formatBytes(lang.size)). You can download it again later.")
        }
    }

    private var footer: String {
        let used = app.languages.filter(\.installed).reduce(Int64(0)) { $0 + $1.size }
        var s = "\(LanguageRules.formatBytes(used)) used by languages"
        if let v = app.catalogVersion { s += " · catalog \(v)" }
        if let last = app.prefs.lastCatalogCheck { s += " · checked \(last.formatted(.relative(presentation: .named)))" }
        return s
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [LanguageInfo]) -> some View {
        if !items.isEmpty {
            Section(title) {
                ForEach(items) { LanguageRow(app: app, lang: $0, confirmRemove: $ui.confirmRemove) }
            }
        }
    }
}

struct LanguageRow: View {
    @ObservedObject var app: AppModel
    let lang: LanguageInfo
    @Binding var confirmRemove: LanguageInfo?

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(lang.name)
                Text(lang.code).font(.caption).foregroundStyle(.tertiary)
            }
            Spacer()
            trailing
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var trailing: some View {
        if let p = app.downloads[lang.code] {
            ProgressView(value: p.fraction).frame(width: 120)
            Text("\(LanguageRules.formatBytes(p.done)) / \(LanguageRules.formatBytes(p.total))")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 110, alignment: .trailing)
            Button("Cancel") { app.cancelDownload(lang.code) }
        } else if lang.builtin {
            Text("Built in").foregroundStyle(.secondary)
        } else if lang.installed {
            Text(LanguageRules.formatBytes(lang.size)).foregroundStyle(.secondary)
            if lang.updateAvailable {
                Button("Update · \(LanguageRules.formatBytes(lang.downloadSize))") { app.download(lang.code) }
                    .buttonStyle(.borderedProminent)
            }
            Button("Remove") { confirmRemove = lang }
        } else if !lang.supported {
            Text("\(LanguageRules.formatBytes(lang.downloadSize)) · not supported yet")
                .foregroundStyle(.tertiary)
                .help("This language still uses an older model format that offline-translate can't run yet.")
        } else {
            Text(LanguageRules.formatBytes(lang.downloadSize)).foregroundStyle(.secondary)
            Button("Download") { app.download(lang.code) }
        }
    }
}

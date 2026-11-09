import AppKit
import Combine
import SwiftUI
import TranslateCore

/// State of one popup: the original text and the translation in progress.
@MainActor
final class PopupModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case loading
        case done(TranslationResult)
        case notInstalled([String])
        case failed(String)
    }

    @Published var original = ""
    @Published var source = "en"
    @Published var target = "en"
    @Published var phase: Phase = .idle
    @Published var pinned = false
    @Published var copied = false

    private var generation = 0
    let app: AppModel
    var onClose: (() -> Void)?
    var onReplace: ((String) -> Void)?
    var onOpenLanguages: (() -> Void)?

    init(app: AppModel) {
        self.app = app
    }

    /// Detect, pick a target, translate. Results of superseded requests are dropped.
    func start(text: String) {
        original = text
        copied = false
        generation += 1
        let gen = generation
        phase = .loading
        Task {
            do {
                let source = try await app.detect(text)
                guard gen == generation else { return }
                self.source = source
                self.target = app.prefs.target(for: source, installed: app.installed)
                await run(gen)
            } catch {
                if gen == generation { fail(error) }
            }
        }
    }

    func show(error message: String) {
        generation += 1
        original = ""
        phase = .failed(message)
    }

    func setSource(_ code: String) {
        guard code != source else { return }
        if code == target { target = source }
        source = code
        retranslate(remember: false)
    }

    func setTarget(_ code: String) {
        guard code != target else { return }
        if code == source { source = target }
        target = code
        retranslate(remember: true)
    }

    func swap() {
        let s = source
        source = target
        target = s
        if case .done(let r) = phase { original = r.text }
        retranslate(remember: true)
    }

    func retranslate(remember: Bool = false) {
        guard !original.isEmpty else { return }
        if remember { app.prefs.remember(source: source, target: target) }
        generation += 1
        let gen = generation
        phase = .loading
        Task { await run(gen) }
    }

    private func run(_ gen: Int) async {
        if source == target {
            phase = .done(TranslationResult(text: original, source: source, target: target, via: [source], ms: 0))
            return
        }
        do {
            let r = try await app.translate(original, source: source, target: target)
            if gen == generation { phase = .done(r) }
        } catch {
            if gen == generation { fail(error) }
        }
    }

    private func fail(_ error: Error) {
        if let e = error as? HelperError, e.code == "not_installed" {
            phase = .notInstalled(e.missing)
        } else {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Download the missing languages, then translate again.
    func downloadMissing(_ codes: [String]) {
        for c in codes { app.download(c) }
        Task {
            while codes.contains(where: { app.downloads[$0] != nil }) {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            if codes.allSatisfy({ app.installed.contains($0) }) { retranslate() }
        }
    }

    var resultText: String? {
        if case .done(let r) = phase { return r.text }
        return nil
    }

    func copy() {
        guard let text = resultText else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
    }
}

/// A floating, non-activating panel: it shows over the current app without taking focus from it.
final class PopupPanel: NSPanel {
    var onEscape: (() -> Void)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 400, height: 160),
                   styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                   backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        animationBehavior = .utilityWindow
    }

    // Becomes key only when clicked, so buttons and text selection work; the other app stays active.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

@MainActor
final class PopupController {
    let model: PopupModel
    private let panel = PopupPanel()
    private var hosting: NSHostingView<PopupView>!
    private var monitors: [Any] = []
    private var anchorTop = true
    private var anchor = NSPoint.zero
    private var sink: AnyCancellable?

    init(app: AppModel) {
        model = PopupModel(app: app)
        hosting = NSHostingView(rootView: PopupView(model: model, app: app))
        panel.contentView = hosting
        panel.onEscape = { [weak self] in self?.close() }
        model.onClose = { [weak self] in self?.close() }
        // Re-fit the panel whenever its content changes (loading → result, errors, language menus).
        sink = model.objectWillChange.merge(with: app.objectWillChange).sink { [weak self] _ in
            DispatchQueue.main.async { self?.fit() }
        }
    }

    var isVisible: Bool { panel.isVisible }
    var view: NSView? { panel.contentView }

    func show(text: String, near rect: NSRect?) {
        model.pinned = false
        model.start(text: text)
        present(near: rect)
    }

    func show(error: String, near rect: NSRect?) {
        model.pinned = false
        model.show(error: error)
        present(near: rect)
    }

    private func present(near rect: NSRect?) {
        let mouse = NSEvent.mouseLocation
        let target = rect ?? NSRect(x: mouse.x - 20, y: mouse.y - 8, width: 1, height: 1)
        let screen = NSScreen.screens.first { $0.frame.intersects(target) || $0.frame.contains(mouse) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = fittingSize()
        // Below the selection if it fits, otherwise above it.
        anchorTop = target.minY - 8 - size.height >= visible.minY
        let x = min(max(target.minX, visible.minX + 8), visible.maxX - size.width - 8)
        anchor = NSPoint(x: x, y: anchorTop ? target.minY - 8 : target.maxY + 8)
        fit()
        panel.orderFrontRegardless()
        installMonitors()
    }

    private func fittingSize() -> NSSize {
        hosting.layoutSubtreeIfNeeded()
        let s = hosting.fittingSize
        return NSSize(width: max(s.width, 300), height: max(s.height, 60))
    }

    private func fit() {
        guard panel.isVisible || anchor != .zero else { return }
        let size = fittingSize()
        var frame = NSRect(origin: .zero, size: size)
        frame.origin.x = anchor.x
        frame.origin.y = anchorTop ? anchor.y - size.height : anchor.y
        if let visible = (panel.screen ?? NSScreen.main)?.visibleFrame {
            frame.origin.y = min(max(frame.origin.y, visible.minY + 4), visible.maxY - size.height - 4)
        }
        if frame != panel.frame { panel.setFrame(frame, display: true) }
    }

    func close() {
        panel.orderOut(nil)
        anchor = .zero
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors = []
    }

    func replaceSelection() {
        guard let text = model.resultText else { return }
        close()
        Task { await SelectionReader.paste(text) }
    }

    private func installMonitors() {
        guard monitors.isEmpty else { return }
        // Clicks in other apps close the popup unless it's pinned.
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.model.pinned else { return }
                self.close()
            }
        }) { monitors.append(m) }
        // Esc while another app has focus (needs Accessibility, which the app has anyway).
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            guard e.keyCode == 53 else { return }
            Task { @MainActor in self?.close() }
        }) { monitors.append(m) }
    }
}

// MARK: - SwiftUI

struct PopupView: View {
    @ObservedObject var model: PopupModel
    @ObservedObject var app: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !model.original.isEmpty {
                header
                Divider()
            }
            content
            if !model.original.isEmpty {
                Text(model.original)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: LanguageRules.isRightToLeft(model.source) ? .trailing : .leading)
                    .multilineTextAlignment(LanguageRules.isRightToLeft(model.source) ? .trailing : .leading)
            }
            footer
        }
        .padding(14)
        .frame(width: 400)
        .fixedSize(horizontal: false, vertical: true)
        .background(VisualEffectBackground())
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator.opacity(0.6)))
    }

    private var header: some View {
        HStack(spacing: 6) {
            languageMenu(selection: model.source, action: model.setSource)
            Button(action: model.swap) { Image(systemName: "arrow.left.arrow.right") }
                .buttonStyle(.borderless)
                .help("Swap languages")
            languageMenu(selection: model.target, action: model.setTarget, showMore: true)
            Spacer()
            Button { model.pinned.toggle() } label: {
                Image(systemName: model.pinned ? "pin.fill" : "pin")
            }
            .buttonStyle(.borderless)
            .help(model.pinned ? "Unpin: close when clicking elsewhere" : "Pin: keep open")
            Button { model.onClose?() } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("Close (Esc)")
        }
        .font(.system(size: 12, weight: .medium))
    }

    private func languageMenu(selection: String, action: @escaping (String) -> Void, showMore: Bool = false) -> some View {
        Menu {
            ForEach(app.installed, id: \.self) { code in
                Button {
                    action(code)
                } label: {
                    if code == selection { Label(app.name(code), systemImage: "checkmark") } else { Text(app.name(code)) }
                }
            }
            if showMore {
                Divider()
                Button("More Languages…") { model.onOpenLanguages?() }
            }
        } label: {
            Text(app.name(selection))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle, .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Translating…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
        case .done(let r):
            let rtl = LanguageRules.isRightToLeft(r.target)
            let text = Text(r.text)
                .font(.system(size: 16))
                .textSelection(.enabled)
                .multilineTextAlignment(rtl ? .trailing : .leading)
                .frame(maxWidth: .infinity, alignment: rtl ? .trailing : .leading)
                .fixedSize(horizontal: false, vertical: true)
            if r.text.count > 900 {
                ScrollView { text }.frame(height: 320)
            } else {
                text
            }
        case .notInstalled(let missing):
            VStack(alignment: .leading, spacing: 8) {
                let names = missing.map(app.name).joined(separator: " and ")
                Text("\(names) \(missing.count == 1 ? "isn't" : "aren't") downloaded yet.")
                if missing.contains(where: { app.downloads[$0] != nil }) {
                    let p = missing.compactMap { app.downloads[$0] }
                    let done = p.reduce(0) { $0 + $1.done }, total = p.reduce(0) { $0 + $1.total }
                    ProgressView(value: total > 0 ? Double(done) / Double(total) : 0) {
                        Text("Downloading \(names)… \(LanguageRules.formatBytes(done)) of \(LanguageRules.formatBytes(total))")
                            .font(.caption)
                    }
                } else {
                    let size = missing.compactMap { app.language($0)?.downloadSize }.reduce(0, +)
                    Button("Download \(names)\(size > 0 ? " · " + LanguageRules.formatBytes(size) : "")") {
                        model.downloadMissing(missing)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if model.resultText != nil {
                Button(model.copied ? "Copied" : "Copy") { model.copy() }
                    .keyboardShortcut("c", modifiers: .command)
                Button("Replace") { model.onReplace?(model.resultText ?? "") }
                    .help("Paste the translation over the selected text")
            }
            Spacer()
            if case .done(let r) = model.phase {
                if r.pivoted { Text("via English").foregroundStyle(.tertiary) }
                Text("Offline · \(r.ms) ms").foregroundStyle(.tertiary)
            }
        }
        .controlSize(.small)
        .font(.caption)
    }
}

struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .popover
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

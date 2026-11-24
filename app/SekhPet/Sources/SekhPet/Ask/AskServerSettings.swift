import AppKit

/// The OpenAI-compatible server for Quick Ask: its address, API key and model. The model list
/// is read from the server while the dialog is open; Automatic uses whichever model is loaded.
@MainActor
final class AskServerSettings {
    static func show() { AskServerSettings().run() }

    private static let automatic = "Automatic"

    private let url = NSTextField(string: AskSettings.serverURL)
    private let key = NSSecureTextField(string: AskKeychain.apiKey ?? "")
    private let model = NSComboBox()
    private let status = NSTextField(labelWithString: "")
    private var lookup: Task<Void, Never>?

    /// For `--ask-preview`: the dialog drawn without running it.
    static func previewWindow() -> NSWindow {
        let dialog = AskServerSettings()
        let alert = dialog.makeAlert()
        alert.layout()
        dialog.status.stringValue = "3 models, none loaded"
        return alert.window
    }

    private func makeAlert() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Quick Ask Server"
        alert.informativeText = "Any server with the OpenAI chat API: llama.cpp, LM Studio, Ollama, vLLM, MLX and others. "
            + "Automatic answers with the model the server has loaded and never loads another."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        url.placeholderString = "http://192.168.1.20:8080"
        key.placeholderString = "Optional"
        model.completes = true
        model.placeholderString = Self.automatic
        model.stringValue = AskSettings.serverModel
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Address:"), url],
            [NSTextField(labelWithString: "API key:"), key],
            [NSTextField(labelWithString: "Model:"), model],
            [NSGridCell.emptyContentView, status],
        ])
        grid.rowSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).width = 300
        grid.frame = NSRect(x: 0, y: 0, width: 390, height: 112)
        alert.accessoryView = grid
        alert.window.initialFirstResponder = url
        return alert
    }

    private func run() {
        let alert = makeAlert()
        // Read the model list again whenever the address or key changes.
        let observers = [url, key].map { field in
            NotificationCenter.default.addObserver(forName: NSControl.textDidEndEditingNotification, object: field,
                                                   queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        refresh()

        NSApp.activate()
        let response = alert.runModal()
        lookup?.cancel()
        observers.forEach(NotificationCenter.default.removeObserver)
        guard response == .alertFirstButtonReturn else { return }
        AskSettings.serverURL = url.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        AskKeychain.apiKey = key.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let chosen = model.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        AskSettings.serverModel = chosen == Self.automatic ? "" : chosen
    }

    private func refresh() {
        lookup?.cancel()
        guard let base = OpenAIBackend.normalized(url.stringValue) else {
            status.stringValue = ""
            return
        }
        status.stringValue = "Reading the server's models…"
        let server = OpenAIBackend(baseURL: base, apiKey: key.stringValue, model: "")
        lookup = Task { [weak self] in
            do {
                let models = try await server.models()
                guard let self, !Task.isCancelled else { return }
                model.removeAllItems()
                model.addItem(withObjectValue: Self.automatic)
                model.addItems(withObjectValues: models.map(\.id))
                let loaded = models.filter { $0.loaded == true }.map(\.id)
                let reportsLoading = models.contains { $0.loaded != nil }
                status.stringValue = "\(models.count) model\(models.count == 1 ? "" : "s")"
                    + (loaded.isEmpty ? (reportsLoading ? ", none loaded" : "") : ", loaded: \(loaded.joined(separator: ", "))")
            } catch {
                guard let self, !Task.isCancelled else { return }
                status.stringValue = "Couldn't reach it: \(error.localizedDescription)"
            }
        }
    }
}

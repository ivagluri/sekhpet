import AppKit
import os

/// Headless checks for Quick Ask, like `--snapshot` for pets.
///   `SekhPet --ask "question"` streams an answer from the current backend to stdout
///   (or from SEKHPET_ASK_SERVER, with SEKHPET_ASK_KEY / _MODEL / _MAX_TOKENS).
///   `SekhPet --ask-preview <dir>` renders the pips and the bubble's states to PNGs.
@MainActor
enum AskPreview {
    static func ask(arguments: [String]) -> Int32 {
        guard let question = arguments.first else {
            print("usage: SekhPet --ask \"question\"")
            return 2
        }
        // SEKHPET_ASK_SERVER (and _KEY, _MODEL) test a server without touching settings or the keychain.
        let env = ProcessInfo.processInfo.environment
        let backend: AskBackend = env["SEKHPET_ASK_SERVER"].flatMap(OpenAIBackend.normalized).map {
            OpenAIBackend(baseURL: $0, apiKey: env["SEKHPET_ASK_KEY"], model: env["SEKHPET_ASK_MODEL"] ?? "")
        } ?? AskSettings.backend()
        let status = OSAllocatedUnfairLock(initialState: Int32(0))
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                for try await text in backend.answer(question, history: []) {
                    FileHandle.standardOutput.write(Data(text.utf8))
                }
                print()
            } catch {
                FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
                status.withLock { $0 = 1 }
            }
            done.signal()
        }
        while done.wait(timeout: .now()) == .timedOut {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return status.withLock { $0 }
    }

    static func preview(arguments: [String]) -> Int32 {
        guard let path = arguments.first else {
            print("usage: SekhPet --ask-preview <dir>")
            return 2
        }
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = NSApplication.shared
        NSApp.appearance = NSAppearance(named: .darkAqua)

        let pips = PipBarView(frame: NSRect(x: 0, y: 0, width: 40, height: PipBarView.height))
        pips.setFrameSize(NSSize(width: pips.preferredWidth, height: PipBarView.height))
        save(pips, dir, "pips-collapsed")
        pips.canReopen = true
        pips.setFrameSize(NSSize(width: pips.preferredWidth, height: PipBarView.height))
        save(pips, dir, "pips-reopen")
        pips.setFieldOpen(true)
        pips.field.alphaValue = 1
        pips.field.stringValue = "what's the tallest mountain in the solar system?"
        pips.setFrameSize(NSSize(width: pips.preferredWidth, height: PipBarView.height))
        save(pips, dir, "pips-field")

        let answer = """
            **Olympus Mons** on Mars, about 21.9 km high: roughly two and a half times Everest. \
            It's a shield volcano wide enough to cover most of France.

            - Base: ~600 km across
            - Use `units` to convert:

            ```
            units '21.9 km' 'ft'
            ```
            """
        let cases: [(String, [AskTurn], AnswerBubbleView.Status, String?, Bool)] = [
            ("bubble-thinking", [AskTurn(question: "what's the tallest mountain in the solar system?", answer: "")], .thinking, nil, false),
            ("bubble-streaming", [AskTurn(question: "what's the tallest mountain in the solar system?", answer: "**Olympus Mons** on Mars, about")], .thinking, nil, false),
            ("bubble-done", [AskTurn(question: "what's the tallest mountain in the solar system?", answer: answer)], .done, nil, false),
            ("bubble-failed", [AskTurn(question: "hello?", answer: "")], .failed, "Couldn't find the claude command.", false),
            ("bubble-expanded", [AskTurn(question: "what's the tallest mountain in the solar system?", answer: answer),
                                 AskTurn(question: "and on Earth, from base to peak?", answer: "Mauna Kea: about **10.2 km** from its base on the sea floor, though only 4.2 km is above water.")],
             .done, nil, true),
        ]
        for (name, turns, status, error, expanded) in cases {
            let bubble = AnswerBubbleView(frame: NSRect(x: 0, y: 0, width: AnswerBubbleView.compactWidth, height: 80))
            bubble.render(turns: turns, status: status, error: error, expanded: expanded)
            bubble.setFrameSize(bubble.fittingSize())
            save(bubble, dir, name)
        }
        let window = AskServerSettings.previewWindow()
        window.appearance = NSAppearance(named: .aqua)
        window.contentView?.layoutSubtreeIfNeeded()
        if let view = window.contentView,
           let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("server-settings.png"))
        }
        print("wrote previews to \(dir.path)")
        return 0
    }

    /// Draws `view` in an offscreen window (so layers and controls render) to `<name>.png` at 2x.
    private static func save(_ view: NSView, _ dir: URL, _ name: String) {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: view.frame.size), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.backgroundColor = NSColor(white: 0.55, alpha: 1)  // a mid-grey desktop behind the glass
        let holder = NSView(frame: NSRect(origin: .zero, size: view.frame.size))
        window.contentView = holder
        holder.addSubview(view)
        view.frame.origin = .zero
        view.layoutSubtreeIfNeeded()
        view.layout()
        view.displayIfNeeded()
        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width * scale),
                                         pixelsHigh: Int(view.bounds.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return }
        rep.size = view.bounds.size
        holder.cacheDisplay(in: holder.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
        view.removeFromSuperview()
    }
}

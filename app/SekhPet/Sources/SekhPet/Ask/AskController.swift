import AppKit

/// Quick Ask settings, shared by every pet.
enum AskSettings {
    private static let modelKey = "ask.claudeModel"
    private static let enabledKey = "ask.enabled"

    static let models: [(alias: String?, title: String)] = [(nil, "Default"), ("haiku", "Haiku"), ("sonnet", "Sonnet"), ("opus", "Opus")]

    /// The `claude -p` model alias; nil uses Claude Code's default.
    static var claudeModel: String? {
        get { UserDefaults.standard.string(forKey: modelKey) }
        set { UserDefaults.standard.set(newValue, forKey: modelKey) }
    }

    /// The whole feature: pips on hover and Ask… in the menus. On unless turned off.
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    enum Source: String { case claude, server }
    private static let sourceKey = "ask.backend"
    private static let serverURLKey = "ask.serverURL"
    private static let serverModelKey = "ask.serverModel"

    /// Who answers: Claude Code (the default) or an OpenAI-compatible server.
    static var source: Source {
        get { Source(rawValue: UserDefaults.standard.string(forKey: sourceKey) ?? "") ?? .claude }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: sourceKey) }
    }

    /// The server's address as typed, e.g. `http://192.168.1.20:8080`; empty until set.
    static var serverURL: String {
        get { UserDefaults.standard.string(forKey: serverURLKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: serverURLKey) }
    }

    /// The server model to ask; empty picks the loaded one.
    static var serverModel: String {
        get { UserDefaults.standard.string(forKey: serverModelKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: serverModelKey) }
    }

    static func server() -> OpenAIBackend? {
        OpenAIBackend.normalized(serverURL).map { OpenAIBackend(baseURL: $0, apiKey: AskKeychain.apiKey, model: serverModel) }
    }

    static func backend() -> AskBackend {
        switch source {
        case .claude: return ClaudeCLIBackend(model: claudeModel)
        case .server: return server() ?? MissingServer()
        }
    }
}

/// Answers with a pointer to the settings when no server address is set.
private struct MissingServer: AskBackend {
    var name: String { "Server" }
    func answer(_ question: String, history: [AskTurn]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish(throwing: AskError.failed("No server address yet: set one in Quick Ask → Server Settings…")) }
    }
}

/// One pet's Quick Ask: pips under its feet on hover, a question field that slides out of
/// them, and an answer bubble over its head that fades on its own. The thread lives only in
/// memory: a new question from the pips starts fresh, and closing the bubble forgets it.
@MainActor
final class AskController {
    /// Where the pet is: its window, the point between its feet and the top of its head.
    struct Anchor {
        var feet: NSPoint
        var headTop: CGFloat
        var window: NSWindow
    }

    /// Supplied by the pet; nil while the pet can't show Ask (housed, dragged, hidden).
    var anchor: (() -> Anchor?)?
    /// The pet finished answering.
    var onAnswered: (() -> Void)?

    private let pipPanel = AskPanel()
    private let pips = PipBarView(frame: NSRect(x: 0, y: 0, width: 40, height: PipBarView.height))
    private let bubblePanel = AskPanel()
    private let bubble = AnswerBubbleView(frame: NSRect(x: 0, y: 0, width: AnswerBubbleView.compactWidth, height: 80))

    private var petHovered = false
    private var pipsHovered = false
    private var bubbleHovered = false
    private var graceUntil: TimeInterval = 0
    private var graceTimer: Timer?

    private var turns: [AskTurn] = []
    private var status = AnswerBubbleView.Status.done
    private var errorText: String?
    private var expanded = false
    private var bubbleShown = false
    private var task: Task<Void, Never>?
    private var fadeTimer: Timer?
    private var lastLayout: (pips: NSRect, bubble: NSRect)?
    /// How far the bubble was dragged from its place over the pet's head.
    private var bubbleOffset = NSPoint.zero

    /// The pet should think while a question is out.
    var isThinking: Bool { status == .thinking }
    /// The pet should stay put while you're typing to it or reading its answer.
    var holdsPet: Bool { pips.fieldOpen || isThinking || bubbleShown }

    init() {
        pipPanel.contentView = pips
        pipPanel.hasShadow = false
        bubblePanel.contentView = bubble

        pips.onHover = { [unowned self] in pipsHovered = $0; hoverChanged() }
        pips.onAsk = { [unowned self] in pips.fieldOpen ? closeField() : openField() }
        pips.onReopen = { [unowned self] in reopen() }
        pips.field.onSubmit = { [unowned self] in ask($0, followUp: false) }
        pips.field.onCancel = { [unowned self] in closeField() }
        pipPanel.onCancel = { [unowned self] in closeField() }
        pipPanel.onResignKey = { [unowned self] in
            // Clicking elsewhere puts an empty field away; a half-typed question stays.
            if pips.fieldOpen, pips.field.stringValue.isEmpty { closeField() }
        }

        bubble.onHover = { [unowned self] in bubbleHovered = $0; scheduleFade() }
        bubble.onClose = { [unowned self] in dismiss() }
        bubble.onCopy = { [unowned self] in copyAnswer() }
        bubble.onExpand = { [unowned self] in setExpanded(!expanded) }
        bubble.onDrag = { [unowned self] dx, dy in
            bubbleOffset.x += dx
            bubbleOffset.y += dy
            follow()
        }
        bubble.input.onSubmit = { [unowned self] in ask($0, followUp: true) }
        bubble.input.onCancel = { [unowned self] in setExpanded(false) }
        bubblePanel.onCancel = { [unowned self] in expanded ? setExpanded(false) : dismiss() }
    }

    func close() {
        task?.cancel()
        fadeTimer?.invalidate()
        graceTimer?.invalidate()
        pipPanel.close()
        bubblePanel.close()
    }

    /// Quick Ask was turned off: stop any question, put everything away and forget the thread.
    func shutDown() {
        closeField()
        dismiss()
        hideBubble(instantly: true)
        pipPanel.hideNow()
    }

    // MARK: Hover

    /// The pointer is over the pet's pixels, or has left them.
    func petHover(_ hovered: Bool) {
        guard hovered != petHovered else { return }
        petHovered = hovered
        hoverChanged()
    }

    private func hoverChanged() {
        if !petHovered && !pipsHovered {
            // A moment's grace to cross the gap between the pet and its pips.
            graceUntil = CACurrentMediaTime() + 1.2
            graceTimer?.invalidate()
            graceTimer = Timer.scheduledTimer(withTimeInterval: 1.25, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.updatePips() }
            }
        }
        updatePips()
    }

    private func updatePips() {
        let wanted = AskSettings.enabled && anchor?() != nil
            && (pips.fieldOpen || petHovered || pipsHovered || CACurrentMediaTime() < graceUntil)
        pips.canReopen = !turns.isEmpty && !bubbleShown
        if wanted {
            follow()
            pipPanel.fade(visible: true, duration: 0.12)
        } else {
            pipPanel.fade(visible: false, duration: 0.25)
        }
    }

    // MARK: Following the pet

    /// Keeps the pips under the pet's feet and the bubble over its head. Called every frame;
    /// it only moves windows when something changed.
    func tick() {
        if pipPanel.shown || bubbleShown { follow() }
    }

    private func follow() {
        guard let anchor = anchor?() else {
            // Being dragged, housed or hidden: put everything away at once. The bubble only steps
            // aside: it comes back when the pet does, question and all.
            if pips.fieldOpen { closeField() }
            pipPanel.hideNow()
            bubblePanel.hideNow()
            return
        }
        let screen = anchor.window.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let full = screen.frame, visible = screen.visibleFrame

        let pipSize = NSSize(width: pips.preferredWidth, height: PipBarView.height)
        var pipFrame = NSRect(x: anchor.feet.x - PipBarView.pip / 2 - 4, y: anchor.feet.y - pipSize.height - 4,
                              width: pipSize.width, height: pipSize.height)
        // Centre the pips under the feet; an open field grows to the right, unless that's off screen.
        if !pips.fieldOpen { pipFrame.origin.x = anchor.feet.x - pipSize.width / 2 }
        pipFrame.origin.x = min(max(pipFrame.minX, visible.minX + 4), visible.maxX - pipFrame.width - 4)
        pipFrame.origin.y = max(pipFrame.minY, full.minY + 2)

        let size = bubble.frame.size
        var bubbleFrame = NSRect(x: anchor.feet.x - size.width / 2, y: anchor.headTop + 10, width: size.width, height: size.height)
        // Over the head if it fits, else under the pips, else wherever it fits on screen.
        if bubbleFrame.maxY > visible.maxY - 4 {
            bubbleFrame.origin.y = pipFrame.minY - 8 - size.height
            if bubbleFrame.minY < visible.minY + 4 { bubbleFrame.origin.y = visible.maxY - 4 - size.height }
        }
        // Wherever it was dragged to, relative to the pet.
        bubbleFrame.origin.x += bubbleOffset.x
        bubbleFrame.origin.y += bubbleOffset.y
        bubbleFrame.origin.x = min(max(bubbleFrame.minX, visible.minX + 8), visible.maxX - size.width - 8)
        bubbleFrame.origin.y = min(max(bubbleFrame.minY, visible.minY + 4), visible.maxY - size.height - 4)

        if let last = lastLayout?.pips, last != pipFrame {
            // The field slides out of the pips (and back) rather than jumping.
            if last.width != pipFrame.width, pipPanel.isVisible {
                NSAnimationContext.runAnimationGroup { $0.duration = 0.18; pipPanel.animator().setFrame(pipFrame, display: true) }
            } else {
                pipPanel.setFrame(pipFrame, display: true)
            }
        } else if lastLayout == nil {
            pipPanel.setFrame(pipFrame, display: true)
        }
        if lastLayout?.bubble != bubbleFrame { bubblePanel.setFrame(bubbleFrame, display: true) }
        lastLayout = (pipFrame, bubbleFrame)
        // Back from a drag (or a pause): the bubble returns.
        if bubbleShown, !bubblePanel.shown {
            bubblePanel.fade(visible: true)
            if expanded {
                bubblePanel.makeKey()
                bubblePanel.makeFirstResponder(bubble.input)
            }
        }
        for panel in [pipPanel, bubblePanel] where panel.isVisible && panel.level != anchor.window.level {
            panel.level = anchor.window.level
        }
    }

    // MARK: Asking

    /// For `--ask-demo`: shows the pips with the question typed, asks it, and optionally
    /// expands the bubble and asks a follow-up once the answer is in.
    func demo(_ question: String, expand: Bool) {
        petHover(true)
        openField()
        pips.field.stringValue = question
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            petHover(false)
            ask(question, followUp: false)
            guard expand else { return }
            Task { @MainActor [weak self] in
                while self?.isThinking == true { try? await Task.sleep(for: .milliseconds(200)) }
                guard let self else { return }
                setExpanded(true)
                try? await Task.sleep(for: .seconds(2))
                ask("And in one short sentence, why?", followUp: true)
            }
        }
    }

    /// Opens the question field, e.g. from the pet's menu.
    func openField() {
        guard AskSettings.enabled else { return }
        pips.setFieldOpen(true)
        follow()
        pipPanel.makeKey()
        pipPanel.makeFirstResponder(pips.field)
        updatePips()
    }

    private func closeField() {
        guard pips.fieldOpen else { return }
        pips.setFieldOpen(false)
        if pipPanel.isKeyWindow { pipPanel.resignKey() }
        follow()
        updatePips()
    }

    /// Asks `question`: from the pips, a fresh thread; from the expanded bubble, a follow-up.
    func ask(_ question: String, followUp: Bool) {
        task?.cancel()
        if !followUp {
            closeField()
            turns = []
            expanded = false
            bubbleOffset = .zero
        } else {
            bubble.input.stringValue = ""
        }
        let history = turns
        turns.append(AskTurn(question: question, answer: ""))
        status = .thinking
        errorText = nil
        showBubble()

        let backend = AskSettings.backend()
        task = Task { [weak self] in
            do {
                for try await text in backend.answer(question, history: history) {
                    guard let self, !Task.isCancelled else { return }
                    self.turns[self.turns.count - 1].answer += text
                    self.refreshBubble()
                }
                guard let self, !Task.isCancelled else { return }
                self.finish(error: nil)
            } catch is CancellationError {
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.finish(error: error.localizedDescription)
            }
        }
    }

    private func finish(error: String?) {
        if error == nil, turns.last?.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
            errorText = "No answer came back."
            status = .failed
        } else {
            errorText = error
            status = error == nil ? .done : .failed
        }
        task = nil
        refreshBubble()
        if status == .done { onAnswered?() }
        if expanded { bubblePanel.makeFirstResponder(bubble.input) }
        scheduleFade()
    }

    // MARK: The bubble

    private func showBubble() {
        bubbleShown = true
        refreshBubble()
        follow()
        bubblePanel.fade(visible: true)
        if expanded {
            bubblePanel.makeKey()
            bubblePanel.makeFirstResponder(bubble.input)
        }
        updatePips()
        scheduleFade()
    }

    private func refreshBubble() {
        bubble.render(turns: turns, status: status, error: errorText, expanded: expanded)
        let size = bubble.fittingSize()
        if bubble.frame.size != size {
            bubble.setFrameSize(size)
            // Grow upward from the bottom edge, so a bubble over the head doesn't slide down onto it.
            follow()
        }
    }

    private func hideBubble(instantly: Bool = false) {
        bubbleShown = false
        fadeTimer?.invalidate()
        if instantly { bubblePanel.hideNow() } else { bubblePanel.fade(visible: false, duration: 0.4) }
        updatePips()
    }

    /// Closes the bubble early and forgets the thread.
    private func dismiss() {
        task?.cancel()
        task = nil
        status = .done
        turns = []
        expanded = false
        hideBubble()
    }

    /// The last answer again, from the pips.
    private func reopen() {
        guard !turns.isEmpty else { return }
        showBubble()
    }

    private func setExpanded(_ on: Bool) {
        expanded = on
        refreshBubble()
        if on {
            bubblePanel.makeKey()
            bubblePanel.makeFirstResponder(bubble.input)
        } else if bubblePanel.isKeyWindow {
            bubblePanel.resignKey()
        }
        scheduleFade()
    }

    private func copyAnswer() {
        guard let answer = turns.last?.answer, !answer.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(answer, forType: .string)
    }

    /// Fades the bubble after time to read it: longer for longer answers, never while the
    /// pointer is on it, it's expanded or an answer is still coming.
    private func scheduleFade() {
        fadeTimer?.invalidate()
        fadeTimer = nil
        guard bubbleShown, !expanded, !bubbleHovered, status != .thinking else { return }
        let words = turns.last?.answer.split(whereSeparator: \.isWhitespace).count ?? 0
        let seconds = min(6 + Double(words) / 3.5, 60) + (status == .failed ? 4 : 0)
        fadeTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.hideBubble() }
        }
    }
}

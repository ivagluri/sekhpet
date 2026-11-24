import AppKit

/// A borderless floating panel that can take typing without activating SekhPet, like Spotlight.
final class AskPanel: NSPanel {
    var onResignKey: (() -> Void)?
    var onCancel: (() -> Void)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        isFloatingPanel = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovable = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        alphaValue = 0
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }

    override func cancelOperation(_ sender: Any?) { onCancel?() }

    /// Whether the panel is showing or fading in (false once it starts fading out).
    private(set) var shown = false

    /// Fades in or out; hidden panels are ordered out so they take no clicks. Asking again
    /// for the state it's already heading to does nothing, so a fade always finishes.
    func fade(visible: Bool, duration: TimeInterval = 0.15) {
        guard visible != shown else { return }
        shown = visible
        if visible {
            if !isVisible {
                alphaValue = 0
                orderFrontRegardless()
            }
            NSAnimationContext.runAnimationGroup { $0.duration = duration; animator().alphaValue = 1 }
        } else {
            NSAnimationContext.runAnimationGroup({ $0.duration = duration; animator().alphaValue = 0 }) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !self.shown else { return }
                    self.orderOut(nil)
                }
            }
        }
    }

    /// Gone at once, without a fade (the pet was picked up).
    func hideNow() {
        shown = false
        alphaValue = 0
        orderOut(nil)
    }
}

/// Shared look: dark translucent glass like a HUD, light text.
@MainActor
enum AskStyle {
    static let background = NSColor(white: 0.13, alpha: 0.92)
    static let rim = NSColor(white: 1, alpha: 0.14)
    static let text = NSColor(white: 0.96, alpha: 1)
    static let secondary = NSColor(white: 0.72, alpha: 1)
    static let codeBackground = NSColor(white: 1, alpha: 0.08)
    static let bodyFont = NSFont.systemFont(ofSize: 13)
    static let titleFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    static let codeFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    static func symbol(_ name: String, size: CGFloat = 13, weight: NSFont.Weight = .medium) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: weight))
    }

    static func iconButton(_ symbol: String, _ tip: String, size: CGFloat = 13, weight: NSFont.Weight = .medium,
                           target: AnyObject, action: Selector) -> HoverButton {
        let button = HoverButton(image: Self.symbol(symbol, size: size, weight: weight) ?? NSImage(), target: target, action: action)
        button.isBordered = false
        button.contentTintColor = secondary
        button.toolTip = tip
        button.setAccessibilityLabel(tip)
        return button
    }

    /// A rounded dark layer with a thin light rim.
    static func applyGlass(to view: NSView, radius: CGFloat) {
        view.wantsLayer = true
        view.layer?.backgroundColor = background.cgColor
        view.layer?.cornerRadius = radius
        view.layer?.cornerCurve = .continuous
        view.layer?.borderWidth = 1
        view.layer?.borderColor = rim.cgColor
        view.layer?.masksToBounds = true
    }
}

/// Brightens on hover.
final class HoverButton: NSButton {
    var normalTint = AskStyle.secondary
    var hoverTint = AskStyle.text

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { contentTintColor = hoverTint }
    override func mouseExited(with event: NSEvent) { contentTintColor = normalTint }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// Reports the mouse entering and leaving, and the text field's Return.
class TrackingView: NSView {
    var onHover: ((Bool) -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}

/// A single-line field for questions: Return sends, Esc cancels.
final class AskField: NSTextField, NSTextFieldDelegate {
    var onSubmit: ((String) -> Void)?
    var onCancel: (() -> Void)?

    init(placeholder: String) {
        super.init(frame: .zero)
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        font = AskStyle.bodyFont
        textColor = AskStyle.text
        usesSingleLineMode = true
        cell?.wraps = false
        cell?.isScrollable = true
        placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .foregroundColor: AskStyle.secondary, .font: AskStyle.bodyFont,
        ])
        delegate = self
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            let text = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { onSubmit?(text) }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onCancel?()
            return true
        default:
            return false
        }
    }
}

// MARK: - Pips

/// The row of pips under a pet. The ask pip slides a question field out of the row.
@MainActor
final class PipBarView: TrackingView {
    static let height: CGFloat = 30
    static let pip: CGFloat = 28
    static let fieldWidth: CGFloat = 260

    let field = AskField(placeholder: "Ask anything…")
    private var askButton: HoverButton!
    private var reopenButton: HoverButton!
    var onAsk: (() -> Void)?
    var onReopen: (() -> Void)?

    private(set) var fieldOpen = false
    var canReopen = false {
        didSet { if canReopen != oldValue { needsLayout = true } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        AskStyle.applyGlass(to: self, radius: Self.height / 2)
        askButton = AskStyle.iconButton("bubble.left.fill", "Ask a question", size: 13, target: self, action: #selector(askClicked))
        reopenButton = AskStyle.iconButton("text.bubble", "Show the last answer", size: 13, target: self, action: #selector(reopenClicked))
        field.isHidden = true
        field.alphaValue = 0
        let views: [NSView] = [askButton, reopenButton, field]
        views.forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func askClicked() { onAsk?() }
    @objc private func reopenClicked() { onReopen?() }

    /// The bar's width for the current state.
    var preferredWidth: CGFloat {
        if fieldOpen { return Self.pip + Self.fieldWidth + 10 }
        return Self.pip * (canReopen ? 2 : 1) + 8
    }

    func setFieldOpen(_ open: Bool) {
        fieldOpen = open
        field.isHidden = false
        if !open { field.stringValue = "" }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.18; field.animator().alphaValue = open ? 1 : 0 }) { [weak self] in
            MainActor.assumeIsolated { if let self, !self.fieldOpen { self.field.isHidden = true } }
        }
        askButton.normalTint = open ? NSColor.controlAccentColor : AskStyle.secondary
        askButton.contentTintColor = open ? NSColor.controlAccentColor : AskStyle.secondary
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let y = (bounds.height - Self.pip) / 2
        askButton.frame = NSRect(x: 4, y: y, width: Self.pip, height: Self.pip)
        reopenButton.isHidden = fieldOpen || !canReopen
        reopenButton.frame = NSRect(x: 4 + Self.pip, y: y, width: Self.pip, height: Self.pip)
        let fieldHeight: CGFloat = 18
        field.frame = NSRect(x: 4 + Self.pip + 2, y: (bounds.height - fieldHeight) / 2,
                             width: max(0, bounds.width - Self.pip - 14), height: fieldHeight)
    }
}

// MARK: - Answer bubble

/// The answer: a status icon and the question as a title, the streamed answer below, and
/// expand, copy and close buttons. Expanded, it shows the whole thread and takes follow-ups.
@MainActor
final class AnswerBubbleView: TrackingView {
    enum Status { case thinking, done, failed }

    static let compactWidth: CGFloat = 340
    static let expandedWidth: CGFloat = 460
    static let compactMaxBody: CGFloat = 220
    static let expandedMaxBody: CGFloat = 380
    private static let padding: CGFloat = 12
    private static let header: CGFloat = 20
    private static let inputHeight: CGFloat = 32

    private let statusIcon = NSImageView()
    private let spinner = NSProgressIndicator()
    private let title = NSTextField(labelWithString: "")
    private var expandButton: HoverButton!
    private var copyButton: HoverButton!
    private var closeButton: HoverButton!
    private let scroll = NSScrollView()
    private let body = NSTextView()
    private let inputBox = NSView()
    let input = AskField(placeholder: "Follow-up question…")

    var onExpand: (() -> Void)?
    var onCopy: (() -> Void)?
    var onClose: (() -> Void)?
    /// The bubble's header or edge was dragged by (dx, dy) screen points.
    var onDrag: ((CGFloat, CGFloat) -> Void)?
    private var dragFrom: NSPoint?

    private(set) var expanded = false

    // Dragging by the header or the edges moves the bubble; the text and buttons keep their clicks.
    override func mouseDown(with event: NSEvent) { dragFrom = NSEvent.mouseLocation }
    override func mouseDragged(with event: NSEvent) {
        guard let from = dragFrom else { return }
        let now = NSEvent.mouseLocation
        dragFrom = now
        onDrag?(now.x - from.x, now.y - from.y)
    }
    override func mouseUp(with event: NSEvent) { dragFrom = nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        AskStyle.applyGlass(to: self, radius: 14)
        title.font = AskStyle.titleFont
        title.textColor = AskStyle.text
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.appearance = NSAppearance(named: .darkAqua)
        spinner.isDisplayedWhenStopped = false
        expandButton = AskStyle.iconButton("arrow.up.left.and.arrow.down.right", "Expand for follow-ups", size: 11,
                                           target: self, action: #selector(expandClicked))
        copyButton = AskStyle.iconButton("doc.on.doc", "Copy the answer", size: 11, target: self, action: #selector(copyClicked))
        closeButton = AskStyle.iconButton("xmark", "Close", size: 11, weight: .semibold, target: self, action: #selector(closeClicked))

        body.isEditable = false
        body.isSelectable = true
        body.drawsBackground = false
        body.textContainerInset = .zero
        body.textContainer?.lineFragmentPadding = 0
        body.isVerticallyResizable = true
        body.isHorizontallyResizable = false
        body.textContainer?.widthTracksTextView = true
        body.linkTextAttributes = [.foregroundColor: NSColor.systemBlue.blended(withFraction: 0.3, of: .white) ?? .systemBlue,
                                   .underlineStyle: NSUnderlineStyle.single.rawValue]
        scroll.documentView = body
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.appearance = NSAppearance(named: .darkAqua)

        inputBox.wantsLayer = true
        inputBox.layer?.backgroundColor = NSColor(white: 1, alpha: 0.07).cgColor
        inputBox.layer?.cornerRadius = 8
        inputBox.addSubview(input)
        inputBox.isHidden = true

        let views: [NSView] = [statusIcon, spinner, title, expandButton, copyButton, closeButton, scroll, inputBox]
        views.forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError("not used") }


    @objc private func expandClicked() { onExpand?() }
    @objc private func copyClicked() { onCopy?() }
    @objc private func closeClicked() { onClose?() }

    /// Fills the bubble. Compact: the latest question as the title and its answer. Expanded:
    /// every turn, each question above its answer, and the follow-up field.
    func render(turns: [AskTurn], status: Status, error: String?, expanded: Bool) {
        self.expanded = expanded
        switch status {
        case .thinking:
            statusIcon.isHidden = true
            spinner.startAnimation(nil)
        case .done, .failed:
            spinner.stopAnimation(nil)
            statusIcon.isHidden = false
            let ok = status == .done
            statusIcon.image = AskStyle.symbol(ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill", size: 14, weight: .semibold)
            statusIcon.contentTintColor = ok ? .systemGreen : .systemOrange
        }
        title.stringValue = expanded ? (turns.first?.question ?? "") : (turns.last?.question ?? "")
        expandButton.image = AskStyle.symbol(expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                                             size: 11)
        expandButton.toolTip = expanded ? "Back to a small bubble" : "Expand for follow-ups"
        copyButton.isEnabled = !(turns.last?.answer.isEmpty ?? true)
        inputBox.isHidden = !expanded
        input.isEnabled = status != .thinking

        let text = NSMutableAttributedString()
        let shown = expanded ? turns : Array(turns.suffix(1))
        for (index, turn) in shown.enumerated() {
            let isLast = index == shown.count - 1
            // In the thread, every question but the first (it's the title) heads its answer.
            if expanded, index > 0 {
                if text.length > 0 { text.append(NSAttributedString(string: "\n\n")) }
                text.append(NSAttributedString(string: turn.question + "\n", attributes: [
                    .font: AskStyle.titleFont, .foregroundColor: AskStyle.text,
                    .paragraphStyle: AskMarkdown.paragraph(spacingAfter: 4),
                ]))
            }
            if isLast, turn.answer.isEmpty {
                let note = status == .failed ? (error ?? "Something went wrong.") : "Thinking…"
                text.append(NSAttributedString(string: note, attributes: [.font: AskStyle.bodyFont, .foregroundColor: AskStyle.secondary]))
            } else {
                text.append(AskMarkdown.attributed(turn.answer))
                if isLast, status == .failed, let error {
                    text.append(NSAttributedString(string: "\n\n" + error, attributes: [
                        .font: AskStyle.bodyFont, .foregroundColor: NSColor.systemOrange,
                    ]))
                }
            }
        }
        let following = expanded && isNearBottom
        body.textStorage?.setAttributedString(text)
        needsLayout = true
        if following { body.scrollToEndOfDocument(nil) }
    }

    private var isNearBottom: Bool {
        let visible = scroll.contentView.bounds
        return visible.maxY >= body.frame.height - 24
    }

    /// The size that fits the current text, up to the body's limit.
    func fittingSize(maxBody: CGFloat? = nil) -> NSSize {
        let width = expanded ? Self.expandedWidth : Self.compactWidth
        let limit = maxBody ?? (expanded ? Self.expandedMaxBody : Self.compactMaxBody)
        let height = min(bodyHeight(width: width - Self.padding * 2), limit)
        var total = Self.padding + Self.header + 8 + height + Self.padding
        if expanded { total += 10 + Self.inputHeight }
        return NSSize(width: width, height: ceil(total))
    }

    private func bodyHeight(width: CGFloat) -> CGFloat {
        guard let text = body.textStorage, text.length > 0 else { return 0 }
        let rect = text.boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                     options: [.usesLineFragmentOrigin, .usesFontLeading])
        return ceil(rect.height) + 2
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let p = Self.padding
        let w = bounds.width
        statusIcon.frame = NSRect(x: p, y: p + 1, width: 16, height: 16)
        spinner.frame = statusIcon.frame
        let button: CGFloat = 20
        closeButton.frame = NSRect(x: w - p - button + 4, y: p, width: button, height: button)
        copyButton.frame = closeButton.frame.offsetBy(dx: -button - 2, dy: 0)
        expandButton.frame = copyButton.frame.offsetBy(dx: -button - 2, dy: 0)
        title.frame = NSRect(x: p + 22, y: p + 1, width: max(0, expandButton.frame.minX - p - 26), height: 18)

        var bottom = bounds.height - p
        if expanded {
            inputBox.frame = NSRect(x: p, y: bottom - Self.inputHeight, width: w - p * 2, height: Self.inputHeight)
            input.frame = NSRect(x: 10, y: (Self.inputHeight - 18) / 2, width: inputBox.bounds.width - 20, height: 18)
            bottom = inputBox.frame.minY - 10
        }
        let top = p + Self.header + 8
        scroll.frame = NSRect(x: p, y: top, width: w - p * 2, height: max(0, bottom - top))
        body.frame = NSRect(x: 0, y: 0, width: scroll.contentSize.width,
                            height: max(bodyHeight(width: scroll.contentSize.width), scroll.contentSize.height))
    }
}

// MARK: - Markdown

/// Enough Markdown for short answers: inline styles via Foundation, fenced code blocks in a
/// monospaced font, headings in bold, and list markers kept as written.
@MainActor
enum AskMarkdown {
    static func paragraph(spacingAfter: CGFloat = 6) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = spacingAfter
        style.lineSpacing = 1.5
        return style
    }

    static func attributed(_ markdown: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var inCode = false
        var code: [String] = []
        var prose: [String] = []

        func flushProse() {
            guard !prose.isEmpty else { return }
            for line in prose {
                if result.length > 0 { result.append(NSAttributedString(string: "\n")) }
                result.append(inline(line))
            }
            prose = []
        }
        func flushCode() {
            if result.length > 0 { result.append(NSAttributedString(string: "\n")) }
            let style = NSMutableParagraphStyle()
            style.paragraphSpacing = 6
            style.headIndent = 6
            style.firstLineHeadIndent = 6
            result.append(NSAttributedString(string: code.joined(separator: "\n"), attributes: [
                .font: AskStyle.codeFont, .foregroundColor: AskStyle.text,
                .backgroundColor: AskStyle.codeBackground, .paragraphStyle: style,
            ]))
            code = []
        }

        for line in markdown.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if inCode { flushCode() } else { flushProse() }
                inCode.toggle()
            } else if inCode {
                code.append(line)
            } else {
                prose.append(line)
            }
        }
        if inCode { flushCode() } else { flushProse() }  // an unclosed fence while streaming
        return result
    }

    /// One line of prose: a heading in bold, otherwise inline Markdown.
    private static func inline(_ line: String) -> NSAttributedString {
        var text = line
        var font = AskStyle.bodyFont
        if let match = text.firstMatch(of: /^#{1,6}\s+/) {
            text.removeSubrange(match.range)
            font = AskStyle.titleFont
        } else if let match = text.firstMatch(of: /^(\s*)[-*+]\s+/) {
            text.replaceSubrange(match.range, with: match.output.1 + "•  ")
        }
        let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: AskStyle.text, .paragraphStyle: paragraph()]
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                              failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: text, options: options) else {
            return NSAttributedString(string: text, attributes: base)
        }
        let out = NSMutableAttributedString(string: String(parsed.characters), attributes: base)
        var location = 0
        for run in parsed.runs {
            let length = parsed[run.range].characters.count
            let range = NSRange(location: location, length: (String(parsed[run.range].characters) as NSString).length)
            location += range.length
            _ = length
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.code) {
                    out.addAttributes([.font: AskStyle.codeFont, .backgroundColor: AskStyle.codeBackground], range: range)
                } else {
                    var traits: NSFontDescriptor.SymbolicTraits = []
                    if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
                    if intent.contains(.emphasized) { traits.insert(.italic) }
                    if !traits.isEmpty {
                        let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(traits))
                        out.addAttribute(.font, value: NSFont(descriptor: descriptor, size: font.pointSize) ?? font, range: range)
                    }
                    if intent.contains(.strikethrough) {
                        out.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
                    }
                }
            }
            if let link = run.link { out.addAttribute(.link, value: link, range: range) }
        }
        return out
    }
}

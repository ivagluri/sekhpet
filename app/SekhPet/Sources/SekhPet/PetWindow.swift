import AppKit
import SceneKit
import os

/// Borderless, transparent, always-on-top panel that never takes focus.
final class PetPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        isFloatingPanel = true
        hidesOnDeactivate = false
        // We own the panel; closing it when a pet is removed must not also free it.
        isReleasedWhenClosed = false
        isMovable = false
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// AppKit keeps a window's top below the menu bar, but the window is sized for
    /// the pet's tallest clip, so that stopped the pet well short of it. The
    /// controller applies its own limit on the pet's body instead.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// The SceneKit view. Dragging the pet moves the window; clicks, double clicks
/// and drags are reported through `onInput`.
final class PetSceneView: SCNView {
    enum Input {
        case dragBegan, dragEnded, click, doubleClick
    }

    var onInput: ((Input) -> Void)?
    var onMoved: ((NSPoint) -> Void)?
    /// The pet's right-click menu.
    var contextMenu: (() -> NSMenu?)?
    /// Adjusts a dragged window origin, e.g. to stop the pet at the menu bar.
    var constrainOrigin: ((NSPoint) -> NSPoint)?
    private var dragOffset: NSPoint?
    private var downPoint: NSPoint = .zero
    private var dragging = false
    private var pendingClick: DispatchWorkItem?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func menu(for event: NSEvent) -> NSMenu? { contextMenu?() }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let mouse = NSEvent.mouseLocation
        dragOffset = NSPoint(x: mouse.x - window.frame.minX, y: mouse.y - window.frame.minY)
        downPoint = mouse
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let dragOffset else { return }
        let mouse = NSEvent.mouseLocation
        if !dragging {
            // A few points of jitter during a click shouldn't pick the pet up.
            guard hypot(mouse.x - downPoint.x, mouse.y - downPoint.y) > 4 else { return }
            dragging = true
            pendingClick?.cancel()
            onInput?(.dragBegan)
        }
        let origin = NSPoint(x: mouse.x - dragOffset.x, y: mouse.y - dragOffset.y)
        window.setFrameOrigin(constrainOrigin?(origin) ?? origin)
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragOffset = nil; dragging = false }
        if dragging {
            onInput?(.dragEnded)
            if let window { onMoved?(window.frame.origin) }
        } else if event.clickCount >= 2 {
            pendingClick?.cancel()
            pendingClick = nil
            onInput?(.doubleClick)
        } else {
            // Wait out the double-click interval so a double click never also fires a single.
            let click = DispatchWorkItem { [weak self] in self?.onInput?(.click) }
            pendingClick = click
            DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: click)
        }
    }

    var isDragging: Bool { dragOffset != nil }
}

/// Makes the window click-through everywhere except over the model's pixels.
/// SceneKit hit tests follow the skinned pose, so this tracks the animation.
@MainActor
final class ClickThroughTracker {
    private let window: NSWindow
    /// Replaced when the controller swaps in a fresh view.
    var view: PetSceneView
    private var timer: Timer?

    init(window: NSWindow, view: PetSceneView) {
        self.window = window
        self.view = view
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func update() {
        guard window.isVisible else { return }
        if view.isDragging {
            window.ignoresMouseEvents = false
            return
        }
        let mouse = NSEvent.mouseLocation
        guard window.frame.contains(mouse) else {
            window.ignoresMouseEvents = true
            return
        }
        let point = view.convert(window.convertPoint(fromScreen: mouse), from: nil)
        let hits = view.hitTest(point, options: [
            .searchMode: SCNHitTestSearchMode.any.rawValue,
            .ignoreHiddenNodes: true,
        ])
        window.ignoresMouseEvents = hits.isEmpty
    }
}

/// Records when SceneKit last drew a frame. After the Mac wakes, an SCNView's
/// own display link can come back dead: the view stops drawing while the pet's
/// behavior (and window movement) carries on, so the pet slides around frozen.
/// The controller watches this and restarts the view's rendering when it stalls.
final class RenderWatch: NSObject, SCNSceneRendererDelegate, @unchecked Sendable {
    private let last = OSAllocatedUnfairLock(initialState: CACurrentMediaTime())

    var lastFrame: TimeInterval { last.withLock { $0 } }

    func reset() { last.withLock { $0 = CACurrentMediaTime() } }

    nonisolated func renderer(_ renderer: any SCNSceneRenderer, didRenderScene scene: SCNScene, atTime time: TimeInterval) {
        last.withLock { $0 = CACurrentMediaTime() }
    }
}

/// A faint oval shadow under a dragged pet's feet, so it's easy to line the pet up with
/// anything on screen; over a surface it would snap to, it sits on that surface and
/// glows softly. Shown only while dragging.
@MainActor
final class LandingShadow {
    private let panel: NSPanel
    private let oval = CAGradientLayer()
    /// A thin light rim, so the dark shadow still shows over dark wallpaper.
    private let outline = CAShapeLayer()
    private static let height: CGFloat = 14

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        let view = NSView()
        view.wantsLayer = true
        oval.type = .radial
        oval.startPoint = CGPoint(x: 0.5, y: 0.5)
        oval.endPoint = CGPoint(x: 1, y: 1)
        view.layer?.addSublayer(oval)
        outline.fillColor = nil
        outline.strokeColor = NSColor.white.withAlphaComponent(0.55).cgColor
        outline.lineWidth = 1
        view.layer?.addSublayer(outline)
        panel.contentView = view
    }

    private var glowing: Bool?

    /// Shows the shadow centred on `point`, just behind `pet`, glowing over a snapping
    /// surface; nil hides it.
    func show(at point: NSPoint?, width: CGFloat, glowing: Bool = false, behind pet: NSWindow) {
        guard let point else {
            panel.orderOut(nil)
            return
        }
        let frame = NSRect(x: point.x - width / 2, y: point.y - Self.height / 2, width: width, height: Self.height)
        if panel.frame != frame {
            panel.setFrame(frame, display: false)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            oval.frame = CGRect(origin: .zero, size: frame.size)
            outline.frame = oval.frame
            outline.path = CGPath(ellipseIn: oval.frame.insetBy(dx: 1, dy: 1), transform: nil)
            CATransaction.commit()
        }
        if glowing != self.glowing {
            self.glowing = glowing
            let colour = glowing ? NSColor.controlAccentColor.withAlphaComponent(0.45) : NSColor.black.withAlphaComponent(0.3)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            oval.colors = [colour.cgColor, colour.withAlphaComponent(0).cgColor]
            outline.isHidden = glowing
            CATransaction.commit()
        }
        if !panel.isVisible || panel.level != pet.level {
            panel.level = pet.level
            panel.order(.below, relativeTo: pet.windowNumber)
        }
    }

    func close() { panel.close() }
}

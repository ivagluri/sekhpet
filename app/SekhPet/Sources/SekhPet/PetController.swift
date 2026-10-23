import AppKit
import SceneKit

/// One pet on the desktop: its scene, behavior, window and saved settings.
/// Created when the pet is placed on the desktop and closed when it is removed.
/// Settings are stored per pet as "<name>.<key>".
@MainActor
final class PetController {
    enum PauseReason { case user, occluded, screensAsleep }
    private enum Key {
        static let origin = "petOrigin"
        static let mode = "behaviorMode"
        static let loopClip = "loopClip"
        static let loopGroup = "loopGroup"
        static let movement = "movement"
        static let snapping = "snapToWindows"
        static let doubleClickClip = "doubleClickClip"
        static let doubleClickGroup = "doubleClickGroup"
    }

    let stage: PetStage
    let engine: BehaviorEngine
    let index: Int
    private let panel: PetPanel
    private var sceneView: PetSceneView
    private let tracker: ClickThroughTracker
    private var size: PetSize
    private var pauseReasons: Set<PauseReason> = []
    private var occlusionObserver: NSObjectProtocol?
    private let renderWatch = RenderWatch()
    private var lastRenderFix: TimeInterval = 0
    private var failedFixes = 0
    /// Called when replacing the view hasn't brought rendering back.
    var onRenderStuck: (() -> Void)?
    /// Builds the right-click menu.
    var contextMenu: (() -> NSMenu?)?

    var catalog: Catalog { stage.rig.catalog }
    var name: String { catalog.name }
    var displayName: String { catalog.displayName }

    init(assets: URL, index: Int, size: PetSize) throws {
        let catalog = try Catalog.load(from: assets)
        stage = try PetStage(assets: assets, catalog: catalog)
        stage.rig.animations.preload(catalog.playableClips)
        engine = BehaviorEngine(rig: stage.rig, clock: CACurrentMediaTime)
        self.index = index
        self.size = size

        panel = PetPanel(contentRect: .zero)
        sceneView = PetSceneView(frame: .zero)
        tracker = ClickThroughTracker(window: panel, view: sceneView)
        buildWindow()
        configure(sceneView)
        connectMotion()
        restoreBehavior()
        observeOcclusion()
        engine.tick()
        panel.orderFrontRegardless()
        // Back on the window it was standing on, if that's still there.
        snapToSurface(within: 6)
    }

    /// Takes the pet off the desktop and releases its window and timers.
    func close() {
        saveOrigin()
        tracker.stop()
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        stage.scene.isPaused = true
        sceneView.isPlaying = false
        panel.orderOut(nil)
        panel.close()
    }

    func frame(at now: TimeInterval) {
        guard !engine.isPaused else { return }
        engine.tick()
        stage.rig.motion.update(at: now)
        let moving = stage.rig.motion.isMoving && !stage.rig.motion.isPinned
        if moving != travelling {
            travelling = moving
            applyRendering(to: sceneView)
        }
        stage.rig.look.update(cursor: cursorInScene(), at: now)
        updatePerch(at: now)
        restartRenderingIfStalled(at: now)
    }

    // MARK: Standing on windows

    /// Snap to Windows: a pet dropped near a window's top edge (or the bottom of the
    /// screen) lands on it, walks only along it, rides along when it moves, and falls
    /// to the next surface below when it goes away.
    /// Per pet, saved; on unless turned off.
    private(set) var snapping = true

    /// What double-clicking plays; nil restores the pack's default.
    func setDoubleClick(_ entry: Catalog.PoolEntry?) {
        engine.doubleClickOverride = entry
        defaults.set(entry?.clip, forKey: key(Key.doubleClickClip))
        defaults.set(entry?.group, forKey: key(Key.doubleClickGroup))
    }

    func setSnapping(_ on: Bool) {
        snapping = on
        if !on { perch = nil }
        defaults.set(on, forKey: key(Key.snapping))
    }
    private var perch: CGWindowID? {
        didSet { stage.rig.motion.holdsDepth = perch != nil }
    }
    private var perchFrame = NSRect.zero
    /// The window the pet just stepped off, possibly still shrinking away: never a landing spot.
    private var leftWindow: CGWindowID?
    private var fall: (fromY: CGFloat, toY: CGFloat, started: TimeInterval)?
    private static let gravity: CGFloat = 2500  // points per second squared

    /// Height of the pet's feet above the window's bottom edge, in points.
    private var floorInWindow: CGFloat { -stage.bounds.minY * pointsPerMetre }

    private var screenUnderPet: NSScreen {
        let frame = panel.frame
        return NSScreen.screens.first { $0.frame.minX <= frame.midX && frame.midX < $0.frame.maxX }
            ?? NSScreen.main ?? NSScreen.screens[0]
    }

    /// Lands on the nearest window top or screen bottom within `gap` points of the
    /// pet's feet, under its centre. Returns whether it found one.
    @discardableResult
    private func snapToSurface(within gap: CGFloat) -> Bool {
        guard snapping else { return false }
        let frame = panel.frame
        let feet = frame.minY + floorInWindow
        var best: (top: CGFloat, window: DesktopSurfaces.Surface?)?
        for surface in DesktopSurfaces.windows()
            where surface.window != leftWindow
               && surface.frame.minX <= frame.midX && frame.midX <= surface.frame.maxX
               && abs(surface.frame.maxY - feet) <= gap && abs(surface.frame.maxY - feet) < abs((best?.top ?? .infinity) - feet) {
            best = (surface.frame.maxY, surface)
        }
        let bottom = screenUnderPet.visibleFrame.minY
        if abs(bottom - feet) <= gap, abs(bottom - feet) < abs((best?.top ?? .infinity) - feet) {
            best = (bottom, nil)
        }
        guard let best else { return false }
        perch = best.window?.window
        perchFrame = best.window?.frame ?? .zero
        if perch != nil { stage.rig.actor.setDepth(0, over: 0.3) }
        panel.setFrameOrigin(NSPoint(x: frame.minX, y: best.top - floorInWindow))
        return true
    }

    /// Follows the perch window, or falls when it's gone; animates a fall in progress.
    private func updatePerch(at now: TimeInterval) {
        if let fall {
            let t = now - fall.started
            let y = max(fall.toY, fall.fromY - 0.5 * Self.gravity * t * t)
            panel.setFrameOrigin(NSPoint(x: panel.frame.minX, y: y))
            if y <= fall.toY {
                self.fall = nil
                snapToSurface(within: 4)
                engine.dragEnded()  // the landing
                saveOrigin()
            }
            return
        }
        // Checked every frame, so the pet rides smoothly on a window being dragged.
        guard let perch, !sceneView.isDragging else { return }
        let frame = panel.frame
        guard let window = DesktopSurfaces.window(perch),
              window.frame.minX <= frame.midX + (window.frame.minX - perchFrame.minX),
              frame.midX + (window.frame.minX - perchFrame.minX) <= window.frame.maxX else {
            startFall(at: now)
            return
        }
        // A window that changes size while its top edge moves is minimizing (the genie
        // or scale effect) or being resized from the top: step off rather than ride it.
        if window.frame.size != perchFrame.size, window.frame.maxY != perchFrame.maxY {
            startFall(at: now)
            return
        }
        // Ride along with the window's top-left corner.
        let dx = window.frame.minX - perchFrame.minX, dy = window.frame.maxY - perchFrame.maxY
        if dx != 0 || dy != 0 {
            panel.setFrameOrigin(NSPoint(x: frame.minX + dx, y: frame.minY + dy))
        }
        perchFrame = window.frame
    }

    /// Drops to the highest window top below the pet's feet, or the screen bottom.
    private func startFall(at now: TimeInterval) {
        leftWindow = perch
        perch = nil
        let frame = panel.frame
        let feet = frame.minY + floorInWindow
        var landing = screenUnderPet.visibleFrame.minY
        for surface in DesktopSurfaces.windows()
            where surface.window != leftWindow
               && surface.frame.minX <= frame.midX && frame.midX <= surface.frame.maxX
               && surface.frame.maxY < feet - 1 && surface.frame.maxY > landing {
            landing = surface.frame.maxY
        }
        guard landing < feet - 1 else { return }
        fall = (frame.minY, landing - floorInWindow, now)
        engine.dragBegan()  // held in the air
    }

    /// Replaces the view if SceneKit has stopped drawing (seen after waking from
    /// sleep: its display link keeps firing but skips every frame, and toggling
    /// `isPlaying` doesn't clear that). A fresh view on the same scene draws again.
    private func restartRenderingIfStalled(at now: TimeInterval) {
        if now - renderWatch.lastFrame < 0.5 { failedFixes = 0 }
        guard panel.occlusionState.contains(.visible), !sceneView.isDragging,
              now - renderWatch.lastFrame > 1, now - lastRenderFix > 2 else { return }
        lastRenderFix = now
        guard failedFixes < 3 else {
            NSLog("SekhPet: %@ still not rendering after %d new views", name, failedFixes)
            onRenderStuck?()
            return
        }
        failedFixes += 1
        NSLog("SekhPet: %@ stopped rendering %.1fs ago; replacing its view", name, now - renderWatch.lastFrame)
        let old = sceneView
        old.isPlaying = false
        old.delegate = nil
        old.scene = nil
        sceneView = PetSceneView(frame: old.frame)
        configure(sceneView)
        tracker.view = sceneView
        renderWatch.reset()
    }

    /// The mouse pointer in this pet's scene coordinates (metres).
    private func cursorInScene() -> CGPoint {
        let mouse = NSEvent.mouseLocation
        let frame = panel.frame
        let bounds = stage.bounds
        return CGPoint(x: (mouse.x - frame.midX) / pointsPerMetre + bounds.midX,
                       y: (mouse.y - frame.minY) / pointsPerMetre + bounds.minY)
    }

    // MARK: Commands

    func resetPosition() {
        panel.setFrameOrigin(defaultOrigin())
        defaults.removeObject(forKey: key(Key.origin))
    }

    func setMode(_ mode: BehaviorEngine.Mode) {
        engine.setMode(mode)
        saveBehavior()
    }

    /// This pet's own Movement choice; the shared Wander switch can pin it regardless.
    private(set) var isPinned = false
    /// The shared Wander switch: off pins every pet.
    var wanderAllowed = true {
        didSet { applyPinned() }
    }

    /// Pinned pets stay where they are and play every animation in place.
    func setPinned(_ pinned: Bool) {
        isPinned = pinned
        applyPinned()
        defaults.set(pinned ? "pinned" : "roam", forKey: key(Key.movement))
    }

    private func applyPinned() {
        let pinned = isPinned || !wanderAllowed
        guard pinned != stage.rig.motion.isPinned else { return }
        stage.rig.motion.isPinned = pinned
        if pinned { stage.rig.actor.setDepth(0, over: 1) }
    }

    /// Plays one of the pet's surprises or travel gaits, picked at random.
    func playRandom() {
        let entries = catalog.surprisePool + catalog.locomotion.map { Catalog.PoolEntry(clip: $0.clip, group: nil) }
        if let entry = entries.randomElement() { playNow(entry) }
    }

    func playNow(_ entry: Catalog.PoolEntry) {
        engine.playNow(entry)
        saveBehavior()
    }

    func applySize(_ newSize: PetSize) {
        size = newSize
        // Keep the pet's feet where they were, centred on the same spot.
        let old = panel.frame
        let new = windowSize()
        let origin = clamped(NSPoint(x: old.midX - new.width / 2, y: old.minY))
        panel.setFrame(NSRect(origin: origin, size: new), display: true)
        saveOrigin()
    }

    /// Fewer frames and no anti-aliasing (Low Power).
    var lowPower = false {
        didSet { if lowPower != oldValue { applyRendering(to: sceneView) } }
    }

    /// Set while the window is carrying the pet across the screen.
    private var travelling = false

    private func applyRendering(to view: PetSceneView) {
        view.antialiasingMode = lowPower ? .none : .multisampling2X
        // While travelling, draw at the window's movement rate (60 Hz, or 30 in Low
        // Power); at a lower rate a planted foot visibly slips between frames.
        view.preferredFramesPerSecond = travelling ? (lowPower ? 30 : 60) : (lowPower ? 20 : 30)
    }

    func setPaused(_ paused: Bool, _ reason: PauseReason) {
        if paused { pauseReasons.insert(reason) } else { pauseReasons.remove(reason) }
        let shouldPause = !pauseReasons.isEmpty
        guard shouldPause != engine.isPaused else { return }
        stage.scene.isPaused = shouldPause
        sceneView.isPlaying = !shouldPause
        if shouldPause { engine.pause() } else { engine.resume() }
        // A pause isn't a stall.
        renderWatch.reset()
    }

    // MARK: Window

    /// Screen points per model metre: the size preset times the game's mesh scale.
    private var pointsPerMetre: Double { size.pointsPerMetre * catalog.meshScale }

    private func buildWindow() {
        let frame = NSRect(origin: .zero, size: windowSize())
        panel.setContentSize(frame.size)
        sceneView.frame = frame
        panel.setFrameOrigin(clamped(savedOrigin() ?? defaultOrigin()))
        tracker.start()
    }

    /// Sets up `view` to show the pet and installs it as the window's content.
    private func configure(_ view: PetSceneView) {
        view.scene = stage.scene
        view.pointOfView = stage.camera
        view.backgroundColor = .clear
        applyRendering(to: view)
        view.isPlaying = true
        view.rendersContinuously = true
        view.delegate = renderWatch
        view.autoresizingMask = [.width, .height]
        view.onInput = { [unowned self] input in
            switch input {
            case .click: engine.click()
            case .doubleClick: engine.doubleClick()
            case .dragBegan:
                perch = nil
                leftWindow = nil
                fall = nil
                engine.dragBegan()
            case .dragEnded:
                engine.dragEnded()
                snapToSurface(within: 40)
            }
        }
        view.onMoved = { [unowned self] _ in saveOrigin() }
        view.constrainOrigin = { [unowned self] in clamped($0) }
        view.contextMenu = { [unowned self] in contextMenu?() }
        panel.contentView = view
    }

    private func connectMotion() {
        let motion = stage.rig.motion
        motion.onMove = { [unowned self] metres in
            guard !sceneView.isDragging else { return }
            var origin = panel.frame.origin
            origin.x += metres * pointsPerMetre
            panel.setFrameOrigin(origin)
        }
        motion.room = { [unowned self] in
            let frame = panel.frame
            let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: frame.midX, y: frame.midY)) }
                ?? NSScreen.main ?? NSScreen.screens[0]
            var visible = screen.visibleFrame
            // Standing on a window: walk only along it.
            if perch != nil { visible = visible.intersection(NSRect(x: perchFrame.minX, y: visible.minY, width: perchFrame.width, height: visible.height)) }
            let ppm = pointsPerMetre
            return (left: (frame.midX - visible.minX) / ppm, right: (visible.maxX - frame.midX) / ppm)
        }
        // Remember where wandering left the pet.
        engine.onChange = { [unowned self] _ in saveOrigin() }
    }

    private func observeOcclusion() {
        occlusionObserver = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                               object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.setPaused(!self.panel.occlusionState.contains(.visible), .occluded)
            }
        }
    }

    private func windowSize() -> NSSize {
        let ppm = pointsPerMetre
        return NSSize(width: (stage.bounds.width * ppm).rounded(), height: (stage.bounds.height * ppm).rounded())
    }

    /// Along the bottom of the main screen from the right, each pet left of the previous one.
    private func defaultOrigin() -> NSPoint {
        let visible = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let width = windowSize().width
        let x = visible.maxX - 40 - width * (0.55 * Double(index) + 1)
        return NSPoint(x: max(visible.minX, x), y: visible.minY)
    }

    /// Lowers `origin` if needed so the top of the idle pose stays below the menu
    /// bar, like a window's title bar. Taller clips may still rise past it.
    private func clamped(_ origin: NSPoint) -> NSPoint {
        let size = windowSize()
        let centre = NSPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(centre) })
                ?? NSScreen.screens.first(where: { $0.frame.minX <= centre.x && centre.x < $0.frame.maxX })
        else { return origin }
        let headTop = (catalog.clip(catalog.idleClip).bounds.max[1] - stage.bounds.minY) * pointsPerMetre
        return NSPoint(x: origin.x, y: min(origin.y, screen.visibleFrame.maxY - headTop))
    }

    private func savedOrigin() -> NSPoint? {
        guard let text = string(Key.origin) else { return nil }
        let origin = NSPointFromString(text)
        let frame = NSRect(origin: origin, size: windowSize())
        // Ignore positions on a display that is no longer attached.
        return NSScreen.screens.contains { $0.frame.intersects(frame) } ? origin : nil
    }

    private func saveOrigin() {
        defaults.set(NSStringFromPoint(panel.frame.origin), forKey: key(Key.origin))
    }

    // MARK: Behavior settings

    private func restoreBehavior() {
        snapping = defaults.object(forKey: key(Key.snapping)) as? Bool ?? true
        let doubleClip = string(Key.doubleClickClip), doubleGroup = string(Key.doubleClickGroup)
        // Ignore a saved choice the pack no longer has.
        if doubleClip.map({ catalog.clips[$0] != nil }) ?? doubleGroup.map({ catalog.groups[$0] != nil }) ?? false {
            engine.doubleClickOverride = Catalog.PoolEntry(clip: doubleClip, group: doubleGroup)
        }
        isPinned = string(Key.movement) == "pinned"
        applyPinned()
        let clip = string(Key.loopClip)
        let group = string(Key.loopGroup)
        if string(Key.mode) == "loop",
           clip.map({ catalog.clips[$0] != nil }) ?? group.map({ catalog.groups[$0] != nil }) ?? false {
            engine.setMode(.loop)
            engine.playNow(Catalog.PoolEntry(clip: clip, group: group))
        }
    }

    private func saveBehavior() {
        defaults.set(engine.mode == .loop ? "loop" : "random", forKey: key(Key.mode))
        defaults.set(engine.loopSelection.clip, forKey: key(Key.loopClip))
        defaults.set(engine.loopSelection.group, forKey: key(Key.loopGroup))
    }

    // MARK: Defaults

    private var defaults: UserDefaults { .standard }

    private func key(_ base: String) -> String { "\(name).\(base)" }

    private func string(_ base: String) -> String? {
        defaults.string(forKey: key(base))
    }
}

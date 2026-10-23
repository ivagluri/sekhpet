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
        static let doubleClickRandom = "doubleClickRandom"
        static let watch = "watchCursor"
        static let size = "petSize"
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
        defaultSize = size
        sizeOverride = PetSize(rawValue: UserDefaults.standard.string(forKey: "\(catalog.name).\(Key.size)") ?? "")
        self.size = sizeOverride ?? size

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
        landingShadow.close()
    }

    func frame(at now: TimeInterval) {
        if housed {
            guard !engine.isPaused else { return }
            engine.tick()
            stage.rig.motion.update(at: now)
            stage.rig.look.update(cursor: nil, at: now)
            return
        }
        // Before the pause check: a pet off every screen counts as hidden, so it's paused.
        returnIfOffScreen(at: now)
        // Also before it: a pet covered along with its window must come back up with it.
        keepWithWindow()
        // A covered pet still rides its window: Mission Control covers the ones that sit
        // with their window, and they must follow it through and back.
        guard !engine.isPaused else {
            updatePerch(at: now, canFall: false)
            return
        }
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

    // MARK: Pet House

    /// While in the Pet House, the pet's body lives in the house's scene and its window is hidden.
    private(set) var housed = false

    /// Hands the pet's body to the Pet House, standing still at neutral depth.
    func enterHouse() -> SCNNode {
        housed = true
        perch = nil
        fall = nil
        jump = nil
        awaitedWindow = nil
        panel.orderOut(nil)
        setPaused(false, .occluded)
        setDrawing(false)
        stage.rig.motion.isPinned = true
        stage.rig.actor.setDepth(0, over: 0)
        let body = stage.rig.actor.node
        body.removeFromParentNode()
        return body
    }

    /// Takes the body back and returns to the desktop where the pet was.
    func leaveHouse() {
        guard housed else { return }
        housed = false
        let body = stage.rig.actor.node
        body.removeFromParentNode()
        stage.scene.rootNode.addChildNode(body)
        applyPinned()
        panel.orderFrontRegardless()
        setDrawing(!engine.isPaused)
        renderWatch.reset()
        snapToSurface(within: 6)
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
        engine.doubleClickRandom = false
        defaults.set(entry?.clip, forKey: key(Key.doubleClickClip))
        defaults.set(entry?.group, forKey: key(Key.doubleClickGroup))
        defaults.set(false, forKey: key(Key.doubleClickRandom))
    }

    /// Every double-click plays a different random animation.
    func setDoubleClickRandom() {
        setDoubleClick(nil)
        engine.doubleClickRandom = true
        defaults.set(true, forKey: key(Key.doubleClickRandom))
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
    private var perchLayer = 0
    /// Until then, window changes come from Mission Control or Show Desktop.
    private var overviewUntil: TimeInterval = 0
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
        guard let best = landingSpot(for: panel.frame, within: gap, among: DesktopSurfaces.windows()) else { return false }
        perch = best.window?.window
        perchFrame = best.window?.frame ?? .zero
        perchLayer = best.window?.layer ?? 0
        if perch != nil { stage.rig.actor.setDepth(0, over: 0.3) }
        panel.setFrameOrigin(NSPoint(x: panel.frame.minX, y: best.top - floorInWindow))
        return true
    }

    /// The nearest window top or screen bottom within `gap` points of the feet of a pet
    /// with window `frame`, under its centre.
    private func landingSpot(for frame: NSRect, within gap: CGFloat, among surfaces: [DesktopSurfaces.Surface])
        -> (top: CGFloat, window: DesktopSurfaces.Surface?)? {
        guard snapping else { return nil }
        let feet = frame.minY + floorInWindow
        var best: (top: CGFloat, window: DesktopSurfaces.Surface?)?
        for surface in surfaces
            where surface.window != leftWindow
               && surface.frame.minX <= frame.midX && frame.midX <= surface.frame.maxX
               && abs(surface.frame.maxY - feet) <= gap && abs(surface.frame.maxY - feet) < abs((best?.top ?? .infinity) - feet) {
            best = (surface.frame.maxY, surface)
        }
        let bottom = screenUnderPet.visibleFrame.minY
        if abs(bottom - feet) <= gap, abs(bottom - feet) < abs((best?.top ?? .infinity) - feet) {
            best = (bottom, nil)
        }
        return best
    }

    // MARK: Landing shadow

    private let landingShadow = LandingShadow()
    /// The windows when the drag began: they don't move during it, and reading them on
    /// every mouse move would be slow.
    private var dragSurfaces: [DesktopSurfaces.Surface] = []

    /// While dragging, a faint oval under the pet's feet, or glowing on the surface it
    /// would snap to if let go now.
    private func showLanding(for origin: NSPoint) {
        let frame = NSRect(origin: origin, size: panel.frame.size)
        let spot = landingSpot(for: frame, within: 40, among: dragSurfaces)
        let idle = catalog.clip(catalog.idleClip).bounds
        let width = min(max((idle.max[0] - idle.min[0]) * pointsPerMetre * 0.7, 40), 260)
        landingShadow.show(at: NSPoint(x: frame.midX, y: spot?.top ?? frame.minY + floorInWindow),
                           width: width, glowing: spot != nil, behind: panel)
    }

    /// Follows the perch window, or falls when it's gone; animates a fall in progress.
    /// Without `canFall` (while paused) it only rides, and leaves any fall for later.
    private func updatePerch(at now: TimeInterval, canFall: Bool = true) {
        if canFall, animateJump(at: now) { return }
        if canFall, perch == nil, fall == nil { watchForReturn(at: now) }
        if let fall {
            guard canFall else { return }
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
        guard let perch, !sceneView.isDragging, let checked = checkPerch(perch, at: now) else { return }
        let frame = panel.frame
        guard let window = checked else {
            if canFall {
                rememberForReturn(perch)
                startFall(at: now)
            }
            return
        }
        // Mission Control and Show Desktop shrink and slide windows, then put them back:
        // ride along through it rather than treating it as minimizing.
        // Checked on every change, and every frame while one is under way; changes stay
        // treated this way for a second after it ends, while windows animate back.
        if perchMovedAt == now || now < overviewUntil, missionControlSeen {
            overviewUntil = now + 1
        }
        if now >= overviewUntil {
            // Stepped off the end of a window that got narrower.
            let shifted = frame.midX + (window.frame.minX - perchFrame.minX)
            guard window.frame.minX <= shifted, shifted <= window.frame.maxX else {
                if canFall { startFall(at: now) }
                return
            }
            // A window that changes size while its top edge moves is minimizing (the genie
            // or scale effect) or being resized from the top: step off rather than ride it.
            if window.frame.size != perchFrame.size, window.frame.maxY != perchFrame.maxY {
                if canFall {
                    rememberForReturn(perch)
                    startFall(at: now)
                }
                return
            }
        }

        // Ride along with the window's top-left corner, but never off the screen: Show
        // Desktop slides windows away and back, so the pet waits at the edge and rides
        // back in with it.
        let dx = window.frame.minX - perchFrame.minX, dy = window.frame.maxY - perchFrame.maxY
        guard dx != 0 || dy != 0 else { return }
        let feet = NSPoint(x: frame.midX + dx, y: frame.minY + dy + floorInWindow)
        guard NSScreen.screens.contains(where: { $0.frame.contains(feet) }) else { return }
        panel.setFrameOrigin(NSPoint(x: frame.minX + dx, y: frame.minY + dy))
        perchFrame = window.frame
    }

    private var nextPerchCheck: TimeInterval = 0
    private var perchMovedAt: TimeInterval = 0
    private var lastSeenFrame = NSRect.zero

    /// The perch window, when it's due a check: every frame while it moves, for smooth
    /// riding while it's dragged, otherwise 10 times a second, on a beat all pets share
    /// so they read the windows once between them. (Reading from a background thread
    /// instead stalled drawing for half a second.)
    private func checkPerch(_ perch: CGWindowID, at now: TimeInterval) -> DesktopSurfaces.Surface?? {
        guard now >= nextPerchCheck else { return nil }
        let snapshot = DesktopSurfaces.snapshot(at: now)
        let window = snapshot.windows[perch]
        missionControlSeen = snapshot.missionControl
        panelInFrontOfPerch = window.map { perch in
            snapshot.windows[CGWindowID(panel.windowNumber)].map { $0.place < perch.place } ?? false
        } ?? false
        if let window, window.surface.frame != lastSeenFrame {
            perchMovedAt = now
            lastSeenFrame = window.surface.frame
        }
        nextPerchCheck = now - perchMovedAt < 0.5 ? now : ((now * 10).rounded(.down) + 1) / 10
        return .some(window?.surface)
    }

    private var missionControlSeen = false
    private var panelInFrontOfPerch = false


    /// A pet standing on an ordinary window sits just above that window instead of above
    /// everything, so whatever covers the window covers the pet too. Pets on the screen
    /// bottom or an always-on-top window, or being dragged or falling, stay on top.
    private func keepWithWindow() {
        guard let perch, perchLayer == 0, !sceneView.isDragging else {
            if panel.level != .floating {
                panel.level = .floating
                panel.orderFrontRegardless()
            }
            return
        }
        // Clicking the window brings it in front of the pet: go back on top of it.
        if panel.level == .normal, panelInFrontOfPerch { return }
        panel.level = .normal
        panel.order(.above, relativeTo: Int(perch))
        panelInFrontOfPerch = true
    }

    private var lastOnScreenCheck: TimeInterval = 0

    /// Safety net: a pet whose feet are on no screen (whatever put it there) drops back
    /// in at the nearest screen's bottom edge.
    private func returnIfOffScreen(at now: TimeInterval) {
        guard now - lastOnScreenCheck >= 1, !sceneView.isDragging else { return }
        lastOnScreenCheck = now
        let frame = panel.frame
        let feet = NSPoint(x: frame.midX, y: frame.minY + floorInWindow)
        guard !NSScreen.screens.contains(where: { $0.frame.contains(feet) }),
              let screen = NSScreen.screens.min(by: { abs($0.frame.midX - feet.x) < abs($1.frame.midX - feet.x) })
        else { return }
        perch = nil
        fall = nil
        let visible = screen.visibleFrame
        let x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        panel.setFrameOrigin(NSPoint(x: x, y: visible.minY - floorInWindow))
        saveOrigin()
    }

    // MARK: Jumping back

    /// The window the pet fell from when it minimized or hid, where on it the pet stood,
    /// whether it has been seen gone, and its last frame, to wait for it to settle.
    private var awaitedWindow: (id: CGWindowID, offset: CGFloat, gone: Bool, lastFrame: NSRect)?
    private var jump: (from: NSPoint, to: NSPoint, started: TimeInterval, duration: TimeInterval)?
    private var nextReturnCheck: TimeInterval = 0

    private func rememberForReturn(_ window: CGWindowID) {
        awaitedWindow = (window, panel.frame.midX - perchFrame.minX, false, .zero)
    }

    /// Jumps back onto the awaited window once it's back on screen and has stopped
    /// animating (restoring from the Dock, or unhiding).
    private func watchForReturn(at now: TimeInterval) {
        guard let awaited = awaitedWindow, !sceneView.isDragging, now >= nextReturnCheck else { return }
        nextReturnCheck = ((now * 10).rounded(.down) + 1) / 10
        guard let window = DesktopSurfaces.snapshot(at: now).windows[awaited.id]?.surface else {
            awaitedWindow?.gone = true
            return
        }
        awaitedWindow?.lastFrame = window.frame
        guard awaited.gone, window.frame == awaited.lastFrame else { return }
        awaitedWindow = nil
        let frame = panel.frame
        let midX = min(max(window.frame.minX + awaited.offset, window.frame.minX + 20), window.frame.maxX - 20)
        let to = NSPoint(x: midX - frame.width / 2, y: window.frame.maxY - floorInWindow)
        let rise = abs(to.y - frame.minY)
        // Leaves the ground once the take-off clip (JumpStart, where there is one) has played.
        let takeOff = engine.jumpBegan()
        jump = (frame.origin, to, now + takeOff, min(0.9, 0.45 + Double(rise) / 2000))
        leftWindow = nil
    }

    /// A jump in progress: an arc up and over to the window top, then the landing.
    private func animateJump(at now: TimeInterval) -> Bool {
        guard let jump else { return false }
        let t = max(0, min(1, (now - jump.started) / jump.duration))
        let arc = max(80, abs(jump.to.y - jump.from.y) * 0.25)
        let x = jump.from.x + (jump.to.x - jump.from.x) * t
        let y = jump.from.y + (jump.to.y - jump.from.y) * t + arc * 4 * t * (1 - t)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        if t >= 1 {
            self.jump = nil
            snapToSurface(within: 4)
            engine.jumpEnded()
            saveOrigin()
        }
        return true
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
        // In the Pet House the house moves the pet; its clips play in place.
        let pinned = housed || isPinned || !wanderAllowed
        guard pinned != stage.rig.motion.isPinned else { return }
        stage.rig.motion.isPinned = pinned
        if pinned { stage.rig.actor.setDepth(0, over: 1) }
    }

    /// Plays one of the pet's surprises or travel gaits, picked at random.
    func playRandom() {
        if let entry = engine.randomEntry() { playNow(entry) }
    }

    func playNow(_ entry: Catalog.PoolEntry) {
        engine.playNow(entry)
        saveBehavior()
    }

    /// The shared Size setting, used unless this pet has its own.
    var defaultSize: PetSize {
        didSet { if sizeOverride == nil { applySize(defaultSize) } }
    }
    /// This pet's own size; nil follows the shared one. Saved.
    private(set) var sizeOverride: PetSize?

    func setSize(_ newSize: PetSize?) {
        sizeOverride = newSize
        defaults.set(newSize?.rawValue, forKey: key(Key.size))
        applySize(newSize ?? defaultSize)
    }

    private func applySize(_ newSize: PetSize) {
        guard newSize != size else { return }
        let feet = panel.frame.minY + floorInWindow
        size = newSize
        // Keep the pet's feet where they were (on a window, say), centred on the same spot.
        let old = panel.frame
        let new = windowSize()
        let origin = clamped(NSPoint(x: old.midX - new.width / 2, y: feet - floorInWindow))
        panel.setFrame(NSRect(origin: origin, size: new), display: true)
        saveOrigin()
    }

    /// The shared Watch Cursor setting, used unless this pet has its own.
    var defaultWatch = BehaviorEngine.Watch.occasionally {
        didSet { engine.watch = watchOverride ?? defaultWatch }
    }
    /// This pet's own Watch Cursor setting; nil follows the shared one. Saved.
    private(set) var watchOverride: BehaviorEngine.Watch?

    func setWatch(_ watch: BehaviorEngine.Watch?) {
        watchOverride = watch
        engine.watch = watch ?? defaultWatch
        defaults.set(watch?.rawValue, forKey: key(Key.watch))
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

    /// Stopping the scene isn't enough: a view that renders continuously keeps drawing
    /// its last frame, even with its window hidden. Stopped views draw nothing.
    private func setDrawing(_ on: Bool) {
        sceneView.isPlaying = on
        sceneView.rendersContinuously = on
    }

    func setPaused(_ paused: Bool, _ reason: PauseReason) {
        if paused { pauseReasons.insert(reason) } else { pauseReasons.remove(reason) }
        let shouldPause = !pauseReasons.isEmpty
        guard shouldPause != engine.isPaused else { return }
        stage.scene.isPaused = shouldPause
        setDrawing(!shouldPause && !housed)
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
                jump = nil
                awaitedWindow = nil
                dragSurfaces = DesktopSurfaces.windows()
                engine.dragBegan()
            case .dragEnded:
                landingShadow.show(at: nil, width: 0, behind: panel)
                dragSurfaces = []
                engine.dragEnded()
                snapToSurface(within: 40)
            }
        }
        view.onMoved = { [unowned self] _ in saveOrigin() }
        view.constrainOrigin = { [unowned self] in
            let origin = clamped($0)
            showLanding(for: origin)
            return origin
        }
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
                self.setPaused(!self.housed && !self.panel.occlusionState.contains(.visible), .occluded)
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
        engine.doubleClickRandom = defaults.bool(forKey: key(Key.doubleClickRandom))
        isPinned = string(Key.movement) == "pinned"
        watchOverride = string(Key.watch).flatMap(BehaviorEngine.Watch.init(rawValue:))
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

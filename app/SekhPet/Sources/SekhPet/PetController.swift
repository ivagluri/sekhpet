import AppKit
import SceneKit

/// One pet on the desktop: its scene, behavior, window and saved settings.
/// Created when the pet is placed on the desktop and closed when it is removed.
/// Settings are stored per pet as "<name>.<key>".
@MainActor
final class PetController {
    enum PauseReason { case user, occluded, screensAsleep, locked }
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
        perch.snapToSurface(within: 6)
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
        // A covered pet still rides its window: Mission Control covers the ones that sit
        // with their window, and they must follow it through and back. And a pet off every
        // screen counts as hidden, so it's paused, but must still come back.
        guard !engine.isPaused else {
            perch.update(at: now, canFall: false)
            return
        }
        // On a window of an app where Claude Code is working (a terminal), the pet works too.
        engine.work = perch.surface.map { ClaudeWatch.shared.hosts.contains($0.owner) } == true ? catalog.workClip : nil
        engine.tick()
        stage.rig.motion.update(at: now)
        let moving = stage.rig.motion.isMoving && !stage.rig.motion.isPinned
        if moving != travelling {
            travelling = moving
            applyRendering(to: sceneView)
        }
        stage.rig.look.update(cursor: cursorInScene(), at: now)
        perch.update(at: now, canFall: true)
        restartRenderingIfStalled(at: now)
    }

    // MARK: Pet House

    /// While in the Pet House, the pet's body lives in the house's scene and its window is hidden.
    private(set) var housed = false

    /// Hands the pet's body to the Pet House, standing still at neutral depth.
    func enterHouse() -> SCNNode {
        housed = true
        engine.work = nil
        perch.leave()
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
        perch.snapToSurface(within: 6)
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
        perch.snapping = on
        defaults.set(on, forKey: key(Key.snapping))
    }

    private lazy var perch: WindowPerch = {
        let perch = WindowPerch(window: panel, freeLevel: .floating) { [unowned self] in
            NSPoint(x: panel.frame.width / 2, y: floorInWindow)
        }
        perch.snapping = snapping
        perch.isHeld = { [unowned self] in sceneView.isDragging }
        perch.fallBegan = { [unowned self] in engine.dragBegan() }  // held in the air
        perch.fallEnded = { [unowned self] in engine.dragEnded() }  // the landing
        perch.jumpBegan = { [unowned self] in engine.jumpBegan() }
        perch.jumpEnded = { [unowned self] in engine.jumpEnded() }
        perch.settled = { [unowned self] in saveOrigin() }
        perch.perchChanged = { [unowned self] onWindow in
            stage.rig.motion.holdsDepth = onWindow
            if onWindow { stage.rig.actor.setDepth(0, over: 0.3) }
        }
        return perch
    }()

    /// Height of the pet's feet above the window's bottom edge, in points.
    private var floorInWindow: CGFloat { -stage.bounds.minY * pointsPerMetre }

    // MARK: Landing shadow

    private let landingShadow = LandingShadow()
    /// The windows when the drag began: they don't move during it, and reading them on
    /// every mouse move would be slow.
    private var dragSurfaces: [DesktopSurfaces.Surface] = []

    /// While dragging, a faint oval under the pet's feet, or glowing on the surface it
    /// would snap to if let go now.
    private func showLanding(for origin: NSPoint) {
        let frame = NSRect(origin: origin, size: panel.frame.size)
        let spot = perch.landingSpot(for: frame, within: 40, among: dragSurfaces)
        let idle = catalog.clip(catalog.idleClip).bounds
        let width = min(max((idle.max[0] - idle.min[0]) * pointsPerMetre * 0.7, 40), 260)
        landingShadow.show(at: NSPoint(x: frame.midX, y: spot?.top ?? frame.minY + floorInWindow),
                           width: width, glowing: spot != nil, behind: panel)
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
        // Waking the screens zooms every window out and back in, like Mission Control: ride it.
        // Unlocking does the same.
        if reason == .screensAsleep || reason == .locked { perch.setAway(paused, reason) }
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
                perch.leave()
                dragSurfaces = DesktopSurfaces.windows()
                engine.dragBegan()
            case .dragEnded:
                landingShadow.show(at: nil, width: 0, behind: panel)
                dragSurfaces = []
                engine.dragEnded()
                perch.snapToSurface(within: 40)
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
            var visible = Self.floor(from: screen)
            // Standing on a window: walk only along it.
            if let window = perch.surface?.frame {
                visible = visible.intersection(NSRect(x: window.minX, y: visible.minY, width: window.width, height: visible.height))
            }
            let ppm = pointsPerMetre
            return (left: (frame.midX - visible.minX) / ppm, right: (visible.maxX - frame.midX) / ppm)
        }
        // Remember where wandering left the pet.
        engine.onChange = { [unowned self] _ in saveOrigin() }
    }

    /// The visible part of `screen`, widened across each screen beside it whose edge touches
    /// and whose floor is level with it, so pets walk from one display to the next. (With
    /// separate Spaces per display a crossing pet is cut off at the seam: it's crossing the gap.)
    private static func floor(from screen: NSScreen) -> NSRect {
        var area = screen.visibleFrame
        var left = screen, right = screen
        func neighbour(of screen: NSScreen, onRight: Bool) -> NSScreen? {
            NSScreen.screens.first { other in
                abs(onRight ? other.frame.minX - screen.frame.maxX : screen.frame.minX - other.frame.maxX) < 1
                    && abs(other.visibleFrame.minY - area.minY) < 1
            }
        }
        while let next = neighbour(of: right, onRight: true), next != screen {
            area.size.width = next.visibleFrame.maxX - area.minX
            right = next
        }
        while let next = neighbour(of: left, onRight: false), next != screen {
            area.size.width = area.maxX - next.visibleFrame.minX
            area.origin.x = next.visibleFrame.minX
            left = next
        }
        return area
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
        perch.snapping = snapping
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

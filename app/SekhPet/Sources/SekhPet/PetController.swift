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
        stage.rig.look.update(cursor: cursorInScene(), at: now)
        restartRenderingIfStalled(at: now)
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

    private func applyRendering(to view: PetSceneView) {
        view.antialiasingMode = lowPower ? .none : .multisampling2X
        view.preferredFramesPerSecond = lowPower ? 20 : 30
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
            case .dragBegan: engine.dragBegan()
            case .dragEnded: engine.dragEnded()
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
            let visible = screen.visibleFrame
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

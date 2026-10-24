import AppKit
import SceneKit

/// The Pet House: a room in an ordinary window that every pet on the desktop moves
/// into while it's open. They stroll about, visit each other, knock a ball and a
/// fruit around and now and then eat the fruit, which comes back a little later.
/// Pets and things can be picked up and dropped, or thrown. The window has no frame or
/// background, so the room sits on the desktop like a toy box; drag the box to move it,
/// or the arrow on its front corner to resize it. The walls are frosted glass: the desktop
/// behind them shows through lightly blurred.
@MainActor
final class PetHouse: NSObject, NSWindowDelegate {
    /// Called when the user closes the window.
    var onClose: (() -> Void)?

    private let window: NSWindow
    private let view = HouseView(frame: NSRect(x: 0, y: 0, width: 760, height: 760 * PetHouse.aspect))
    /// The resize arrow, shown while the mouse is over the box.
    private let grip = PetHouse.makeGrip()
    /// Blurs the desktop behind the walls; masked to their outline on screen.
    private let frost = FrostView()
    private var walls: [SCNNode] = []
    private var floor = SCNNode()
    private var gripShown = false
    private let scene = SCNScene()
    private let room = SCNNode()
    private let camera = SCNNode()
    private let keyLight = SCNNode()
    private let ball: SCNNode
    private var fruit: SCNNode?
    private var fruitDue: TimeInterval = 0
    private var residents: [Resident] = []
    /// Floor size in metres: x across, z front to back.
    private var width = 8.0, depth = 4.5
    private var lastFrame: TimeInterval?
    private var userPaused = false
    private var hidden = false
    private var grabbed: Grab?
    private var throwSamples: [(position: SCNVector3, time: TimeInterval)] = []
    private var occlusionObserver: NSObjectProtocol?
    private var clickThrough: Timer?

    private enum Grab {
        case pet(Resident, lift: Double, carrying: Bool)
        case thing(SCNNode)
        /// Moving the whole box: the mouse's offset from the window's origin.
        case box(offset: NSPoint)
        /// Resizing from the grip: the window and mouse when it started.
        case resize(from: NSRect, mouse: NSPoint)
    }

    /// Window height to width; the box keeps its shape as it's resized.
    static let aspect = 0.84
    static let minWidth = 320.0

    static let ballRadius = 0.28
    static let fruitRadius = 0.16
    static let wallHeight = 1.6
    static let fruitDelay: ClosedRange<Double> = 30...60
    static let eatChance = 0.35

    override init() {
        window = HouseWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        ball = Self.makeBall()
        super.init()
        window.title = "Pet House"
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        let content = NSView(frame: view.frame)
        for layer in [frost, view] as [NSView] {
            layer.frame = content.bounds
            layer.autoresizingMask = [.width, .height]
            content.addSubview(layer)
        }
        window.contentView = content
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("PetHouse")
        // A frame saved in an older shape keeps its width and top edge.
        let saved = window.frame
        window.setFrame(NSRect(x: saved.minX, y: saved.maxY - saved.width * Self.aspect,
                               width: saved.width, height: saved.width * Self.aspect), display: false)

        scene.rootNode.addChildNode(room)
        let lens = SCNCamera()
        lens.fieldOfView = 42
        lens.projectionDirection = .horizontal
        lens.zNear = 0.1
        lens.zFar = 500
        camera.camera = lens
        scene.rootNode.addChildNode(camera)
        addLights()
        scene.rootNode.addChildNode(grip)
        scene.rootNode.addChildNode(ball)

        view.scene = scene
        view.pointOfView = camera
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling2X
        view.preferredFramesPerSecond = 30
        view.rendersContinuously = true
        view.isPlaying = true
        connectInput()
        layout()
        ball.position = SCNVector3(-width / 4, 1.5, depth / 6)
        // Back on the window it was standing on, if that's still there.
        snapToSurface(within: 6)

        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.hidden = !self.window.occlusionState.contains(.visible)
                self.applyPaused()
            }
        }
        // Clicks on the empty space around the box go to whatever is behind it.
        clickThrough = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateClickThrough() }
        }
    }

    func show() {
        window.orderFrontRegardless()
    }

    private func updateClickThrough() {
        guard grabbed == nil else { return }
        let mouse = NSEvent.mouseLocation
        guard window.frame.contains(mouse) else {
            window.ignoresMouseEvents = true
            return
        }
        let point = view.convert(window.convertPoint(fromScreen: mouse), from: nil)
        let overBox = !view.hitTest(point, options: [.ignoreHiddenNodes: true]).isEmpty
        window.ignoresMouseEvents = !overBox
        showGrip(overBox)
    }

    private func showGrip(_ show: Bool) {
        guard show != gripShown else { return }
        gripShown = show
        grip.removeAllActions()
        grip.runAction(.fadeOpacity(to: show ? 1 : 0, duration: 0.2))
    }

    /// Sends every pet back to the desktop and closes the window.
    func close() {
        for resident in residents { remove(resident.pet) }
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        clickThrough?.invalidate()
        view.isPlaying = false
        window.delegate = nil
        window.close()
    }

    func windowWillClose(_ notification: Notification) { onClose?() }

    var lowPower = false {
        didSet {
            view.antialiasingMode = lowPower ? .none : .multisampling2X
            view.preferredFramesPerSecond = lowPower ? 20 : 30
        }
    }

    func setPaused(_ paused: Bool) {
        userPaused = paused
        applyPaused()
    }

    /// The physics and the room's animations stop with Pause All, or while the window can't be seen.
    private func applyPaused() {
        scene.isPaused = userPaused || hidden
        for resident in residents { resident.pet.setPaused(hidden, .occluded) }
    }

    // MARK: Residents

    func add(_ pet: PetController) {
        guard !residents.contains(where: { $0.pet === pet }) else { return }
        let resident = Resident(pet: pet)
        resident.holder.addChildNode(pet.enterHouse())
        room.addChildNode(resident.holder)
        scene.rootNode.addChildNode(resident.collider)
        residents.append(resident)
        layout()
        resident.place(at: freeSpot(for: resident))
        resident.pet.setPaused(hidden, .occluded)
    }

    func remove(_ pet: PetController) {
        guard let index = residents.firstIndex(where: { $0.pet === pet }) else { return }
        let resident = residents.remove(at: index)
        if case let .pet(held, _, _)? = grabbed, held === resident { grabbed = nil }
        // The house ends its walks itself; on the desktop nothing would, and a held pet would stay held.
        switch resident.plan {
        case .walk: pet.engine.settle()
        case .carried: pet.engine.dragEnded()
        default: break
        }
        for other in residents { other.forget(resident) }
        resident.holder.removeFromParentNode()
        resident.collider.removeFromParentNode()
        pet.setPaused(false, .occluded)
        pet.leaveHouse()
    }

    // MARK: The room

    /// Sizes the room for the biggest resident and frames the camera on it.
    private func layout() {
        let biggest = residents.map(\.radius).max() ?? 0.5
        let tallest = residents.map(\.height).max() ?? 1
        width = max(8, biggest * 7)
        depth = width * 0.85
        let wall = max(Self.wallHeight, tallest * 0.7)

        room.childNodes.filter { $0.name == "room" }.forEach { $0.removeFromParentNode() }
        let floor = Self.box(width: width, height: 0.2, length: depth, colour: NSColor(calibratedRed: 0.72, green: 0.56, blue: 0.40, alpha: 1))
        floor.position = SCNVector3(0, -0.1, 0)
        room.addChildNode(floor)
        self.floor = floor
        let back = Self.box(width: width + 0.3, height: wall, length: 0.15, material: Self.glass())
        back.position = SCNVector3(0, wall / 2 - 0.2, -depth / 2 - 0.075)
        walls = [back]
        for side in [-1.0, 1.0] {
            let sideWall = Self.box(width: 0.15, height: wall, length: depth, material: Self.glass())
            sideWall.position = SCNVector3(side * (width / 2 + 0.075), wall / 2 - 0.2, 0)
            walls.append(sideWall)
        }
        for glass in walls {
            glass.castsShadow = false
            room.addChildNode(glass)
        }
        // A light metal frame: rails along the tops and posts at the corners.
        let metal = NSColor(calibratedWhite: 0.85, alpha: 1)
        let rail = 0.07, top = wall - 0.2
        let edgeX = width / 2 + 0.075, edgeZ = depth / 2 + 0.075
        var bars: [(SCNVector3, SCNVector3)] = [
            (SCNVector3(width + 0.3 + rail, rail, rail), SCNVector3(0, top, -edgeZ)),
            (SCNVector3(rail, rail, depth + 0.15), SCNVector3(-edgeX, top, 0)),
            (SCNVector3(rail, rail, depth + 0.15), SCNVector3(edgeX, top, 0)),
        ]
        for x in [-edgeX, edgeX] {
            for z in [-edgeZ, edgeZ] { bars.append((SCNVector3(rail, wall, rail), SCNVector3(x, wall / 2 - 0.2, z))) }
        }
        for (size, position) in bars {
            let bar = Self.box(width: size.x, height: size.y, length: size.z, colour: metal)
            bar.physicsBody = nil
            bar.position = position
            room.addChildNode(bar)
        }
        // Invisible, taller walls and a lid keep thrown things in, front included.
        let tall = wall * 4
        for (size, position) in [
            (SCNVector3(width, tall, 0.4), SCNVector3(0, tall / 2, -depth / 2 - 0.2)),
            (SCNVector3(width, tall, 0.4), SCNVector3(0, tall / 2, depth / 2 + 0.2)),
            (SCNVector3(0.4, tall, depth), SCNVector3(-width / 2 - 0.2, tall / 2, 0)),
            (SCNVector3(0.4, tall, depth), SCNVector3(width / 2 + 0.2, tall / 2, 0)),
            (SCNVector3(width, 0.4, depth), SCNVector3(0, tall, 0)),
        ] {
            let barrier = SCNNode()
            barrier.name = "room"
            barrier.position = position
            let shape = SCNPhysicsShape(geometry: SCNBox(width: size.x, height: size.y, length: size.z, chamferRadius: 0))
            barrier.physicsBody = SCNPhysicsBody(type: .static, shape: shape)
            room.addChildNode(barrier)
        }

        // From the front and a little above, wide enough to show the whole floor.
        let lens = camera.camera!
        let distance = width * 0.6 / tan(lens.fieldOfView / 2 * .pi / 180)
        let tilt = 30.0 * .pi / 180
        camera.position = SCNVector3(0, tallest * 0.4 + distance * sin(tilt), depth / 2 + distance * cos(tilt) - depth * 0.2)
        camera.look(at: SCNVector3(0, tallest * 0.4, -depth * 0.05))
        keyLight.light?.orthographicScale = width * 0.7
        grip.scale = SCNVector3(width / 16, width / 16, width / 16)
        grip.position = SCNVector3(width / 2 + 0.1, 0.1, depth / 2 + 0.1)

        updateFrost()
        for resident in residents { resident.place(at: clamp(resident.spot, for: resident)) }
        for thing in [ball, fruit].compactMap({ $0 }) where abs(thing.position.x) > width / 2 || abs(thing.position.z) > depth / 2 {
            thing.position = SCNVector3(0, 1.5, 0)
        }
    }

    private static func box(width: Double, height: Double, length: Double, colour: NSColor) -> SCNNode {
        let material = SCNMaterial()
        material.diffuse.contents = colour
        material.roughness.contents = 0.85
        material.lightingModel = .physicallyBased
        return box(width: width, height: height, length: length, material: material)
    }

    /// Pale, faintly blue and mostly clear, matte so it doesn't glare; the frost behind it does the blur.
    private static func glass() -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .lambert
        material.diffuse.contents = NSColor(calibratedRed: 0.86, green: 0.93, blue: 1, alpha: 0.1)
        material.transparencyMode = .dualLayer
        material.writesToDepthBuffer = false
        return material
    }

    private static func box(width: Double, height: Double, length: Double, material: SCNMaterial) -> SCNNode {
        let geometry = SCNBox(width: width, height: height, length: length, chamferRadius: 0.03)
        geometry.materials = [material]
        let node = SCNNode(geometry: geometry)
        node.name = "room"
        node.physicsBody = SCNPhysicsBody(type: .static, shape: nil)
        node.physicsBody?.friction = 0.8
        node.physicsBody?.restitution = 0.5
        return node
    }

    private func addLights() {
        scene.lightingEnvironment.contents = NSColor(white: 0.7, alpha: 1)
        scene.lightingEnvironment.intensity = 1.5
        let key = SCNLight()
        key.type = .directional
        key.intensity = 1100
        key.castsShadow = true
        key.shadowColor = NSColor(white: 0, alpha: 0.35)
        key.shadowRadius = 3
        key.shadowSampleCount = 4
        key.shadowMapSize = CGSize(width: 1024, height: 1024)
        key.automaticallyAdjustsShadowProjection = true
        keyLight.light = key
        keyLight.eulerAngles = SCNVector3(-1.0, -0.45, 0)
        scene.rootNode.addChildNode(keyLight)

        let rim = SCNLight()
        rim.type = .directional
        rim.intensity = 450
        let rimNode = SCNNode()
        rimNode.light = rim
        rimNode.eulerAngles = SCNVector3(-0.3, 2.6, 0)
        scene.rootNode.addChildNode(rimNode)
    }

    /// Masks the desktop blur to the walls' outlines as the camera sees them.
    /// Projected here rather than with `projectPoint`, which follows the last frame drawn
    /// and so lags behind a resize (and the first layout).
    private func updateFrost() {
        let outlines = walls.map { Self.hull(corners(of: $0)) }
        let path = CGMutablePath()
        for outline in outlines where outline.count > 2 { path.addLines(between: outline); path.closeSubpath() }
        frost.setShape(path)
    }

    /// Where a node's bounding-box corners fall in the view. Projected here rather than with
    /// `projectPoint`, which follows the last frame drawn and so lags behind a resize.
    private func corners(of node: SCNNode) -> [CGPoint] {
        let size = view.bounds.size
        guard let lens = camera.camera, size.width > 0, size.height > 0 else { return [] }
        let toScreen = simd_float4x4(lens.projectionTransform(withViewportSize: size)) * camera.simdWorldTransform.inverse
        let (lo, hi) = node.boundingBox
        var corners: [CGPoint] = []
        for x in [lo.x, hi.x] { for y in [lo.y, hi.y] { for z in [lo.z, hi.z] {
            let world = node.simdConvertPosition(SIMD3(Float(x), Float(y), Float(z)), to: nil)
            let clip = toScreen * SIMD4(world, 1)
            guard clip.w > 0 else { continue }
            corners.append(CGPoint(x: CGFloat((clip.x / clip.w + 1) / 2) * size.width,
                                   y: CGFloat((clip.y / clip.w + 1) / 2) * size.height))
        } } }
        return corners
    }

    // MARK: Standing on windows, like a pet

    /// The window the box stands on, as last seen, and its window level.
    private var perch: (window: CGWindowID, frame: NSRect, layer: Int)?
    private var fall: (fromY: CGFloat, toY: CGFloat, started: TimeInterval)?
    private var jump: (from: NSPoint, to: NSPoint, started: TimeInterval, duration: TimeInterval)?
    /// The window the box fell from when it minimized or hid, to jump back onto.
    private var awaited: (window: CGWindowID, offset: CGFloat, gone: Bool, lastFrame: NSRect)?
    /// The window just stepped off, possibly still shrinking away: never a landing spot.
    private var leftWindow: CGWindowID?
    private var nextPerchCheck: TimeInterval = 0
    private var nextReturnCheck: TimeInterval = 0
    private var perchMovedAt: TimeInterval = 0
    private var lastSeenFrame = NSRect.zero
    /// Until then, window changes come from Mission Control or Show Desktop.
    private var overviewUntil: TimeInterval = 0
    private static let gravity: CGFloat = 2500

    /// The bottom edge of the floor and its middle, in window coordinates: the box's feet.
    private var base: (y: CGFloat, midX: CGFloat)? {
        let points = corners(of: floor)
        guard let y = points.map(\.y).min(), let left = points.map(\.x).min(), let right = points.map(\.x).max() else { return nil }
        return (y, (left + right) / 2)
    }

    private var nextOnScreenCheck: TimeInterval = 0

    /// Like a pet's: a box whose feet aren't on any screen (saved mid-move, or left behind by
    /// a display that went away) drops onto the bottom of the nearest one.
    private func returnIfOffScreen(at now: TimeInterval) {
        guard now >= nextOnScreenCheck, !movingBox, jump == nil, let base else { return }
        nextOnScreenCheck = now + 1
        let frame = window.frame
        let feet = NSPoint(x: frame.minX + base.midX, y: frame.minY + base.y)
        guard !NSScreen.screens.contains(where: { $0.frame.insetBy(dx: -1, dy: -1).contains(feet) }),
              let screen = NSScreen.screens.min(by: { abs($0.frame.midX - feet.x) < abs($1.frame.midX - feet.x) })
        else { return }
        perch = nil
        fall = nil
        awaited = nil
        let visible = screen.visibleFrame
        let x = min(max(feet.x, visible.minX + base.midX), visible.maxX - (frame.width - base.midX)) - base.midX
        window.setFrameOrigin(NSPoint(x: x, y: visible.minY - base.y))
    }

    private var screenUnderBox: NSScreen? {
        let frame = window.frame
        return NSScreen.screens.first { $0.frame.minX <= frame.midX && frame.midX < $0.frame.maxX } ?? window.screen
    }

    private var movingBox: Bool {
        switch grabbed {
        case .box?, .resize?: true
        default: false
        }
    }

    /// Lands on the nearest window top or screen bottom within `gap` points of the box's
    /// bottom edge, under its middle.
    private func snapToSurface(within gap: CGFloat = 40) {
        guard let base else { return }
        let frame = window.frame
        let bottom = frame.minY + base.y, middle = frame.minX + base.midX
        var best: (top: CGFloat, surface: DesktopSurfaces.Surface?)?
        for surface in DesktopSurfaces.windows()
            where surface.window != leftWindow
               && surface.frame.minX <= middle && middle <= surface.frame.maxX
               && abs(surface.frame.maxY - bottom) <= gap && abs(surface.frame.maxY - bottom) < abs((best?.top ?? .infinity) - bottom) {
            best = (surface.frame.maxY, surface)
        }
        if let floor = screenUnderBox?.visibleFrame.minY,
           abs(floor - bottom) <= gap, abs(floor - bottom) < abs((best?.top ?? .infinity) - bottom) {
            best = (floor, nil)
        }
        guard let best else { return }
        window.setFrameOrigin(NSPoint(x: frame.minX, y: frame.minY + best.top - bottom))
        perch = best.surface.map { ($0.window, $0.frame, $0.layer) }
        lastSeenFrame = perch?.frame ?? .zero
        leftWindow = nil
        keepWithWindow(nil)
    }

    private func leavePerch() {
        perch = nil
        fall = nil
        jump = nil
        awaited = nil
        leftWindow = nil
        keepWithWindow(nil)
    }

    /// Standing on an ordinary window, the box sits just above it, so whatever covers the
    /// window covers the box too; on an always-on-top window it stays on top.
    private func keepWithWindow(_ snapshot: DesktopSurfaces.Snapshot?) {
        guard let perch else {
            if window.level != .normal { window.level = .normal }
            return
        }
        guard perch.layer == 0 else {
            if window.level != .floating { window.level = .floating }
            return
        }
        window.level = .normal
        // Clicking the window brings it in front of the box: go back on top of it.
        if let snapshot, let mine = snapshot.windows[CGWindowID(window.windowNumber)],
           let theirs = snapshot.windows[perch.window], mine.place < theirs.place { return }
        window.order(.above, relativeTo: Int(perch.window))
    }

    /// Rides the perch window, falls when it goes, and jumps back when it returns.
    /// While the house is hidden (Mission Control covers it) it rides along but never falls.
    private func updatePerch(at now: TimeInterval, canFall: Bool) {
        guard !movingBox else { return }
        if let jump {
            guard canFall else { return }
            animateJump(jump, at: now)
            return
        }
        if let fall {
            guard canFall else { return }
            let t = now - fall.started
            let y = max(fall.toY, fall.fromY - 0.5 * Self.gravity * t * t)
            window.setFrameOrigin(NSPoint(x: window.frame.minX, y: y))
            if y <= fall.toY {
                self.fall = nil
                snapToSurface(within: 4)
            }
            return
        }
        guard let perch else {
            if canFall { watchForReturn(at: now) }
            return
        }
        // Every frame while the window moves, for smooth riding; otherwise on the pets' 10 Hz beat.
        guard now >= nextPerchCheck, let base else { return }
        let snapshot = DesktopSurfaces.snapshot(at: now)
        let seen = snapshot.windows[perch.window]?.surface
        if let seen, seen.frame != lastSeenFrame {
            perchMovedAt = now
            lastSeenFrame = seen.frame
        }
        nextPerchCheck = now - perchMovedAt < 0.5 ? now : ((now * 10).rounded(.down) + 1) / 10
        guard let seen else {
            if canFall { fallOff(rememberingWindow: true, at: now) }
            return
        }
        let frame = window.frame
        if perchMovedAt == now || now < overviewUntil, snapshot.missionControl { overviewUntil = now + 1 }
        if now >= overviewUntil {
            // Off the end of a window that got narrower.
            let middle = frame.minX + base.midX + (seen.frame.minX - perch.frame.minX)
            guard seen.frame.minX <= middle, middle <= seen.frame.maxX else {
                if canFall { fallOff(rememberingWindow: false, at: now) }
                return
            }
            // Changing size while its top moves: minimizing, or resizing from the top.
            if seen.frame.size != perch.frame.size, seen.frame.maxY != perch.frame.maxY {
                if canFall { fallOff(rememberingWindow: true, at: now) }
                return
            }
        }
        keepWithWindow(snapshot)
        // Ride along, but never with the bottom edge off every screen (Show Desktop slides windows away).
        let dx = seen.frame.minX - perch.frame.minX, dy = seen.frame.maxY - perch.frame.maxY
        guard dx != 0 || dy != 0 else { return }
        let feet = NSPoint(x: frame.minX + base.midX + dx, y: frame.minY + base.y + dy)
        guard NSScreen.screens.contains(where: { $0.frame.contains(feet) }) else { return }
        window.setFrameOrigin(NSPoint(x: frame.minX + dx, y: frame.minY + dy))
        self.perch?.frame = seen.frame
    }

    /// Drops to the highest window top below the box, or the screen bottom.
    private func fallOff(rememberingWindow: Bool, at now: TimeInterval) {
        guard let perch, let base else { return }
        let frame = window.frame
        if rememberingWindow { awaited = (perch.window, frame.minX + base.midX - perch.frame.minX, false, .zero) }
        leftWindow = perch.window
        self.perch = nil
        keepWithWindow(nil)
        let bottom = frame.minY + base.y, middle = frame.minX + base.midX
        var landing = screenUnderBox?.visibleFrame.minY ?? bottom
        for surface in DesktopSurfaces.windows()
            where surface.window != leftWindow
               && surface.frame.minX <= middle && middle <= surface.frame.maxX
               && surface.frame.maxY < bottom - 1 && surface.frame.maxY > landing {
            landing = surface.frame.maxY
        }
        guard landing < bottom - 1 else { return }
        fall = (frame.minY, frame.minY - (bottom - landing), now)
    }

    /// Jumps back onto the window it fell from once that's back and has stopped animating.
    private func watchForReturn(at now: TimeInterval) {
        guard let awaited, now >= nextReturnCheck, let base else { return }
        nextReturnCheck = ((now * 10).rounded(.down) + 1) / 10
        guard let seen = DesktopSurfaces.snapshot(at: now).windows[awaited.window]?.surface else {
            self.awaited?.gone = true
            return
        }
        self.awaited?.lastFrame = seen.frame
        guard awaited.gone, seen.frame == awaited.lastFrame else { return }
        self.awaited = nil
        let frame = window.frame
        let middle = min(max(seen.frame.minX + awaited.offset, seen.frame.minX + 20), seen.frame.maxX - 20)
        let to = NSPoint(x: middle - base.midX, y: seen.frame.maxY - base.y)
        jump = (frame.origin, to, now, min(0.9, 0.45 + Double(abs(to.y - frame.minY)) / 2000))
        leftWindow = nil
    }

    /// An arc up and over to the window top.
    private func animateJump(_ jump: (from: NSPoint, to: NSPoint, started: TimeInterval, duration: TimeInterval), at now: TimeInterval) {
        let t = max(0, min(1, (now - jump.started) / jump.duration))
        let arc = max(80, abs(jump.to.y - jump.from.y) * 0.25)
        window.setFrameOrigin(NSPoint(x: jump.from.x + (jump.to.x - jump.from.x) * t,
                                      y: jump.from.y + (jump.to.y - jump.from.y) * t + arc * 4 * t * (1 - t)))
        if t >= 1 {
            self.jump = nil
            snapToSurface(within: 4)
        }
    }

    /// Convex hull, by the monotone chain.
    private static func hull(_ points: [CGPoint]) -> [CGPoint] {
        let sorted = points.sorted { ($0.x, $0.y) < ($1.x, $1.y) }
        func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat { (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x) }
        var lower: [CGPoint] = [], upper: [CGPoint] = []
        for p in sorted {
            while lower.count >= 2, cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 { lower.removeLast() }
            lower.append(p)
        }
        for p in sorted.reversed() {
            while upper.count >= 2, cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 { upper.removeLast() }
            upper.append(p)
        }
        return Array(lower.dropLast() + upper.dropLast())
    }

    /// A small round token with a diagonal double arrow, always facing the camera and drawn on top.
    private static func makeGrip() -> SCNNode {
        let size = 128.0
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            NSColor(white: 0, alpha: 0.6).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 4, dy: 4)).fill()
            NSColor(white: 1, alpha: 0.85).setStroke()
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 6, dy: 6))
            ring.lineWidth = 4
            ring.stroke()
            let config = NSImage.SymbolConfiguration(pointSize: size * 0.42, weight: .bold)
                .applying(.init(paletteColors: [.white]))
            if let arrow = NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: nil)?
                .withSymbolConfiguration(config) {
                let s = arrow.size
                arrow.draw(in: NSRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2, width: s.width, height: s.height))
            }
            return true
        }
        let plane = SCNPlane(width: 1, height: 1)
        let material = SCNMaterial()
        material.diffuse.contents = image
        material.lightingModel = .constant
        material.readsFromDepthBuffer = false
        material.isDoubleSided = true
        plane.materials = [material]
        let node = SCNNode(geometry: plane)
        node.name = "grip"
        node.renderingOrder = 100
        node.constraints = [SCNBillboardConstraint()]
        node.opacity = 0
        return node
    }

    private static func makeBall() -> SCNNode {
        let sphere = SCNSphere(radius: ballRadius)
        sphere.segmentCount = 32
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = NSColor(calibratedRed: 0.20, green: 0.45, blue: 0.95, alpha: 1)
        material.roughness.contents = 0.35
        sphere.materials = [material]
        let node = SCNNode(geometry: sphere)
        node.name = "ball"
        let body = SCNPhysicsBody(type: .dynamic, shape: SCNPhysicsShape(geometry: sphere))
        body.mass = 0.4
        body.restitution = 0.75
        body.friction = 0.6
        body.rollingFriction = 0.02
        body.damping = 0.1
        body.angularDamping = 0.3
        body.continuousCollisionDetectionThreshold = ballRadius
        node.physicsBody = body
        return node
    }

    private static func makeFruit() -> SCNNode {
        let sphere = SCNSphere(radius: fruitRadius)
        let skin = SCNMaterial()
        skin.lightingModel = .physicallyBased
        skin.diffuse.contents = NSColor(calibratedRed: 0.85, green: 0.12, blue: 0.10, alpha: 1)
        skin.roughness.contents = 0.3
        sphere.materials = [skin]
        let node = SCNNode(geometry: sphere)
        node.name = "fruit"
        node.scale = SCNVector3(1, 0.9, 1)
        let stem = SCNNode(geometry: SCNCylinder(radius: 0.012, height: 0.09))
        stem.geometry?.firstMaterial?.diffuse.contents = NSColor(calibratedRed: 0.35, green: 0.22, blue: 0.10, alpha: 1)
        stem.position = SCNVector3(0, fruitRadius + 0.03, 0)
        node.addChildNode(stem)
        let leaf = SCNNode(geometry: SCNSphere(radius: 0.04))
        leaf.geometry?.firstMaterial?.diffuse.contents = NSColor(calibratedRed: 0.25, green: 0.6, blue: 0.2, alpha: 1)
        leaf.scale = SCNVector3(1.4, 0.3, 0.8)
        leaf.position = SCNVector3(0.04, fruitRadius + 0.06, 0)
        node.addChildNode(leaf)
        let body = SCNPhysicsBody(type: .dynamic, shape: SCNPhysicsShape(geometry: sphere))
        body.mass = 0.25
        body.restitution = 0.3
        body.friction = 0.8
        body.rollingFriction = 0.15
        body.angularDamping = 0.5
        body.continuousCollisionDetectionThreshold = fruitRadius
        node.physicsBody = body
        return node
    }

    // MARK: Every frame

    func frame(at now: TimeInterval) {
        let dt = min(now - (lastFrame ?? now), 0.1)
        lastFrame = now
        returnIfOffScreen(at: now)
        updatePerch(at: now, canFall: !scene.isPaused)
        guard !scene.isPaused else { return }
        if fruit == nil, now >= fruitDue { dropFruit() }
        for thing in [ball, fruit].compactMap({ $0 }) { keepInside(thing) }
        for resident in residents where !resident.pet.engine.isPaused {
            think(resident, at: now)
            move(resident, dt: dt, at: now)
            resident.turn(dt: dt)
            resident.syncCollider()
        }
    }

    /// Anything knocked out of the room (through a wall, say) drops back in from above.
    private func keepInside(_ thing: SCNNode) {
        guard let body = thing.physicsBody, body.type == .dynamic else { return }
        let p = thing.presentation.position
        guard abs(Double(p.x)) > width / 2 || abs(Double(p.z)) > depth / 2 || p.y < -0.5 else { return }
        thing.position = SCNVector3(Double.random(in: -0.3...0.3) * width, 2.5, Double.random(in: -0.3...0.3) * depth)
        body.velocity = SCNVector3Zero
        body.angularVelocity = SCNVector4Zero
        body.resetTransform()
    }

    private func dropFruit() {
        let node = Self.makeFruit()
        node.position = SCNVector3(Double.random(in: -0.4...0.4) * width, 2.5, Double.random(in: -0.35...0.35) * depth)
        scene.rootNode.addChildNode(node)
        fruit = node
    }

    private func eat(_ resident: Resident, at now: TimeInterval) {
        guard let fruit, resident.canEat else { return }
        self.fruit = nil
        fruitDue = now + Double.random(in: Self.fruitDelay)
        let engine = resident.pet.engine
        if case .walk = resident.plan { engine.release() }
        engine.perform(.single("Eat", side: 1))
        let duration = resident.pet.catalog.clip("Eat").duration
        resident.plan = .eat(at: fruit.presentation.position, until: now + duration + 0.5)
        fruit.physicsBody = nil
        fruit.runAction(.sequence([.wait(duration: duration * 0.3),
                                   .scale(to: 0, duration: duration * 0.5),
                                   .removeFromParentNode()]))
    }

    /// Picks something new to do once the pet has settled back into idle.
    private func think(_ resident: Resident, at now: TimeInterval) {
        let engine = resident.pet.engine
        switch resident.plan {
        case let .rest(until):
            guard now >= until, engine.mode == .random, engine.currentName == resident.pet.catalog.idleClip else { return }
            choose(for: resident, at: now)
        case let .walk(_, _, started, walking):
            let name = resident.walkName
            if engine.currentName == name, !walking {
                resident.plan = resident.plan.walking()
            } else if (walking && engine.currentName != name) || (!walking && now - started > 4) || now - started > 20 {
                // Interrupted (a click, say), or it never got going.
                if engine.currentName == name { engine.release() }
                resident.rest(at: now)
            }
        case let .eat(_, until), let .chat(_, until):
            if now >= until { resident.rest(at: now) }
        case .carried:
            break
        }
    }

    private func choose(for resident: Resident, at now: TimeInterval) {
        let others = residents.filter { $0 !== resident && $0.isResting && $0.pet.engine.mode == .random }
        var options: [(weight: Double, target: Target)] = [(4, .spot(randomSpot(for: resident)))]
        options.append((2.5, .ball))
        if fruit != nil, resident.canEat { options.append((2, .fruit)) }
        if let other = others.randomElement() { options.append((2, .pet(other))) }
        var roll = Double.random(in: 0..<options.reduce(0) { $0 + $1.weight })
        let target = options.first { roll -= $0.weight; return roll < 0 }?.target ?? options[0].target
        guard let goal = goal(of: target, for: resident),
              let gait = resident.gait(for: hypot(goal.x - resident.spot.x, goal.z - resident.spot.z))
        else {
            resident.rest(at: now)
            return
        }
        resident.gaitClip = gait
        resident.pet.engine.perform(ClipSequence(name: resident.walkName, steps: [Step(clip: gait, loops: nil)], side: 1))
        resident.plan = .walk(target, gait: gait, started: now, walking: false)
    }

    private func goal(of target: Target, for resident: Resident) -> (x: Double, z: Double)? {
        switch target {
        case let .spot(spot): return spot
        case .ball: return (Double(ball.presentation.position.x), Double(ball.presentation.position.z))
        case .fruit:
            guard let fruit else { return nil }
            return (Double(fruit.presentation.position.x), Double(fruit.presentation.position.z))
        case let .pet(other):
            guard residents.contains(where: { $0 === other }) else { return nil }
            // Stop beside it, on the side we're coming from.
            let dx = resident.spot.x - other.spot.x, dz = resident.spot.z - other.spot.z
            let d = max(hypot(dx, dz), 0.001), gap = resident.radius + other.radius + 0.2
            return (other.spot.x + dx / d * gap, other.spot.z + dz / d * gap)
        }
    }

    private func move(_ resident: Resident, dt: Double, at now: TimeInterval) {
        switch resident.plan {
        case let .walk(target, gait, _, walking):
            guard walking, let goal = goal(of: target, for: resident) else {
                if case .walk(_, _, _, true) = resident.plan { stopWalking(resident, at: now) }
                return
            }
            let dx = goal.x - resident.spot.x, dz = goal.z - resident.spot.z
            let distance = hypot(dx, dz)
            let catalog = resident.pet.catalog
            let speed = (catalog.clip(gait).groundSpeed ?? 1) * catalog.meshScale
            resident.facing = atan2(dx, dz) * 180 / .pi
            let reach: Double = switch target {
            case .ball: resident.radius * 0.5
            case .fruit: resident.radius * 0.6
            default: 0.05
            }
            if distance <= reach {
                arrive(resident, at: target, now: now)
                return
            }
            let step = min(speed * dt, distance)
            var spot = (x: resident.spot.x + dx / distance * step, z: resident.spot.z + dz / distance * step)
            spot = separate(resident, at: spot)
            resident.place(at: clamp(spot, for: resident))
            // One good kick and it's done with the ball.
            if touch(resident, at: now), case .ball = target, case .walk = resident.plan { stopWalking(resident, at: now) }
        case let .eat(fruitAt, _):
            resident.facing = atan2(Double(fruitAt.x) - resident.spot.x, Double(fruitAt.z) - resident.spot.z) * 180 / .pi
        case let .chat(other, _):
            resident.facing = atan2(other.spot.x - resident.spot.x, other.spot.z - resident.spot.z) * 180 / .pi
        case .rest, .carried:
            break
        }
    }

    private func stopWalking(_ resident: Resident, at now: TimeInterval) {
        if resident.pet.engine.currentName == resident.walkName { resident.pet.engine.release() }
        resident.rest(at: now)
    }

    private func arrive(_ resident: Resident, at target: Target, now: TimeInterval) {
        switch target {
        case .fruit where fruit != nil:
            eat(resident, at: now)
        case let .pet(other) where other.isResting:
            stopWalking(resident, at: now)
            // Say hello: face each other and both do something.
            let until = now + Double.random(in: 5...8)
            for (a, b) in [(resident, other), (other, resident)] {
                a.plan = .chat(with: b, until: until)
                if let entry = a.pet.catalog.surprisePool.randomElement() { a.pet.engine.playNow(entry) }
            }
        default:
            stopWalking(resident, at: now)
        }
    }

    /// A walking pet that runs into the ball or the fruit sends it rolling, and may eat the fruit.
    /// Returns whether it kicked the ball.
    private func touch(_ resident: Resident, at now: TimeInterval) -> Bool {
        var kickedBall = false
        for (thing, radius) in [(ball, Self.ballRadius), (fruit, Self.fruitRadius)] {
            guard let thing, let body = thing.physicsBody, body.type == .dynamic else { continue }
            let p = thing.presentation.position
            let dx = Double(p.x) - resident.spot.x, dz = Double(p.z) - resident.spot.z
            let d = hypot(dx, dz)
            let touching = d < resident.radius + radius + 0.05 && Double(p.y) < resident.height
            if thing === fruit {
                defer { resident.touchingFruit = touching }
                if touching, !resident.touchingFruit, resident.canEat, Double.random(in: 0..<1) < Self.eatChance {
                    eat(resident, at: now)
                    return false
                }
            }
            guard touching, now - resident.lastKick > 0.6 else { continue }
            resident.lastKick = now
            let push = Double.random(in: 2.5...4.5) * Double(body.mass) / max(d, 0.001)
            body.applyForce(SCNVector3(dx * push, Double(body.mass) * Double.random(in: 0.5...2), dz * push), asImpulse: true)
            if thing === ball { kickedBall = true }
        }
        return kickedBall
    }

    /// Steps a moving pet aside rather than through another one.
    private func separate(_ resident: Resident, at spot: (x: Double, z: Double)) -> (x: Double, z: Double) {
        var spot = spot
        for other in residents where other !== resident {
            let dx = spot.x - other.spot.x, dz = spot.z - other.spot.z
            let d = hypot(dx, dz), least = (resident.radius + other.radius) * 0.8
            guard d < least, d > 0.0001 else { continue }
            // Only push out of overlaps that are getting deeper, so pets can still part.
            let before = hypot(resident.spot.x - other.spot.x, resident.spot.z - other.spot.z)
            guard d < before else { continue }
            spot.x += dx / d * (least - d) * 0.5
            spot.z += dz / d * (least - d) * 0.5
        }
        return spot
    }

    private func clamp(_ spot: (x: Double, z: Double), for resident: Resident) -> (x: Double, z: Double) {
        let rx = min(resident.radius, width / 2 - 0.1), rz = min(resident.radius, depth / 2 - 0.1)
        return (min(max(spot.x, -width / 2 + rx), width / 2 - rx), min(max(spot.z, -depth / 2 + rz), depth / 2 - rz))
    }

    private func randomSpot(for resident: Resident) -> (x: Double, z: Double) {
        clamp((Double.random(in: -0.5...0.5) * width, Double.random(in: -0.5...0.5) * depth), for: resident)
    }

    /// Somewhere clear of the others, if there is room.
    private func freeSpot(for resident: Resident) -> (x: Double, z: Double) {
        var best = randomSpot(for: resident), bestGap = -Double.infinity
        for _ in 0..<20 {
            let spot = randomSpot(for: resident)
            let gap = residents.filter { $0 !== resident }
                .map { hypot($0.spot.x - spot.x, $0.spot.z - spot.z) - $0.radius - resident.radius }
                .min() ?? .infinity
            if gap > bestGap { (best, bestGap) = (spot, gap) }
        }
        return best
    }

    // MARK: Input

    private func connectInput() {
        view.onPress = { [unowned self] point in press(at: point) }
        view.onDrag = { [unowned self] point in drag(to: point) }
        view.onRelease = { [unowned self] dragged in release(dragged: dragged) }
        view.onClick = { [unowned self] point, double in click(at: point, double: double) }
        view.menuAt = { [unowned self] point in resident(at: point).flatMap { $0.pet.contextMenu?() } }
    }

    private func resident(at point: NSPoint) -> Resident? {
        guard case let .pet(resident)? = thing(at: point) else { return nil }
        return resident
    }

    private enum Hit {
        case grip
        case pet(Resident)
        case thing(SCNNode)
    }

    private func thing(at point: NSPoint) -> Hit? {
        for hit in view.hitTest(point, options: [.ignoreHiddenNodes: true, .searchMode: SCNHitTestSearchMode.all.rawValue]) {
            var node: SCNNode? = hit.node
            while let current = node {
                if current === grip { return gripShown ? .grip : nil }
                if current === ball || (fruit != nil && current === fruit) { return .thing(current) }
                if let resident = residents.first(where: { $0.holder === current }) { return .pet(resident) }
                node = current.parent
            }
        }
        return nil
    }

    private func press(at point: NSPoint) {
        switch thing(at: point) {
        case let .pet(resident): grabbed = .pet(resident, lift: 0.35 + resident.height * 0.15, carrying: false)
        case let .thing(node): grabbed = .thing(node)
        case .grip: grabbed = .resize(from: window.frame, mouse: NSEvent.mouseLocation)
        case nil:
            let origin = window.frame.origin, mouse = NSEvent.mouseLocation
            grabbed = .box(offset: NSPoint(x: mouse.x - origin.x, y: mouse.y - origin.y))
        }
        throwSamples = []
    }

    /// Where the mouse ray meets the level plane `height` metres above the floor.
    private func floorPoint(_ point: NSPoint, height: Double) -> (x: Double, z: Double)? {
        let near = view.unprojectPoint(SCNVector3(point.x, point.y, 0))
        let far = view.unprojectPoint(SCNVector3(point.x, point.y, 1))
        let dy = Double(far.y - near.y)
        guard abs(dy) > 1e-6 else { return nil }
        let t = (height - Double(near.y)) / dy
        guard t > 0 else { return nil }
        return (Double(near.x) + Double(far.x - near.x) * t, Double(near.z) + Double(far.z - near.z) * t)
    }

    private func drag(to point: NSPoint) {
        let now = CACurrentMediaTime()
        switch grabbed {
        case let .pet(resident, lift, carrying):
            if !carrying {
                if case .walk = resident.plan, resident.pet.engine.currentName == resident.walkName { resident.pet.engine.release() }
                resident.plan = .carried
                resident.holder.removeAllActions()
                resident.pet.engine.dragBegan()
                grabbed = .pet(resident, lift: lift, carrying: true)
            }
            guard let spot = floorPoint(point, height: lift) else { return }
            resident.place(at: clamp(spot, for: resident), height: lift)
            resident.syncCollider()
        case let .thing(node):
            guard let spot = floorPoint(point, height: 0.6) else { return }
            if node.physicsBody?.type != .kinematic {
                node.physicsBody?.type = .kinematic
                node.physicsBody?.velocity = SCNVector3Zero
                node.physicsBody?.angularVelocity = SCNVector4Zero
            }
            let x = min(max(spot.x, -width / 2 + 0.3), width / 2 - 0.3), z = min(max(spot.z, -depth / 2 + 0.3), depth / 2 - 0.3)
            node.position = SCNVector3(x, 0.6, z)
            throwSamples.append((node.position, now))
            throwSamples.removeAll { now - $0.time > 0.1 }
        case let .resize(from, start):
            leavePerch()
            // Grows down and to the right from the top-left corner, keeping the box's shape.
            let mouse = NSEvent.mouseLocation
            let change = max(mouse.x - start.x, (start.y - mouse.y) / Self.aspect)
            let width = max(Self.minWidth, from.width + change), height = width * Self.aspect
            window.setFrame(NSRect(x: from.minX, y: from.maxY - height, width: width, height: height), display: true)
            updateFrost()
        case let .box(offset):
            leavePerch()
            let mouse = NSEvent.mouseLocation
            var origin = NSPoint(x: mouse.x - offset.x, y: mouse.y - offset.y)
            // Up to the menu bar with the top of the box, not the empty space above it.
            if let top = walls.flatMap({ corners(of: $0) }).map(\.y).max(),
               let screen = NSScreen.screens.first(where: { $0.frame.minX <= mouse.x && mouse.x < $0.frame.maxX }) {
                origin.y = min(origin.y, screen.visibleFrame.maxY - top)
            }
            window.setFrameOrigin(origin)
        case nil:
            break
        }
    }

    private func release(dragged: Bool) {
        defer { grabbed = nil }
        guard dragged else { return }
        switch grabbed {
        case .box, .resize:
            snapToSurface()
        case let .pet(resident, lift, true):
            let fall = sqrt(2 * lift / 9.8)
            let drop = SCNAction.moveBy(x: 0, y: -lift, z: 0, duration: fall)
            drop.timingMode = .easeIn
            resident.holder.runAction(drop)
            resident.pet.engine.dragEnded()
            resident.rest(at: CACurrentMediaTime() + fall)
        case let .thing(node):
            guard let body = node.physicsBody else { return }
            body.type = .dynamic
            body.resetTransform()
            if let first = throwSamples.first, let last = throwSamples.last, last.time - first.time > 0.01 {
                let t = last.time - first.time
                var v = SCNVector3((last.position.x - first.position.x) / t, 1.5, (last.position.z - first.position.z) / t)
                let speed = hypot(Double(v.x), Double(v.z))
                if speed > 12 { v.x *= 12 / speed; v.z *= 12 / speed }
                body.velocity = v
            }
        default:
            break
        }
    }

    private func click(at point: NSPoint, double: Bool) {
        switch thing(at: point) {
        case let .pet(resident):
            if double { resident.pet.engine.doubleClick() } else { resident.pet.engine.click() }
        case let .thing(node):
            // A poke hops it up and off to one side.
            guard let body = node.physicsBody, body.type == .dynamic else { return }
            body.applyForce(SCNVector3(Double.random(in: -1...1) * body.mass, 3 * body.mass, Double.random(in: -1...1) * body.mass),
                            asImpulse: true)
        case .grip, nil:
            break
        }
    }
}

private enum Target {
    case spot((x: Double, z: Double))
    case ball, fruit
    case pet(Resident)
}

private enum Plan {
    case rest(until: TimeInterval)
    /// `walking` once the gait has started playing (it may wait for the last clip to finish).
    case walk(Target, gait: String, started: TimeInterval, walking: Bool)
    case eat(at: SCNVector3, until: TimeInterval)
    case chat(with: Resident, until: TimeInterval)
    case carried

    func walking() -> Plan {
        guard case let .walk(target, gait, started, _) = self else { return self }
        return .walk(target, gait: gait, started: started, walking: true)
    }
}

/// A pet living in the house: where it stands on the floor, which way it heads, and what it's up to.
@MainActor
private final class Resident {
    let pet: PetController
    /// Stands the pet's body on the floor, turned to its heading, at its real size.
    let holder = SCNNode()
    /// Lets the ball and fruit bump into the pet.
    let collider = SCNNode()
    /// Floor footprint and height, metres.
    let radius: Double
    let height: Double
    let canEat: Bool
    private(set) var spot: (x: Double, z: Double) = (0, 0)
    var plan = Plan.rest(until: 0)
    /// World heading the pet should face, degrees (0 toward the viewer, +90 to the right).
    var facing = 0.0
    private var heading = 0.0
    var lastKick: TimeInterval = 0
    var touchingFruit = false
    var gaitClip = ""

    init(pet: PetController) {
        self.pet = pet
        let catalog = pet.catalog
        let idle = catalog.clip(catalog.idleClip).bounds
        // Tails and wings stick out; the body proper is nearer the middle.
        radius = max(idle.horizontalRadius * 0.55 * catalog.meshScale, 0.15)
        height = max(idle.max[1] * catalog.meshScale, 0.3)
        canEat = catalog.clips["Eat"] != nil
        holder.scale = SCNVector3(catalog.meshScale, catalog.meshScale, catalog.meshScale)
        let shape = SCNPhysicsShape(geometry: SCNCylinder(radius: radius, height: height))
        collider.physicsBody = SCNPhysicsBody(type: .kinematic, shape: shape)
    }

    var walkName: String { "Walk (\(gaitClip))" }

    var isResting: Bool {
        if case .rest = plan { return pet.engine.currentName == pet.catalog.idleClip }
        return false
    }

    func place(at spot: (x: Double, z: Double), height: Double? = nil) {
        self.spot = spot
        holder.position = SCNVector3(spot.x, height ?? Double(holder.position.y), spot.z)
    }

    func syncCollider() {
        let p = holder.presentation.position
        collider.position = SCNVector3(p.x, p.y + height / 2, p.z)
    }

    /// Settles for a while, turned roughly toward the viewer.
    func rest(at now: TimeInterval) {
        plan = .rest(until: now + Double.random(in: 3...10))
        facing = Double.random(in: -50...50)
    }

    func forget(_ other: Resident) {
        switch plan {
        case let .chat(with, _) where with === other: rest(at: CACurrentMediaTime())
        case let .walk(.pet(target), _, _, _) where target === other: rest(at: CACurrentMediaTime())
        default: break
        }
    }

    /// A gait picked by the pack's weights, as on the desktop, leaving out any faster than
    /// the pet's main gait (its most likely one) that would cover the trip in under a
    /// second and a half. Never only the slow oddities (Sekhmet's swim) on a short trip.
    func gait(for distance: Double) -> String? {
        let catalog = pet.catalog
        let gaits = catalog.locomotion.filter { catalog.clip($0.clip).groundSpeed != nil }
        guard let main = gaits.max(by: { $0.weight < $1.weight }) else { return nil }
        let mainSpeed = catalog.clip(main.clip).groundSpeed!
        let unhurried = gaits.filter {
            let speed = catalog.clip($0.clip).groundSpeed!
            return speed <= mainSpeed || distance / (speed * catalog.meshScale) >= 1.5
        }
        return unhurried.pickWeighted() ?? main.clip
    }

    /// Eases the heading toward `facing`; the holder turns so that, whichever way the
    /// playing clip points the body, the pet as a whole faces `heading`.
    func turn(dt: Double) {
        let diff = remainder(facing - heading, 360)
        heading += diff * (1 - exp(-8 * dt))
        holder.eulerAngles.y = CGFloat((heading - pet.stage.rig.actor.yawDegrees) * .pi / 180)
    }
}

/// The house's SceneKit view: presses, drags (past a few points of jitter) and clicks,
/// with a double click never also firing a single.
final class HouseView: SCNView {
    var onPress: ((NSPoint) -> Void)?
    var onDrag: ((NSPoint) -> Void)?
    var onRelease: ((Bool) -> Void)?
    var onClick: ((NSPoint, Bool) -> Void)?
    var menuAt: ((NSPoint) -> NSMenu?)?
    private var downPoint: NSPoint = .zero
    private var dragging = false
    private var pendingClick: DispatchWorkItem?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func menu(for event: NSEvent) -> NSMenu? {
        menuAt?(convert(event.locationInWindow, from: nil))
    }

    override func mouseDown(with event: NSEvent) {
        downPoint = convert(event.locationInWindow, from: nil)
        dragging = false
        onPress?(downPoint)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if !dragging {
            guard hypot(point.x - downPoint.x, point.y - downPoint.y) > 4 else { return }
            dragging = true
            pendingClick?.cancel()
        }
        onDrag?(point)
    }

    override func mouseUp(with event: NSEvent) {
        onRelease?(dragging)
        defer { dragging = false }
        guard !dragging else { return }
        let point = downPoint
        if event.clickCount >= 2 {
            pendingClick?.cancel()
            pendingClick = nil
            onClick?(point, true)
        } else {
            let click = DispatchWorkItem { [weak self] in self?.onClick?(point, false) }
            pendingClick = click
            DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: click)
        }
    }
}

/// Blurs whatever is behind the window, inside a given shape. macOS's public blur
/// (NSVisualEffectView) always adds a heavy tint and a fixed, strong blur, so this uses
/// the private backdrop layer it's built on, with a light blur and no tint. If a future
/// macOS drops those classes, it shows nothing and the glass is simply clear.
final class FrostView: NSView {
    static let blurRadius = 4.0
    private let shape = CAShapeLayer()
    private let backdrop: CALayer?

    override init(frame: NSRect) {
        backdrop = Self.makeBackdrop()
        super.init(frame: frame)
        wantsLayer = true
        if let backdrop {
            backdrop.mask = shape
            layer?.addSublayer(backdrop)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private static func makeBackdrop() -> CALayer? {
        guard let backdropClass = NSClassFromString("CABackdropLayer") as? CALayer.Type,
              let filterClass = NSClassFromString("CAFilter") as? NSObject.Type,
              let blur = filterClass.perform(NSSelectorFromString("filterWithType:"), with: "gaussianBlur")?
                  .takeUnretainedValue() as? NSObject
        else { return nil }
        blur.setValue(blurRadius, forKey: "inputRadius")
        blur.setValue(true, forKey: "inputNormalizeEdges")
        let layer = backdropClass.init()
        layer.setValue(true, forKey: "windowServerAware")
        layer.filters = [blur]
        return layer
    }

    /// The area to blur, in this view's coordinates.
    func setShape(_ path: CGPath) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdrop?.frame = bounds
        shape.frame = bounds
        shape.path = path
        CATransaction.commit()
    }
}

/// AppKit keeps a window's top below the menu bar, but most of this window above the box
/// is empty, so that stopped the box well short of it. The house limits the box itself.
final class HouseWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

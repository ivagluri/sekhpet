import AppKit
import SceneKit
import SwiftUI

/// The Pet Viewer: a loadout-screen style window for looking at any installed pet up
/// close. Drag to orbit, scroll or pinch to zoom, tilt up and down; click and double-click
/// the pet as on the desktop, and play any of its animations from a tidy list. It loads
/// its own copy of the pet, so the desktop pets carry on undisturbed.

/// One line in the animation list: an animation, or a grouped one (start, loop, end) as a whole.
struct ViewerAnimation: Identifiable, Hashable {
    enum Section: String { case moves = "Moves", actions = "Actions", reactions = "Reactions" }
    let title: String
    let section: Section
    let entry: Catalog.PoolEntry

    var id: String { entry.name }

    static func == (a: Self, b: Self) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// The pet's animations without the parts of grouped ones, readably named, in sections.
    static func list(for catalog: Catalog) -> [ViewerAnimation] {
        var seen = Set<String>()
        var list: [ViewerAnimation] = []
        func add(_ entry: Catalog.PoolEntry, _ section: Section) {
            guard seen.insert(entry.name).inserted else { return }
            list.append(ViewerAnimation(title: title(entry.name), section: section, entry: entry))
        }
        add(.init(clip: catalog.idleClip, group: nil), .moves)
        for gait in catalog.locomotion { add(.init(clip: gait.clip, group: nil), .moves) }
        let actions = catalog.surprisePool.sorted { title($0.name) < title($1.name) }
        for entry in actions { add(entry, .actions) }
        let input = catalog.input
        var reactions = input.singleClick.map { Catalog.PoolEntry(clip: $0.clip, group: nil) }
        reactions += [input.doubleClick].compactMap { $0 }.map { Catalog.PoolEntry(clip: $0, group: nil) }
        reactions += [input.dragGroup, input.dropGroup].compactMap { $0 }.map { Catalog.PoolEntry(clip: nil, group: $0) }
        for entry in reactions { add(entry, .reactions) }
        return list
    }

    /// Game names that don't read well on their own.
    private static let names = [
        "CommonWork": "Work", "Encount": "Notice", "FarSkill": "Ranged Skill", "Architecture": "Build",
        "GetUp_BackDown": "Get Up (Back)", "GetUp_FrontDown": "Get Up (Front)", "SleepLoopTogether": "Sleep Together",
        "Idle_Swim": "Tread Water", "Walk_Swim": "Swim", "Run_Swim": "Swim Fast", "Transport": "Carry Load",
        "Spa": "Hot Spring", "Petting": "Petted", "Damage": "Hurt", "Carrying": "Picked Up", "Jump": "Jump",
    ]

    /// "RollingScratch" → "Rolling Scratch", "Rest01" → "Rest 1", "SideStep_Left" → "Side Step Left".
    static func title(_ raw: String) -> String {
        if let name = names[raw] { return name }
        var words: [String] = [], word = ""
        for ch in raw {
            if ch == "_" || ch == " " {
                if !word.isEmpty { words.append(word); word = "" }
            } else if let last = word.last,
                      (ch.isUppercase && !last.isUppercase) || (ch.isNumber != last.isNumber) {
                words.append(word)
                word = String(ch)
            } else {
                word.append(ch)
            }
        }
        if !word.isEmpty { words.append(word) }
        return words.map { Int($0).map(String.init) ?? $0 }.joined(separator: " ")
    }
}

/// The 3D side: the pet on a studio floor, an orbiting camera, and the pet's behavior.
@MainActor
final class ViewerStage {
    let view = ViewerSceneView(frame: .zero)
    private let scene = SCNScene()
    private let camera = SCNNode()
    private let floor = SCNNode()
    private let keyLight = SCNNode()
    private(set) var stage: PetStage?
    private(set) var engine: BehaviorEngine?
    private var target = SIMD3<Float>(0, 1, 0)
    private var radius: Float = 1
    /// How far up the point the camera turns around may slide: the pet's height.
    private var height: Float = 1
    private var lastFrame: TimeInterval?
    /// Slowly orbits the camera until the user grabs it.
    var turntable = true
    var onGrab: (() -> Void)?

    init() {
        let lens = SCNCamera()
        lens.fieldOfView = 30
        lens.zNear = 0.05
        lens.wantsHDR = false
        camera.camera = lens
        scene.rootNode.addChildNode(camera)

        // A soft white disc, fading out at its rim, to stand on and catch the shadow.
        let disc = SCNCylinder(radius: 1, height: 0.01)
        let material = SCNMaterial()
        material.lightingModel = .lambert
        material.diffuse.contents = Self.radialFade()
        disc.materials = [material, material, material]
        floor.geometry = disc
        floor.castsShadow = false
        scene.rootNode.addChildNode(floor)

        scene.lightingEnvironment.contents = NSColor(white: 0.7, alpha: 1)
        scene.lightingEnvironment.intensity = 1.5
        let key = SCNLight()
        key.type = .directional
        key.intensity = 1100
        key.castsShadow = true
        key.shadowColor = NSColor(white: 0, alpha: 0.4)
        key.shadowRadius = 3
        key.shadowSampleCount = 4
        key.shadowMapSize = CGSize(width: 2048, height: 2048)
        key.automaticallyAdjustsShadowProjection = true
        keyLight.light = key
        keyLight.eulerAngles = SCNVector3(-1.1, -0.45, 0)
        scene.rootNode.addChildNode(keyLight)
        let rim = SCNLight()
        rim.type = .directional
        rim.intensity = 450
        let rimNode = SCNNode()
        rimNode.light = rim
        rimNode.eulerAngles = SCNVector3(-0.3, 2.6, 0)
        scene.rootNode.addChildNode(rimNode)

        view.scene = scene
        view.pointOfView = camera
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 60
        view.rendersContinuously = true
        view.allowsCameraControl = true
        view.cameraControlConfiguration.allowsTranslation = false
        view.cameraControlConfiguration.autoSwitchToFreeCamera = false
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.defaultCameraController.inertiaEnabled = true
        // Tilt from just under the floor to looking down from above.
        view.defaultCameraController.minimumVerticalAngle = -10
        view.defaultCameraController.maximumVerticalAngle = 80
        view.isPlaying = true
        view.onGrab = { [unowned self] in onGrab?() }
        view.onZoom = { [unowned self] in zoom(by: Float($0)) }
        view.onPan = { [unowned self] in pan(by: Float($0)) }
        view.onClick = { [unowned self] point, double in click(at: point, double: double) }
    }

    /// Shows `pack`, replacing whatever pet was there.
    func load(_ pack: PetPack) throws {
        unload()
        let catalog = try Catalog.load(from: pack.directory)
        let stage = try PetStage(assets: pack.directory, catalog: catalog)
        stage.rig.animations.preload(catalog.playableClips)
        let body = stage.rig.actor.node
        body.removeFromParentNode()
        scene.rootNode.addChildNode(body)
        stage.rig.motion.isPinned = true
        let engine = BehaviorEngine(rig: stage.rig, clock: CACurrentMediaTime)
        engine.surpriseInterval = nil
        engine.watch = .never
        engine.tick()
        self.stage = stage
        self.engine = engine
        frame(catalog)
    }

    func unload() {
        stage?.rig.actor.node.removeFromParentNode()
        stage = nil
        engine = nil
    }

    /// Frames the camera on the pet's idle pose, a little above and in front.
    private func frame(_ catalog: Catalog) {
        let bounds = catalog.clip(catalog.idleClip).bounds
        height = Float(bounds.max[1])
        radius = max(Float(bounds.horizontalRadius), height / 2, 0.2)
        target = SIMD3(0, height * 0.45, 0)
        let span = max(Float(bounds.horizontalRadius) * 1.1, height * 0.45)
        floor.simdScale = SIMD3(span, 1, span)
        floor.simdPosition = SIMD3(0, -0.005, 0)
        keyLight.light?.orthographicScale = CGFloat(span * 2)

        let lens = camera.camera!
        let fov = Float(lens.fieldOfView) * .pi / 180
        let distance = radius / sin(fov / 2) * 1.6
        // Clip planes from the pet's size: the default far plane (100 m) cut Panthalus off.
        lens.zNear = Double(max(0.02, radius * 0.01))
        lens.zFar = Double(radius * 12)
        view.defaultCameraController.stopInertia()
        let tilt: Float = 12 * .pi / 180
        camera.simdPosition = target + SIMD3(0, sin(tilt), cos(tilt)) * distance
        camera.simdLook(at: target)
        view.defaultCameraController.target = SCNVector3(target)
    }

    func frame(at now: TimeInterval) {
        let dt = Float(min(now - (lastFrame ?? now), 0.1))
        lastFrame = now
        guard let stage, let engine else { return }
        engine.tick()
        stage.rig.motion.update(at: now)
        stage.rig.look.update(cursor: nil, at: now)

        var offset = camera.simdPosition - target
        if turntable {
            let angle = dt * 0.35
            offset = SIMD3(offset.x * cos(angle) + offset.z * sin(angle), offset.y, -offset.x * sin(angle) + offset.z * cos(angle))
        }
        // Zoom stays between close up and the whole pet small in the middle.
        let length = simd_length(offset)
        let clamped = min(max(length, radius * 1.1), radius * 9)
        camera.simdPosition = target + offset / length * clamped
        // Upright and on the pet every frame: the camera control can leave a roll behind.
        camera.simdLook(at: target, up: SIMD3(0, 1, 0), localFront: SCNNode.simdLocalFront)
    }

    /// Slides the camera and the point it turns around up or down by `points` on screen,
    /// between the floor and the top of the pet.
    private func pan(by points: Float) {
        let lens = camera.camera!
        let distance = simd_length(camera.simdPosition - target)
        let metresPerPoint = 2 * distance * tan(Float(lens.fieldOfView) * .pi / 360) / max(Float(view.bounds.height), 1)
        let y = min(max(target.y - points * metresPerPoint, 0), height)
        let shift = SIMD3<Float>(0, y - target.y, 0)
        target += shift
        camera.simdPosition += shift
        view.defaultCameraController.target = SCNVector3(target)
    }

    /// Moves the camera toward (factor below 1) or away from the pet, within the zoom limits.
    private func zoom(by factor: Float) {
        let offset = camera.simdPosition - target
        let length = simd_length(offset)
        let zoomed = min(max(length * factor, radius * 1.1), radius * 9)
        camera.simdPosition = target + offset / length * zoomed
    }

    private func click(at point: NSPoint, double: Bool) {
        guard let body = stage?.rig.actor.node, let engine else { return }
        let hit = view.hitTest(point, options: [.searchMode: SCNHitTestSearchMode.all.rawValue]).contains { result in
            var node: SCNNode? = result.node
            while let current = node {
                if current === body { return true }
                node = current.parent
            }
            return false
        }
        guard hit else { return }
        if double { engine.doubleClick() } else { engine.click() }
    }

    private static func radialFade() -> NSImage {
        NSImage(size: NSSize(width: 256, height: 256), flipped: false) { rect in
            let gradient = NSGradient(colorsAndLocations:
                (NSColor(white: 0.5, alpha: 0.7), 0), (NSColor(white: 0.42, alpha: 0.45), 0.6), (NSColor(white: 0.35, alpha: 0), 1))
            gradient?.draw(in: NSBezierPath(ovalIn: rect), relativeCenterPosition: .zero)
            return true
        }
    }
}

/// The scene view with camera control, plus clicks on the pet (a press that didn't
/// turn into a drag) and a heads-up when the camera is grabbed.
final class ViewerSceneView: SCNView {
    var onClick: ((NSPoint, Bool) -> Void)?
    var onGrab: (() -> Void)?
    private var downPoint: NSPoint = .zero
    private var dragged = false
    private var pendingClick: DispatchWorkItem?

    override func mouseDown(with event: NSEvent) {
        downPoint = convert(event.locationInWindow, from: nil)
        dragged = false
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if !dragged, hypot(point.x - downPoint.x, point.y - downPoint.y) > 4 {
            dragged = true
            pendingClick?.cancel()
            onGrab?()
        }
        super.mouseDragged(with: event)
    }

    /// Scrolling and pinching zoom in and out (the built-in camera control doesn't).
    var onZoom: ((Double) -> Void)?
    /// Middle-button drags slide the view up and down, in points (up is positive).
    var onPan: ((Double) -> Void)?
    private var panFrom: NSPoint?

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return super.otherMouseDown(with: event) }
        panFrom = convert(event.locationInWindow, from: nil)
        onGrab?()
    }

    override func otherMouseDragged(with event: NSEvent) {
        guard let from = panFrom else { return super.otherMouseDragged(with: event) }
        let point = convert(event.locationInWindow, from: nil)
        onPan?(Double(point.y - from.y))
        panFrom = point
    }

    override func otherMouseUp(with event: NSEvent) {
        guard panFrom != nil else { return super.otherMouseUp(with: event) }
        panFrom = nil
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 10
        onZoom?(exp(-Double(delta) * 0.01))
    }

    override func magnify(with event: NSEvent) {
        onZoom?(exp(-Double(event.magnification)))
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        guard !dragged else { return }
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

@MainActor
@Observable
final class PetViewerModel {
    private(set) var packs: [PetPack] = []
    private(set) var selected: PetPack?
    private(set) var animations: [ViewerAnimation] = []
    private(set) var playing: ViewerAnimation?
    private(set) var info: [(label: String, value: String)] = []
    private(set) var failure: String?
    var loop = false {
        didSet { applyLoop() }
    }
    var turntable = true {
        didSet { stage.turntable = turntable }
    }
    @ObservationIgnored let stage = ViewerStage()
    @ObservationIgnored private var playStarted: TimeInterval = 0

    static let lastPetKey = "viewerPet"

    init() {
        stage.onGrab = { [unowned self] in if turntable { turntable = false } }
    }

    func update(packs: [PetPack]) {
        // In paldeck order, variants after their base pal; pets without a number last.
        self.packs = packs.sorted { a, b in
            switch (a.paldeckNo, b.paldeckNo) {
            case let (x?, y?): x.localizedStandardCompare(y) == .orderedAscending
            case (_?, nil): true
            case (nil, _?): false
            case (nil, nil): a.displayName < b.displayName
            }
        }
        if selected == nil || !packs.contains(where: { $0.name == selected?.name }) {
            let last = UserDefaults.standard.string(forKey: Self.lastPetKey)
            if let pack = packs.first(where: { $0.name == last }) ?? packs.first { select(pack) }
        }
    }

    func select(_ pack: PetPack) {
        guard pack.name != selected?.name || stage.stage == nil else { return }
        do {
            try stage.load(pack)
            selected = pack
            failure = nil
            UserDefaults.standard.set(pack.name, forKey: Self.lastPetKey)
        } catch {
            failure = "Couldn't load \(pack.displayName): \(error.localizedDescription)"
            return
        }
        guard let catalog = stage.stage?.rig.catalog else { return }
        animations = ViewerAnimation.list(for: catalog)
        playing = nil
        loop = false
        info = Self.info(for: catalog, animations: animations.count)
    }

    func play(_ animation: ViewerAnimation) {
        guard let engine = stage.engine else { return }
        playing = animation
        playStarted = CACurrentMediaTime()
        if loop { engine.setMode(.loop) }
        engine.playNow(animation.entry)
    }

    private func applyLoop() {
        guard let engine = stage.engine else { return }
        if loop, let playing {
            engine.setMode(.loop)
            engine.playNow(playing.entry)
        } else if !loop, engine.mode == .loop {
            engine.setMode(.random)
            playing = nil
        }
    }

    func frame(at now: TimeInterval) {
        stage.frame(at: now)
        // Played once and back to idle: nothing is highlighted any more.
        if !loop, playing != nil, now - playStarted > 0.5, let engine = stage.engine,
           engine.currentName == stage.stage?.rig.catalog.idleClip, playing?.entry.clip != engine.currentName {
            playing = nil
        }
    }

    func unload() {
        stage.unload()
        selected = nil
    }

    private static func info(for catalog: Catalog, animations: Int) -> [(label: String, value: String)] {
        let height = catalog.clip(catalog.idleClip).bounds.max[1]
        var rows: [(String, String)] = [("Height", String(format: "%.2f m", height))]
        if catalog.meshScale < 0.999 {
            rows.append(("On the desktop", String(format: "%.2f m", height * catalog.meshScale)))
        }
        rows.append(("Animations", "\(animations)"))
        let gaits = catalog.locomotion.compactMap { gait in
            catalog.clip(gait.clip).groundSpeed.map { (ViewerAnimation.title(gait.clip), $0) }
        }
        if let top = gaits.max(by: { $0.1 < $1.1 }) {
            rows.append(("Top speed", String(format: "%.1f m/s (%@)", top.1, top.0)))
        }
        return rows
    }
}

// MARK: Views

private enum Palette {
    static let panel = Color.white.opacity(0.06)
    static let line = Color.white.opacity(0.08)
    static let text = Color.white.opacity(0.92)
    static let dim = Color.white.opacity(0.5)
    static let accent = Color.accentColor
}

struct PetViewerView: View {
    @Bindable var model: PetViewerModel

    var body: some View {
        HStack(spacing: 0) {
            petList
                .frame(width: 200)
            ZStack {
                ViewerSceneRepresentable(view: model.stage.view)
                VStack {
                    HStack {
                        Spacer()
                        Pill(title: "Turntable", systemImage: "arrow.trianglehead.2.clockwise.rotate.90", on: model.turntable) {
                            model.turntable.toggle()
                        }
                    }
                    Spacer()
                    Text("Drag to turn and tilt · scroll or pinch to zoom · middle-drag to move up and down · click or double-click the pet")
                        .font(.caption).foregroundStyle(Palette.dim)
                }
                .padding(14)
                if let failure = model.failure {
                    Text(failure).font(.callout).foregroundStyle(Palette.text)
                        .padding(12).background(Palette.panel, in: RoundedRectangle(cornerRadius: 10))
                }
            }
            sidePanel
                .frame(width: 260)
        }
        .background(
            LinearGradient(colors: [Color(white: 0.16), Color(white: 0.09)], startPoint: .top, endPoint: .bottom)
        )
        .environment(\.colorScheme, .dark)
        .frame(minWidth: 860, minHeight: 540)
    }

    private var petList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("PETS").font(.caption.weight(.semibold)).tracking(1.5).foregroundStyle(Palette.dim)
            ScrollBox(items: model.packs, rowHeight: 46) { pack in
                PetRow(pack: pack, selected: pack.name == model.selected?.name)
                    .onTapGesture { model.select(pack) }
            }
            // Ahead of the spacer: the list takes the height first.
            .layoutPriority(1)
            Spacer(minLength: 0)
        }
        .padding(.top, 8)
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .background(Palette.panel)
    }

    private var sidePanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let pack = model.selected {
                VStack(alignment: .leading, spacing: 8) {
                    Text(pack.displayName).font(.title2.weight(.semibold)).foregroundStyle(Palette.text)
                    Text((pack.paldeckNo.map { "No. \($0) · " } ?? "") + pack.name)
                        .font(.caption.monospaced()).foregroundStyle(Palette.dim)
                    Rectangle().fill(Palette.line).frame(height: 1).padding(.vertical, 2)
                    ForEach(model.info, id: \.label) { row in
                        HStack {
                            Text(row.label).foregroundStyle(Palette.dim)
                            Spacer()
                            Text(row.value).foregroundStyle(Palette.text)
                        }
                        .font(.callout)
                    }
                }
                .padding(14)
                .background(Palette.panel, in: RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("ANIMATIONS").font(.caption.weight(.semibold)).tracking(1.5).foregroundStyle(Palette.dim)
                        Spacer()
                        Pill(title: "Loop", systemImage: "repeat", on: model.loop) { model.loop.toggle() }
                    }
                    ScrollBox(items: model.animations, rowHeight: 30) { animation in
                        AnimationRow(animation: animation, playing: animation == model.playing,
                                     firstInSection: model.animations.first { $0.section == animation.section } == animation)
                            .onTapGesture { model.play(animation) }
                    }
                }
                .padding(14)
                .background(Palette.panel, in: RoundedRectangle(cornerRadius: 12))
                .layoutPriority(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 8)
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }
}

private struct PetRow: View {
    let pack: PetPack
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let image = pack.thumbnail {
                    Image(nsImage: image).resizable().interpolation(.high)
                } else {
                    Image(systemName: "pawprint.fill").foregroundStyle(Palette.dim)
                }
            }
            .frame(width: 34, height: 34)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 1) {
                Text(pack.displayName).font(.callout.weight(selected ? .semibold : .regular)).foregroundStyle(Palette.text)
                Text(pack.paldeckNo.map { "No. \($0)" } ?? "No. —").font(.caption2.monospaced()).foregroundStyle(Palette.dim)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .frame(maxHeight: .infinity)
        .background(selected ? Palette.accent.opacity(0.28) : .clear, in: RoundedRectangle(cornerRadius: 9))
        .contentShape(Rectangle())
    }
}

private struct AnimationRow: View {
    let animation: ViewerAnimation
    let playing: Bool
    let firstInSection: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: playing ? "play.fill" : "circle.fill")
                .font(.system(size: playing ? 9 : 4))
                .frame(width: 12)
                .foregroundStyle(playing ? Palette.accent : Palette.dim)
            Text(animation.title).font(.callout).foregroundStyle(Palette.text)
            Spacer(minLength: 0)
            if firstInSection {
                Text(animation.section.rawValue.uppercased()).font(.system(size: 9, weight: .semibold)).tracking(1)
                    .foregroundStyle(Palette.dim)
            }
        }
        .padding(.horizontal, 6)
        .frame(maxHeight: .infinity)
        .background(playing ? Palette.accent.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
    }
}

/// A small rounded toggle button.
private struct Pill: View {
    let title: String
    let systemImage: String
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .foregroundStyle(on ? Color.white : Palette.dim)
                .background(on ? Palette.accent.opacity(0.55) : Color.white.opacity(0.08), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// A list that fills the height it's given (no more than its rows need), with a thin
/// position bar and small arrows that page through it instead of the system scroller.
private struct ScrollBox<Item: Identifiable, Row: View>: View {
    let items: [Item]
    let rowHeight: CGFloat
    @ViewBuilder let row: (Item) -> Row
    @State private var top: Item.ID?
    @State private var progress: CGFloat = 0
    /// How much of the list shows: the visible height over the whole list's.
    @State private var shown: CGFloat = 1

    private var step: CGFloat { rowHeight + 2 }
    private var visibleRows: Int { max(1, Int(CGFloat(items.count) * shown)) }

    var body: some View {
        HStack(spacing: 6) {
            ScrollView(.vertical) {
                LazyVStack(spacing: 2) {
                    ForEach(items) { item in
                        row(item).frame(height: rowHeight).id(item.id)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollIndicators(.never)
            .contentMargins(0, for: .scrollContent)
            .scrollPosition(id: $top, anchor: .top)
            .onScrollGeometryChange(for: [CGFloat].self) { geometry in
                let range = geometry.contentSize.height - geometry.containerSize.height
                let shown = geometry.contentSize.height > 0 ? min(geometry.containerSize.height / geometry.contentSize.height, 1) : 1
                return [range > 0 ? min(max(geometry.contentOffset.y / range, 0), 1) : 0, shown]
            } action: { _, value in
                progress = value[0]
                shown = value[1]
            }
            if shown < 0.999 {
                VStack(spacing: 4) {
                    arrow("chevron.up", enabled: progress > 0.01) { page(-1) }
                    GeometryReader { geometry in
                        let thumb = max(16, geometry.size.height * shown)
                        ZStack(alignment: .top) {
                            Capsule().fill(Palette.line)
                            Capsule().fill(Palette.dim.opacity(0.7))
                                .frame(height: thumb)
                                .offset(y: (geometry.size.height - thumb) * progress)
                        }
                    }
                    .frame(width: 3)
                    arrow("chevron.down", enabled: progress < 0.99) { page(1) }
                }
                .frame(width: 12)
            }
        }
        // Never taller than the rows: the bar's track would otherwise stretch it.
        .frame(maxHeight: step * CGFloat(max(items.count, 1)))
    }

    private func arrow(_ name: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 9, weight: .bold))
                .frame(width: 12, height: 12)
                .foregroundStyle(enabled ? Palette.text : Palette.line)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    /// Moves a page less one row, so the row at the edge stays in view.
    private func page(_ direction: Int) {
        let current = items.firstIndex { $0.id == top } ?? 0
        let index = min(max(current + direction * max(visibleRows - 1, 1), 0), max(items.count - visibleRows, 0))
        withAnimation(.easeOut(duration: 0.25)) { top = items[index].id }
    }
}

private struct ViewerSceneRepresentable: NSViewRepresentable {
    let view: ViewerSceneView
    func makeNSView(context: Context) -> ViewerSceneView { view }
    func updateNSView(_ nsView: ViewerSceneView, context: Context) {}
}

/// The viewer's window: an ordinary one whose title bar blends into the content.
/// Closing it frees the pet it was showing.
@MainActor
final class PetViewerWindow: NSObject, NSWindowDelegate {
    let model = PetViewerModel()
    private let window: NSWindow

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 640),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        super.init()
        window.title = "Pet Viewer"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // The title bar takes the top of the backdrop's colour. Content drawn under it
        // instead (a full-size content view) makes AppKit pad every scroll view.
        window.backgroundColor = NSColor(white: 0.16, alpha: 1)
        window.isMovableByWindowBackground = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: PetViewerView(model: model))
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("PetViewer")
    }

    var isVisible: Bool { window.isVisible && window.occlusionState.contains(.visible) }

    func show(packs: [PetPack]) {
        model.update(packs: packs)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func frame(at now: TimeInterval) {
        guard isVisible else { return }
        model.frame(at: now)
    }

    func windowWillClose(_ notification: Notification) { model.unload() }
}

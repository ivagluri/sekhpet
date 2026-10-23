import AppKit
import SceneKit

/// The facade behaviors drive: plays a clip, turns the body to suit it, and
/// starts whatever on-screen movement the clip implies.
@MainActor
final class PetRig {
    let catalog: Catalog
    let animations: AnimationController
    let actor: PetActor
    let motion: PetMotion
    let look: PetLook

    init(catalog: Catalog, animations: AnimationController, actor: PetActor) {
        self.catalog = catalog
        self.animations = animations
        self.actor = actor
        motion = PetMotion(actor: actor)
        look = PetLook(actor: actor, boneNames: catalog.lookBones)
    }

    /// Model metres from the pet's centre to the screen-side tip of its body while
    /// `name` plays, at the nearest depth: side to side for front-facing clips, and
    /// nose or tail as well for turned ones. Travel stops this far from a screen
    /// edge, so the whole body stays on screen whatever the pal's size.
    func edgeMargin(for name: String) -> Double {
        let clip = catalog.clip(name), b = clip.bounds
        var reach = max(abs(b.min[0]), abs(b.max[0]))
        if clip.facing != .front { reach = max(reach, abs(b.min[2]), abs(b.max[2])) }
        return reach * PetActor.scale(forDepth: PetActor.depthRange.lowerBound)
    }

    func play(_ step: Step, side: Double, at now: TimeInterval) {
        let clip = catalog.clip(step.clip)
        animations.play(step.clip, loop: step.loops != 1, fade: clip.fadeIn)
        let turn = max(clip.fadeIn, 0.25)
        motion.margin = edgeMargin(for: step.clip)
        if let travel = step.travel {
            actor.face(yawDegrees: motion.headingDegrees(dx: travel.dx, depthTo: travel.depthTo), over: turn)
            motion.beginTravel(dx: travel.dx, depthTo: travel.depthTo, speed: travel.speed)
            return
        }
        actor.face(clip.facing, yawDegrees: clip.yawDegrees, side: side, over: turn)
        if let root = clip.rootTravel, root.scale != 0 {
            motion.beginRoot(root, yawDegrees: actor.yawDegrees, at: now)
        } else {
            motion.cancel()
        }
    }

    /// The side (+1 right, -1 left) that gives a root-travel clip the most room;
    /// random for clips that stay in place.
    func preferredSide(for name: String) -> Double {
        guard let spare = spareRoom(for: name) else { return Bool.random() ? 1 : -1 }
        return spare(1) >= spare(-1) ? 1 : -1
    }

    /// Whether a clip that travels on screen can complete its path from here.
    func hasRoom(for name: String) -> Bool {
        guard let spare = spareRoom(for: name) else { return true }
        return max(spare(1), spare(-1)) >= 0
    }

    private func spareRoom(for name: String) -> ((Double) -> Double)? {
        let clip = catalog.clip(name)
        guard !motion.isPinned, let root = clip.rootTravel, root.scale != 0, clip.facing == .directional else { return nil }
        let room = motion.room()
        let margin = edgeMargin(for: name)
        return { side in
            let dx = PetMotion.sidewaysTravel(root, yawDegrees: clip.yawDegrees * side)
            return (dx < 0 ? room.left : room.right) - margin - abs(dx)
        }
    }
}

/// Builds the SceneKit scene: model, camera, lights, and the stage rectangle the
/// window must cover so every clip in play fits without clipping.
@MainActor
final class PetStage {
    static let padding = 0.06

    let scene: SCNScene
    let camera: SCNNode
    let rig: PetRig
    /// Stage rectangle in metres (x: left/right, y: floor up).
    let bounds: CGRect

    init(assets: URL, catalog: Catalog) throws {
        let model = try SCNScene(url: assets.appendingPathComponent(catalog.model), options: nil)
        guard let skeleton = model.rootNode.childNode(withName: catalog.skeletonNode, recursively: true) else {
            throw CocoaError(.fileReadCorruptFile)
        }

        scene = SCNScene()
        scene.background.contents = NSColor.clear
        let body = SCNNode()
        for child in model.rootNode.childNodes { body.addChildNode(child) }
        let actor = PetActor(model: body)
        scene.rootNode.addChildNode(actor.node)

        let animations = AnimationController(catalog: catalog, assets: assets, skeleton: skeleton)
        rig = PetRig(catalog: catalog, animations: animations, actor: actor)

        bounds = Self.stageBounds(catalog: catalog, clips: catalog.playableClips)
        camera = Self.makeCamera(bounds: bounds, reach: Self.reach(catalog: catalog, clips: catalog.playableClips))
        scene.rootNode.addChildNode(camera)
        Self.addLights(to: scene)
    }

    /// Union of the clips' extents, allowing for directional turns and depth scaling.
    static func stageBounds(catalog: Catalog, clips: [String]) -> CGRect {
        var minX = 0.0, maxX = 0.0, minY = 0.0, maxY = 0.0
        let maxScale = PetActor.scale(forDepth: PetActor.depthRange.lowerBound)
        for name in clips {
            let clip = catalog.clip(name), b = clip.bounds
            let left = clip.facing == .front ? b.min[0] : -b.horizontalRadius
            let right = clip.facing == .front ? b.max[0] : b.horizontalRadius
            minX = min(minX, left * maxScale)
            maxX = max(maxX, right * maxScale)
            minY = min(minY, b.min[1] * maxScale)
            maxY = max(maxY, b.max[1] * maxScale + PetActor.depthRise)
        }
        // Keep the stage symmetric so turning left or right never needs a window move.
        let half = max(-minX, maxX) * (1 + padding)
        let height = (maxY - minY) * (1 + padding)
        return CGRect(x: -half, y: minY - (maxY - minY) * padding / 2, width: half * 2, height: height)
    }

    /// How far any clip reaches from the pet's centre in any direction, at the
    /// nearest depth: what the camera must see in front of and behind the pet.
    static func reach(catalog: Catalog, clips: [String]) -> Double {
        let maxScale = PetActor.scale(forDepth: PetActor.depthRange.lowerBound)
        let radius = clips.map { name in
            let b = catalog.clip(name).bounds
            return max(b.horizontalRadius, abs(b.min[2]), abs(b.max[2]))
        }.max() ?? 0
        return radius * maxScale + PetActor.depthZ
    }

    /// Orthographic, so distance doesn't change the framing; it sits far enough
    /// back that long bodies (Panthalus is 50 m nose to tail) aren't clipped.
    private static func makeCamera(bounds: CGRect, reach: Double) -> SCNNode {
        let distance = max(15, reach + 1)
        let camera = SCNCamera()
        camera.usesOrthographicProjection = true
        camera.orthographicScale = bounds.height / 2
        camera.zNear = 0.1
        camera.zFar = distance + max(25, reach + 1)
        let node = SCNNode()
        node.name = "PetCamera"
        node.camera = camera
        node.position = SCNVector3(bounds.midX, bounds.midY, distance)
        return node
    }

    private static func addLights(to scene: SCNScene) {
        // A plain grey environment gives the PBR materials soft, even fill;
        // the key light adds shape from the upper left.
        scene.lightingEnvironment.contents = NSColor(white: 0.7, alpha: 1)
        scene.lightingEnvironment.intensity = 1.5

        let key = SCNLight()
        key.type = .directional
        key.intensity = 1100
        let keyNode = SCNNode()
        keyNode.light = key
        keyNode.eulerAngles = SCNVector3(-0.55, -0.45, 0)
        scene.rootNode.addChildNode(keyNode)

        let rim = SCNLight()
        rim.type = .directional
        rim.intensity = 450
        let rimNode = SCNNode()
        rimNode.light = rim
        rimNode.eulerAngles = SCNVector3(-0.3, 2.6, 0)
        scene.rootNode.addChildNode(rimNode)
    }
}

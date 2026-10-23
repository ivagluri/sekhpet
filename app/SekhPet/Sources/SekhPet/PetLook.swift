import SceneKit

/// Turns the pet's neck and head toward the cursor on top of whatever animation
/// is playing. Each bone gets a world-space transform constraint that rotates its
/// animated pose about the bone's own pivot, so it works whatever axes the rig's
/// bones use. Angles are clamped and eased, and the effect fades in and out.
@MainActor
final class PetLook {
    /// Body-relative limits, radians.
    static let maxYaw = 50.0 * .pi / 180
    static let minPitch = -25.0 * .pi / 180
    static let maxPitch = 30.0 * .pi / 180
    /// How far in front of the pet the cursor is imagined to be, metres.
    static let cursorDistance = 2.0

    private let actor: PetActor
    private let head: SCNNode?
    private let state = LookState()
    private var constraints: [SCNTransformConstraint] = []
    private var influence = 0.0
    private var yaw = 0.0
    private var pitch = 0.0
    private var lastUpdate: TimeInterval?

    /// Whether the pet should be watching; the effect eases toward this.
    var isWatching = false

    init(actor: PetActor, boneNames: [String]?) {
        self.actor = actor
        let root = actor.node
        let names = boneNames ?? [["neck_01", "neck", "Neck"].first { root.childNode(withName: $0, recursively: true) != nil },
                                  "head"].compactMap { $0 }
        let bones = names.compactMap { root.childNode(withName: $0, recursively: true) }
        head = bones.last
        // The head takes the larger share; a lone head bone takes all of it.
        let shares = bones.count > 1 ? [0.4] + Array(repeating: 0.6 / Double(bones.count - 1), count: bones.count - 1) : [1.0]
        for (bone, share) in zip(bones, shares) {
            let constraint = Self.makeConstraint(state: state, share: share)
            constraint.influenceFactor = 0
            bone.constraints = (bone.constraints ?? []) + [constraint]
            constraints.append(constraint)
        }
    }

    var isAvailable: Bool { head != nil }

    /// SceneKit calls the block on its render thread, so it must not inherit the
    /// main-actor isolation of `init` (Swift would trap on the executor check).
    private nonisolated static func makeConstraint(state: LookState, share: Double) -> SCNTransformConstraint {
        SCNTransformConstraint(inWorldSpace: true) { @Sendable _, transform in
            state.rotate(transform, share: share)
        }
    }

    /// `cursor` is the pointer in scene coordinates (metres), or nil when unknown.
    func update(cursor: CGPoint?, at now: TimeInterval) {
        let dt = min(now - (lastUpdate ?? now), 0.1)
        lastUpdate = now
        guard let head else { return }

        var targetYaw = 0.0, targetPitch = 0.0
        if let cursor {
            let h = head.presentation.worldPosition
            let dx = Double(cursor.x) - Double(h.x)
            let dy = Double(cursor.y) - Double(h.y)
            let worldYaw = atan2(dx, Self.cursorDistance)
            let bodyYaw = actor.yawDegrees * .pi / 180
            targetYaw = max(-Self.maxYaw, min(Self.maxYaw, remainder(worldYaw - bodyYaw, 2 * .pi)))
            targetPitch = max(Self.minPitch, min(Self.maxPitch, atan2(dy, hypot(dx, Self.cursorDistance))))
        }
        // Ease the angles and the fade so the head never snaps.
        let follow = 1 - exp(-8 * dt)
        yaw += (targetYaw - yaw) * follow
        pitch += (targetPitch - pitch) * follow
        let fade = 1 - exp(-3 * dt)
        influence += ((isWatching && cursor != nil ? 1 : 0) - influence) * fade
        if influence < 0.001 { influence = 0 }

        state.set(yaw: yaw, pitch: pitch, bodyYaw: actor.yawDegrees * .pi / 180)
        for constraint in constraints { constraint.influenceFactor = CGFloat(influence) }
    }
}

/// The current look angles, shared with SceneKit's render thread.
private final class LookState: @unchecked Sendable {
    private let lock = NSLock()
    private var yaw = 0.0
    private var pitch = 0.0
    private var bodyYaw = 0.0

    func set(yaw: Double, pitch: Double, bodyYaw: Double) {
        lock.lock()
        defer { lock.unlock() }
        self.yaw = yaw
        self.pitch = pitch
        self.bodyYaw = bodyYaw
    }

    /// Rotates a bone's world transform about its own position: yaw about world up,
    /// then pitch about the body's sideways axis.
    func rotate(_ transform: SCNMatrix4, share: Double) -> SCNMatrix4 {
        lock.lock()
        let yaw = self.yaw * share, pitch = self.pitch * share, body = bodyYaw
        lock.unlock()
        let facing = body + yaw
        // Rotating the facing direction about this axis tilts it upward.
        let side = SCNVector3(-cos(facing), 0, sin(facing))
        let pivot = SCNVector3(transform.m41, transform.m42, transform.m43)
        var rotation = SCNMatrix4MakeRotation(CGFloat(yaw), 0, 1, 0)
        rotation = SCNMatrix4Mult(rotation, SCNMatrix4MakeRotation(CGFloat(pitch), side.x, side.y, side.z))
        let toOrigin = SCNMatrix4MakeTranslation(-pivot.x, -pivot.y, -pivot.z)
        let back = SCNMatrix4MakeTranslation(pivot.x, pivot.y, pivot.z)
        // SceneKit composes row-vector style: transform, then move to origin, rotate, move back.
        return SCNMatrix4Mult(SCNMatrix4Mult(SCNMatrix4Mult(transform, toOrigin), rotation), back)
    }
}

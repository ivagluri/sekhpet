import SceneKit

/// The pet's body in the stage: which way it faces and how far "into" the screen it stands.
/// The camera is orthographic, so depth reads as a small scale change and a slight rise.
@MainActor
final class PetActor {
    /// Depth runs from -1 (nearest the viewer) to 1 (furthest back).
    static let depthRange: ClosedRange<Double> = -1...1
    static let depthScale = 0.12
    static let depthRise = 0.15
    static let depthZ = 0.3

    let node: SCNNode
    private(set) var yawDegrees: Double = 0
    private(set) var depth: Double = 0

    init(model: SCNNode) {
        node = SCNNode()
        node.name = "PetActor"
        node.addChildNode(model)
    }

    static func scale(forDepth depth: Double) -> Double { 1 - depth * depthScale }

    /// Front-facing clips look at the camera; everything else turns to a
    /// three-quarter or side view on `side` (+1 = screen right, -1 = screen left).
    func face(_ facing: Catalog.Facing, yawDegrees clipYaw: Double, side: Double, over duration: TimeInterval) {
        face(yawDegrees: facing == .front ? 0 : clipYaw * side, over: duration)
    }

    /// Turns to an explicit heading (0 faces the viewer, +90 faces screen right).
    func face(yawDegrees target: Double, over duration: TimeInterval) {
        guard target != yawDegrees else { return }
        yawDegrees = target
        animate(duration) { self.node.eulerAngles.y = CGFloat(target * .pi / 180) }
    }

    func setDepth(_ value: Double, over duration: TimeInterval) {
        depth = min(max(value, Self.depthRange.lowerBound), Self.depthRange.upperBound)
        let scale = CGFloat(Self.scale(forDepth: depth))
        animate(duration) {
            self.node.scale = SCNVector3(scale, scale, scale)
            self.node.position.y = CGFloat(self.depth * Self.depthRise)
            self.node.position.z = CGFloat(-self.depth * Self.depthZ)
        }
    }

    /// Offscreen snapshots run on a virtual clock that implicit animations don't follow.
    static var animatesChanges = true

    private func animate(_ duration: TimeInterval, _ changes: () -> Void) {
        SCNTransaction.begin()
        SCNTransaction.animationDuration = Self.animatesChanges ? duration : 0
        SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        changes()
        SCNTransaction.commit()
    }
}

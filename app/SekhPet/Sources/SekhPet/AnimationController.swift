import SceneKit

/// Plays catalog clips on the skeleton, crossfading from whatever is playing.
/// Each play gets a fresh player, so any clip can follow any other (including itself)
/// without restarting a player that is still blending out.
@MainActor
final class AnimationController {
    private let catalog: Catalog
    private let assets: URL
    private let skeleton: SCNNode
    private var cache: [String: SCNAnimation] = [:]
    private var activeKey: String?
    private var serial = 0

    private(set) var currentClip: String?

    init(catalog: Catalog, assets: URL, skeleton: SCNNode) {
        self.catalog = catalog
        self.assets = assets
        self.skeleton = skeleton
    }

    func play(_ name: String, loop: Bool, fade: TimeInterval) {
        guard let source = animation(named: name) else { return }
        let animation = source.copy() as! SCNAnimation
        animation.repeatCount = loop ? .infinity : 1
        animation.isRemovedOnCompletion = false
        animation.fillsForward = true
        // The very first clip has nothing to blend from but the bind T-pose.
        animation.blendInDuration = activeKey == nil ? 0 : fade

        serial += 1
        let key = "clip-\(serial)-\(name)"
        let player = SCNAnimationPlayer(animation: animation)
        skeleton.addAnimationPlayer(player, forKey: key)
        player.play()
        if let old = activeKey {
            skeleton.removeAnimation(forKey: old, blendOutDuration: fade)
        }
        activeKey = key
        currentClip = name
    }

    /// Loads every clip up front so the first play of each never stalls a frame.
    func preload(_ names: some Sequence<String>) {
        for name in names { _ = animation(named: name) }
    }

    private func animation(named name: String) -> SCNAnimation? {
        if let cached = cache[name] { return cached }
        let url = assets.appendingPathComponent(catalog.clip(name).file)
        guard let scene = try? SCNScene(url: url, options: nil),
              let node = scene.rootNode.childNode(withName: catalog.skeletonNode, recursively: true),
              let key = node.animationKeys.first,
              let animation = node.animationPlayer(forKey: key)?.animation
        else {
            NSLog("SekhPet: could not load animation %@ from %@", name, url.path)
            return nil
        }
        node.removeAllAnimations()
        cache[name] = animation
        return animation
    }
}

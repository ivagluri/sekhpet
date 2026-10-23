import AppKit
import SceneKit

/// `SekhPet --snapshot <dir> [seconds] [fps] [surpriseMin-surpriseMax] [events] [--pet Name]`
/// renders the behavior engine offscreen on a virtual clock and writes numbered
/// transparent PNG frames, for checking framing, lighting and transitions without
/// the desktop window. `events` scripts input, e.g. `5:click,12:double,20:drag,24:drop`.
@MainActor
enum Snapshot {
    /// The value after `flag`, e.g. `--pet KingWhale`.
    private static func option(_ flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    /// `SekhPet --icon <file.png>`: a 1024 px transparent head-and-shoulders
    /// render of the idle pose, used to build the app icon.
    static func icon(arguments: [String]) -> Int32 {
        guard let path = arguments.first, let assets = AssetLocator.petDirectory(named: option("--pet", in: arguments)) else {
            print("usage: SekhPet --icon <output.png>")
            return 2
        }
        do {
            PetActor.animatesChanges = false
            let catalog = try Catalog.load(from: assets)
            let stage = try PetStage(assets: assets, catalog: catalog)
            stage.rig.animations.play(catalog.idleClip, loop: true, fade: 0)
            // Frame the head and shoulders, slightly turned for some shape.
            stage.rig.actor.face(yawDegrees: 18, over: 0)
            // Head and shoulders, proportioned to the model's standing height and
            // centred on the posed head bone (falling back to a typical head height).
            let height = catalog.clip(catalog.idleClip).bounds.max[1]
            stage.camera.camera?.orthographicScale = 0.31 * height
            let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
            renderer.scene = stage.scene
            renderer.pointOfView = stage.camera
            _ = renderer.snapshot(atTime: 0.45, with: CGSize(width: 64, height: 64), antialiasingMode: .none)
            let distance = stage.camera.position.z
            if let head = stage.scene.rootNode.childNode(withName: "head", recursively: true) {
                let p = head.presentation.worldPosition
                stage.camera.position = SCNVector3(p.x, p.y + 0.05 * height, distance)
            } else {
                stage.camera.position = SCNVector3(0, 0.76 * height, distance)
            }
            let image = renderer.snapshot(atTime: 0.45, with: CGSize(width: 1024, height: 1024), antialiasingMode: .multisampling4X)
            let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
            try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
            print("wrote \(path)")
            return 0
        } catch {
            print("icon failed: \(error)")
            return 1
        }
    }

    static func run(arguments: [String]) -> Int32 {
        let pet = option("--pet", in: arguments)
        var arguments = arguments
        if let index = arguments.firstIndex(of: "--pet") {
            arguments.removeSubrange(index..<min(index + 2, arguments.count))
        }
        guard arguments.count >= 1, let assets = AssetLocator.petDirectory(named: pet) else {
            print("usage: SekhPet --snapshot <output-dir> [seconds] [fps] [min-max] [t:event,...]")
            return 2
        }
        let output = URL(fileURLWithPath: arguments[0])
        let seconds = arguments.count > 1 ? Double(arguments[1]) ?? 20 : 20
        let fps = arguments.count > 2 ? Double(arguments[2]) ?? 10 : 10
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            PetActor.animatesChanges = false
            let catalog = try Catalog.load(from: assets)
            let stage = try PetStage(assets: assets, catalog: catalog)
            var now = 0.0
            let engine = BehaviorEngine(rig: stage.rig, clock: { now })
            if arguments.count > 3 {
                let bounds = arguments[3].split(separator: "-").compactMap { Double($0) }
                if bounds.count == 2 { engine.surpriseInterval = bounds[0]...bounds[1] }
            }
            var events: [(time: Double, name: String)] = []
            if arguments.count > 4 {
                for item in arguments[4].split(separator: ",") {
                    let parts = item.split(separator: ":")
                    if parts.count == 2, let time = Double(parts[0]) { events.append((time, String(parts[1]))) }
                }
            }
            // A virtual screen 12 m wide on screen, starting in the middle. Motion is in
            // model metres, so a scaled-down giant gets proportionally more room.
            var x = 0.0
            let half = 6 / catalog.meshScale
            stage.rig.motion.onMove = { x += $0 }
            stage.rig.motion.room = { (left: half + x, right: half - x) }
            var log: [String] = []
            var positions: [String] = []
            // Scripted pointer position in scene metres (`cursor=x/y` events).
            var cursor: CGPoint? = nil
            engine.onChange = { log.append(String(format: "%.2f %@  x=%.2f depth=%.2f", now, $0, x, stage.rig.actor.depth)) }

            let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
            renderer.scene = stage.scene
            renderer.pointOfView = stage.camera
            // Twice the on-screen Medium size, so frames match what the desktop shows.
            var ppm = PetSize.medium.pointsPerMetre * 2 * catalog.meshScale
            // Cap frames at 2048 px so an oversized pack can't exhaust memory.
            ppm = min(ppm, 2048 / max(stage.bounds.width, stage.bounds.height))
            let size = CGSize(width: stage.bounds.width * ppm, height: stage.bounds.height * ppm)
            var frame = 0
            while now <= seconds {
                renderer.sceneTime = now
                while let event = events.first, event.time <= now {
                    events.removeFirst()
                    log.append(String(format: "%.2f [%@]", now, event.name))
                    switch event.name {
                    case "click": engine.click()
                    case "double": engine.doubleClick()
                    case "drag": engine.dragBegan()
                    case "drop": engine.dragEnded()
                    case "watch": engine.watchCursorNow()
                    case let name where name.hasPrefix("cursor="):
                        let parts = name.dropFirst(7).split(separator: "/").compactMap { Double($0) }
                        if parts.count == 2 { cursor = CGPoint(x: parts[0], y: parts[1]) }
                    case let name where name.hasPrefix("play="):
                        let clip = String(name.dropFirst(5))
                        let isGroup = catalog.groups[clip] != nil
                        engine.playNow(Catalog.PoolEntry(clip: isGroup ? nil : clip, group: isGroup ? clip : nil))
                    default: print("unknown event \(event.name)")
                    }
                }
                engine.tick()
                stage.rig.motion.update(at: now)
                stage.rig.look.update(cursor: cursor, at: now)
                positions.append(String(format: "%d %.4f %.4f %.1f", frame, x, stage.rig.actor.depth, stage.rig.actor.yawDegrees))
                // Release each frame's image before the next, or long runs pile them up.
                try autoreleasepool {
                    let image = renderer.snapshot(atTime: now, with: size, antialiasingMode: .multisampling4X)
                    let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
                    let name = String(format: "frame-%05d.png", frame)
                    try rep.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
                }
                frame += 1
                now = Double(frame) / fps
            }
            try positions.joined(separator: "\n").write(to: output.appendingPathComponent("positions.txt"), atomically: true, encoding: .utf8)
            try log.joined(separator: "\n").write(to: output.appendingPathComponent("behaviors.txt"), atomically: true, encoding: .utf8)
            print("wrote \(frame) frames to \(output.path)")
            return 0
        } catch {
            print("snapshot failed: \(error)")
            return 1
        }
    }
}

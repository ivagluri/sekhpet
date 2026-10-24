import Foundation

/// Mirror of `clips.json`, written by `scripts/export_realtime.py`.
/// All lengths are SceneKit metres; the character faces +Z at yaw 0.
struct Catalog: Decodable {
    enum Facing: String, Decodable {
        case front, directional
    }

    struct Bounds: Decodable {
        let min: [Double]
        let max: [Double]
        let horizontalRadius: Double
    }

    /// Authored root travel, as (x, z) samples in model space; `scale` shrinks it for the desktop.
    struct RootTravel: Decodable {
        let end: [Double]
        let samples: [[Double]]
        let fps: Double
        let scale: Double
    }

    struct Clip: Decodable {
        let file: String
        let duration: Double
        let loop: Bool
        let facing: Facing
        let yawDegrees: Double
        let fadeIn: Double
        let bounds: Bounds
        let rootTravel: RootTravel?
        /// Metres per second an in-place locomotion clip's stride covers.
        let groundSpeed: Double?
    }

    /// Start/loop/end clips that must always play as one unit. `loopCount`, when
    /// given, fixes how often the loop plays (for brief holds or falls), overriding
    /// the surprise minimum.
    struct Group: Decodable {
        let start: [String]
        let loop: String
        let end: [String]
        let loopCount: [Int]?
    }

    struct Surprise: Decodable {
        let intervalSeconds: [Double]
        let loopCount: [Int]
        let minSeconds: Double
    }

    /// One surprise choice: a single clip or a start/loop/end group.
    struct PoolEntry: Decodable, Hashable {
        let clip: String?
        let group: String?

        var name: String { clip ?? group ?? "?" }
    }

    struct WeightedClip: Decodable {
        let clip: String
        let weight: Double
        let maxSeconds: Double?
    }

    struct Wander: Decodable {
        let chance: Double
        let seconds: [Double]
        let minDistanceMetres: Double
        let depthChance: Double
    }

    struct Input: Decodable {
        /// Reactions are optional: not every pal has a carry, jump or signature move.
        let singleClick: [WeightedClip]
        let doubleClick: String?
        let dragGroup: String?
        let dropGroup: String?
    }

    let name: String
    let displayName: String
    /// The game's paldeck number as it shows it ("002", or "005B" for a variant).
    let paldeckNo: String?
    /// The game's own scale for this character's mesh, applied on screen so
    /// several pets keep their in-game relative sizes.
    let meshScale: Double
    /// Neck/head bones the cursor-watching turns; nil auto-detects them.
    let lookBones: [String]?
    let model: String
    let skeletonNode: String
    let clips: [String: Clip]
    let groups: [String: Group]
    let idleClip: String
    /// Clips the idle drifts into now and then (one at a time, with plain idle between),
    /// for characters whose idle alone is too still. Not surprises; empty for most packs.
    let idleVariants: [String]
    let surprise: Surprise
    let surprisePool: [PoolEntry]
    let locomotion: [WeightedClip]
    let wander: Wander
    let input: Input

    static func load(from directory: URL) throws -> Catalog {
        let data = try Data(contentsOf: directory.appendingPathComponent("clips.json"))
        return try JSONDecoder().decode(Catalog.self, from: data)
    }

    // Packs exported before multi-pet support have no name fields.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        model = try c.decode(String.self, forKey: .model)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? (model as NSString).deletingPathExtension
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? name
        paldeckNo = try c.decodeIfPresent(String.self, forKey: .paldeckNo)
        meshScale = try c.decodeIfPresent(Double.self, forKey: .meshScale) ?? 1
        lookBones = try c.decodeIfPresent([String].self, forKey: .lookBones)
        skeletonNode = try c.decode(String.self, forKey: .skeletonNode)
        clips = try c.decode([String: Clip].self, forKey: .clips)
        groups = try c.decode([String: Group].self, forKey: .groups)
        idleClip = try c.decode(String.self, forKey: .idleClip)
        idleVariants = try c.decodeIfPresent([String].self, forKey: .idleVariants) ?? []
        surprise = try c.decode(Surprise.self, forKey: .surprise)
        surprisePool = try c.decode([PoolEntry].self, forKey: .surprisePool)
        locomotion = try c.decode([WeightedClip].self, forKey: .locomotion)
        wander = try c.decode(Wander.self, forKey: .wander)
        input = try c.decode(Input.self, forKey: .input)
    }

    private enum CodingKeys: String, CodingKey {
        case name, displayName, paldeckNo, meshScale, lookBones, model, skeletonNode, clips, groups, idleClip, idleVariants, surprise, surprisePool, locomotion, wander, input
    }

    /// The clips a pool entry plays (a group's members in order).
    func clips(for entry: PoolEntry) -> [String] {
        if let clip = entry.clip { return [clip] }
        guard let name = entry.group, let group = groups[name] else { return [] }
        return group.start + [group.loop] + group.end
    }

    /// Every clip the pet can play: idle, surprises and input reactions.
    var playableClips: [String] {
        var names = [idleClip] + idleVariants + [input.doubleClick].compactMap { $0 } + input.singleClick.map(\.clip)
        names += surprisePool.flatMap { clips(for: $0) } + locomotion.map(\.clip) + [workClip].compactMap { $0 }
        for group in [input.dragGroup, input.dropGroup].compactMap({ $0 }) {
            names += clips(for: PoolEntry(clip: nil, group: group))
        }
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }

    func isLocomotion(_ name: String) -> Bool { locomotion.contains { $0.clip == name } }

    /// The clip the pet works with: handiwork, or else its first other work action
    /// (the game's work montages, as named in the packs).
    var workClip: String? {
        ["CommonWork", "Commonwork", "Architecture", "Mining", "Deforest", "Watering", "Planting", "Cooking", "Cooling"]
            .first { clips[$0] != nil }
    }

    func clip(_ name: String) -> Clip {
        guard let clip = clips[name] else { fatalError("clips.json has no clip named \(name)") }
        return clip
    }
}

extension Array where Element == Catalog.WeightedClip {
    func pickWeighted() -> String? {
        let total = reduce(0) { $0 + $1.weight }
        guard total > 0 else { return first?.clip }
        var roll = Double.random(in: 0..<total)
        for entry in self {
            roll -= entry.weight
            if roll < 0 { return entry.clip }
        }
        return last?.clip
    }
}

/// The project's exported pet packs, used by the `--snapshot` and `--icon`
/// development modes: found via `SEKHPET_ASSETS`, otherwise the pipeline's
/// `work/<pal>/realtime` folders (found by walking up from the binary) and then
/// the installed pets. The app itself reads pets from `PetLibrary`.
enum AssetLocator {
    static func petDirectories() -> [URL] {
        let fm = FileManager.default
        if let env = ProcessInfo.processInfo.environment["SEKHPET_ASSETS"] {
            return [URL(fileURLWithPath: env)]
        }
        var found: [URL] = []
        var dir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        for _ in 0..<8 {
            dir.deleteLastPathComponent()
            let work = dir.appendingPathComponent("work")
            guard fm.fileExists(atPath: work.path) else { continue }
            let candidates = (try? fm.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)) ?? []
            found = candidates.map { $0.appendingPathComponent("realtime") }
                .filter { fm.fileExists(atPath: $0.appendingPathComponent("clips.json").path) }
            break
        }
        return found + PetLibrary.packDirectories()
    }

    /// The pack for `name` (case-insensitive), or the first pack.
    static func petDirectory(named name: String?) -> URL? {
        let all = petDirectories()
        guard let name else { return all.first }
        return all.first { url in
            (try? Catalog.load(from: url))?.name.lowercased() == name.lowercased()
        }
    }
}

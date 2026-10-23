import Foundation

/// The user's pets folder, `~/Library/Application Support/SekhPet/Pets/`, holding
/// one pack folder per pet. The app ships without pets; packs are installed by
/// dropping them into this folder (or with `scripts/build_app.sh --pets`).
enum PetLibrary {
    static var folder: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("SekhPet/Pets", isDirectory: true)
    }

    /// Every folder in the pets folder that contains a `clips.json`.
    static func packDirectories() -> [URL] {
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let entries = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return entries.filter { fm.fileExists(atPath: $0.appendingPathComponent("clips.json").path) }
    }

    /// Moves a pack to the Trash, so it can be restored.
    static func trash(_ directory: URL) throws {
        try FileManager.default.trashItem(at: directory, resultingItemURL: nil)
    }
}

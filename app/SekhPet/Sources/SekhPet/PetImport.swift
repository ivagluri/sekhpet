import AppKit

/// Installs pets from zips or pack folders (the Pets window's Add Pet… button or a
/// drop), one pet per zip, and exports a pet as such a zip for another Mac. Every
/// pack is checked before anything is asked: its catalog must load and every file it
/// names must be present.
enum PetImport {
    /// A pack found in what the user added, unpacked somewhere temporary if it came zipped.
    struct Found: Sendable {
        let directory: URL
    }

    struct Scan: Sendable {
        var found: [Found] = []
        var problems: [String] = []
        /// Temporary folders holding unzipped packs, removed once the import is done.
        var scratch: [URL] = []
    }

    /// Unzips each of `urls` and finds the one pet pack (a folder with a `clips.json`)
    /// in it: at the top, or one folder down as Export as Zip makes them. Runs off the
    /// main thread, since unzipping and checking a pack takes a moment.
    static func scan(_ urls: [URL]) async -> Scan {
        await Task.detached {
            var scan = Scan()
            let fm = FileManager.default
            for url in urls {
                var root = url
                if url.pathExtension.lowercased() == "zip" {
                    let scratch = fm.temporaryDirectory.appendingPathComponent("SekhPet-import-\(UUID().uuidString)")
                    do {
                        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
                        try run("/usr/bin/ditto", ["-x", "-k", url.path, scratch.path])
                    } catch {
                        scan.problems.append("\(url.lastPathComponent): couldn't unzip it.")
                        try? fm.removeItem(at: scratch)
                        continue
                    }
                    scan.scratch.append(scratch)
                    root = scratch
                }
                let packs = packFolders(in: root, depth: 1)
                guard packs.count == 1, let directory = packs.first else {
                    scan.problems.append(packs.isEmpty
                        ? "\(url.lastPathComponent): no pet inside (a pet is a folder with a clips.json)."
                        : "\(url.lastPathComponent): holds \(packs.count) pets; add each pet as its own zip.")
                    continue
                }
                if let problem = check(directory) {
                    scan.problems.append("\(url.lastPathComponent): \(problem)")
                } else {
                    scan.found.append(Found(directory: directory))
                }
            }
            return scan
        }.value
    }

    /// Copies `pack` into the pets folder as `<name lowercased>`, moving any pack
    /// already there to the Trash first.
    static func install(_ pack: PetPack, replacing existing: PetPack?) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: PetLibrary.folder, withIntermediateDirectories: true)
        if let existing { try PetLibrary.trash(existing.directory) }
        let destination = PetLibrary.folder.appendingPathComponent(pack.name.lowercased(), isDirectory: true)
        if fm.fileExists(atPath: destination.path) { try PetLibrary.trash(destination) }
        try fm.copyItem(at: pack.directory, to: destination)
    }

    /// Zips `pack` (the folder itself, so unzipping gives back the pack folder).
    static func export(_ pack: PetPack, to zip: URL) throws {
        try? FileManager.default.removeItem(at: zip)
        try run("/usr/bin/ditto", ["-c", "-k", "--keepParent", pack.directory.path, zip.path])
    }

    // MARK: Checks

    private static func packFolders(in root: URL, depth: Int) -> [URL] {
        let fm = FileManager.default
        if fm.fileExists(atPath: root.appendingPathComponent("clips.json").path) { return [root] }
        guard depth > 0 else { return [] }
        let children = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                    options: [.skipsHiddenFiles])) ?? []
        return children
            .filter { $0.lastPathComponent != "__MACOSX" && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .flatMap { packFolders(in: $0, depth: depth - 1) }
    }

    /// Why `directory` isn't a usable pack, or nil if it is.
    private static func check(_ directory: URL) -> String? {
        let catalog: Catalog
        do {
            catalog = try Catalog.load(from: directory)
        } catch {
            return "its clips.json couldn't be read."
        }
        let fm = FileManager.default
        let files = [catalog.model] + catalog.clips.values.map(\.file)
        let missing = files.filter { !fm.fileExists(atPath: directory.appendingPathComponent($0).path) }
        if !missing.isEmpty {
            return missing.count == 1 ? "a file it needs is missing (\(missing[0]))."
                : "\(missing.count) files it needs are missing (e.g. \(missing[0]))."
        }
        // Links could point anywhere on the Mac; a real pack never has them.
        let items = fm.enumerator(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey])
        while let item = items?.nextObject() as? URL {
            if (try? item.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                return "it contains a link to another location, so it wasn't added."
            }
        }
        return nil
    }

    private static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}

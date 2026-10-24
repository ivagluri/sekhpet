import AppKit

/// Other apps' windows a pet can stand on, read from the window server. Their frames
/// are readable without any permission; nothing else about them is used.
enum DesktopSurfaces {
    struct Surface {
        let window: CGWindowID
        /// In AppKit screen coordinates (origin bottom-left of the main screen).
        let frame: NSRect
        /// Window level: 0 for ordinary windows, higher for always-on-top ones.
        let layer: Int
        /// The app that owns the window.
        let owner: pid_t
    }

    /// On-screen windows of other apps, front to back: normal windows and always-on-top
    /// ones such as Activity Monitor's CPU Usage, but not the menu bar, Dock or system UI.
    static func windows() -> [Surface] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return [] }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        // CoreGraphics measures from the top of the main screen; AppKit from its bottom.
        let flipHeight = NSScreen.screens.first?.frame.maxY ?? 0
        return list.compactMap { info in
            guard let layer = info[kCGWindowLayer as String] as? Int,
                  (0...Int(CGWindowLevelForKey(.floatingWindow))).contains(layer),
                  let owner = info[kCGWindowOwnerPID as String] as? pid_t, owner != ownPID,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let number = info[kCGWindowNumber as String] as? CGWindowID,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict),
                  bounds.width >= 120, bounds.height >= 40 else { return nil }
            let frame = NSRect(x: bounds.minX, y: flipHeight - bounds.maxY, width: bounds.width, height: bounds.height)
            return Surface(window: number, frame: frame, layer: layer, owner: owner)
        }
    }

    /// Every window on screen, read once and shared by all pets in the same frame. Each
    /// read waits on the window server, and gets slower with every pet window, so pets
    /// reading for themselves took 40% of the main thread with nine on windows.
    struct Snapshot {
        /// Each window and its place, front to back (0 is frontmost).
        let windows: [CGWindowID: (place: Int, surface: Surface)]
        /// Whether Mission Control is open: the Dock then covers a screen with windows at
        /// its own level and above, and shows every window shrunk and moved.
        let missionControl: Bool
    }

    @MainActor private static var latest: (at: TimeInterval, snapshot: Snapshot)?

    /// The windows as of `now`, read at most once for that time.
    @MainActor static func snapshot(at now: TimeInterval) -> Snapshot {
        if let latest, latest.at == now { return latest.snapshot }
        let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        let flipHeight = NSScreen.screens.first?.frame.maxY ?? 0
        let screens = Set(NSScreen.screens.map { "\(Int($0.frame.width))x\(Int($0.frame.height))" })
        let dockLevel = Int(CGWindowLevelForKey(.dockWindow)) - 2
        var windows: [CGWindowID: (place: Int, surface: Surface)] = [:]
        var missionControl = false
        for (place, info) in list.enumerated() {
            guard let number = info[kCGWindowNumber as String] as? CGWindowID,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict) else { continue }
            let frame = NSRect(x: bounds.minX, y: flipHeight - bounds.maxY, width: bounds.width, height: bounds.height)
            let owner = info[kCGWindowOwnerPID as String] as? pid_t ?? 0
            windows[number] = (place, Surface(window: number, frame: frame, layer: layer, owner: owner))
            if layer >= dockLevel, (info[kCGWindowOwnerName as String] as? String) == "Dock",
               screens.contains("\(Int(bounds.width))x\(Int(bounds.height))") {
                missionControl = true
            }
        }
        let snapshot = Snapshot(windows: windows, missionControl: missionControl)
        latest = (now, snapshot)
        return snapshot
    }
}

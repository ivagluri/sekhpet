import AppKit

/// Other apps' windows a pet can stand on, read from the window server. Their frames
/// are readable without any permission; nothing else about them is used.
enum DesktopSurfaces {
    struct Surface {
        let window: CGWindowID
        /// In AppKit screen coordinates (origin bottom-left of the main screen).
        let frame: NSRect
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
                  (info[kCGWindowOwnerPID as String] as? pid_t) != ownPID,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let number = info[kCGWindowNumber as String] as? CGWindowID,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict),
                  bounds.width >= 120, bounds.height >= 40 else { return nil }
            let frame = NSRect(x: bounds.minX, y: flipHeight - bounds.maxY, width: bounds.width, height: bounds.height)
            return Surface(window: number, frame: frame)
        }
    }

    /// One window, if it's still on screen. Cheap enough to call every frame.
    static func window(_ id: CGWindowID) -> Surface? {
        guard let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]])?.first,
              info[kCGWindowIsOnscreen as String] as? Bool == true,
              let dict = info[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: dict) else { return nil }
        let flipHeight = NSScreen.screens.first?.frame.maxY ?? 0
        return Surface(window: id, frame: NSRect(x: bounds.minX, y: flipHeight - bounds.maxY,
                                                 width: bounds.width, height: bounds.height))
    }
}

import AppKit

/// The menu bar (status bar) icon: only the "StatusBarIcon" image set from Assets.xcassets.
@MainActor
enum MenuBarIcon {
    static func image() -> NSImage {
        guard let src = NSImage(named: "StatusBarIcon") else { return NSImage() }
        let img = src.copy() as! NSImage
        let h: CGFloat = 18
        let s = img.size
        if s.height > 0 { img.size = NSSize(width: s.width * h / s.height, height: h) }
        img.isTemplate = true       // tints automatically for light/dark menu bar
        return img
    }
}

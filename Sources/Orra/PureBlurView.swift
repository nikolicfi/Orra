import AppKit
import QuartzCore

/// A pure backdrop blur: it blurs whatever is behind the window (the lock-screen wallpaper)
/// and adds NOTHING else - no tint, no saturation/brightness boost, no vibrancy.
///
/// Why not NSVisualEffectView? Every NSVisualEffectView material stacks a colour-matrix
/// (saturation + brightness) and a light/dark tint on top of the blur, which is what made the
/// background look whiter. Here we create the same window-server backdrop layer
/// (CABackdropLayer) that NSVisualEffectView uses internally, but give it a single
/// gaussianBlur filter and nothing else.
///
/// Uses private Core Animation classes (CABackdropLayer, CAFilter) - same category of risk as
/// the SkyLight usage elsewhere in this app.
final class PureBlurView: NSView {
    private let backdrop: CALayer?
    private let cornerRadius: CGFloat

    /// Gaussian blur radius in points. 0 = no blur.
    var radius: CGFloat = 0 {
        didSet { if oldValue != radius { applyFilter() } }
    }

    /// False when the private classes could not be found (the view then simply shows nothing).
    var isSupported: Bool { backdrop != nil }

    init(frame: CGRect, cornerRadius: CGFloat) {
        self.cornerRadius = cornerRadius
        if let cls = NSClassFromString("CABackdropLayer") as? CALayer.Type {
            let l = cls.init()
            l.setValue(true, forKey: "windowServerAware")   // sample the content behind the window
            l.setValue(UUID().uuidString, forKey: "groupName")
            l.setValue(1.0, forKey: "scale")
            l.setValue(0.0, forKey: "bleedAmount")
            backdrop = l
        } else {
            backdrop = nil
            lpLog("CABackdropLayer not available - blur disabled")
        }
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = nil
        if let b = backdrop {
            b.frame = bounds
            layer?.addSublayer(b)
        }
        applyFilter()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdrop?.frame = bounds
        CATransaction.commit()
    }

    private func applyFilter() {
        guard let backdrop else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if radius > 0, let f = Self.gaussianBlur(radius: radius) {
            backdrop.filters = [f]
        } else {
            backdrop.filters = []
        }
        CATransaction.commit()
    }

    /// CAFilter(type: "gaussianBlur") with only the radius set - no colour filters.
    private static func gaussianBlur(radius: CGFloat) -> NSObject? {
        guard let cls = NSClassFromString("CAFilter") else { return nil }
        let sel = NSSelectorFromString("filterWithType:")
        let obj = cls as AnyObject
        guard obj.responds(to: sel),
              let f = obj.perform(sel, with: "gaussianBlur")?.takeUnretainedValue() as? NSObject
        else {
            lpLog("CAFilter gaussianBlur not available")
            return nil
        }
        f.setValue(radius, forKey: "inputRadius")
        f.setValue(true, forKey: "inputNormalizeEdges")   // no dark/transparent fringe at the edges
        return f
    }
}

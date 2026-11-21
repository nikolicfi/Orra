import AppKit
import SwiftUI
import Combine

final class OverlayWindow: NSWindow {
    init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        level = .screenSaver
        canBecomeVisibleWithoutLogin = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    }
    override var canBecomeKey: Bool { true }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown && !isKeyWindow { makeKey() }
        super.sendEvent(event)
    }
}

@MainActor
final class LockScreenController {
    private let model: NowPlayingModel
    private let settings: Settings
    private let backdrop: OverlayWindow
    private let card: OverlayWindow
    private let blurView = PureBlurView(
        frame: CGRect(x: 20, y: 20, width: 360, height: 164),
        cornerRadius: 26)
    private var space: LockSpace?
    private var bag = Set<AnyCancellable>()
    private(set) var isShown = false

    init(model: NowPlayingModel, settings: Settings) {
        self.model = model
        self.settings = settings
        let screen = NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)

        backdrop = OverlayWindow(frame: screen)
        backdrop.ignoresMouseEvents = true          // never blocks the password field
        let backdropHost = NSHostingView(rootView: BackdropView(model: model, settings: settings))
        backdropHost.autoresizingMask = [.width, .height]
        backdrop.contentView = backdropHost

        card = OverlayWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 204))
        // window content: [ real behind-window blur ] under [ SwiftUI card ]
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 204))
        let pad: CGFloat = 20   // PlayerCard pads 20 pt around the 360 x 164 card
        blurView.frame = CGRect(x: pad, y: pad, width: PlayerCard.size.width, height: PlayerCard.size.height)
        container.addSubview(blurView)
        let host = NSHostingView(rootView: CardRoot(model: model, settings: settings))
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        card.contentView = container

        layout()
        backdrop.orderFrontRegardless()
        card.orderFrontRegardless()
        applyVisibility()

        let lvl = Int32(UserDefaults.standard.object(forKey: "level") as? Int ?? 400)
        space = LockSpace(windows: [backdrop, card], level: lvl)
        space?.hide()
        if space == nil { NSLog("Orra: SkyLight unavailable – lock screen display disabled") }

        settings.$blur.sink { [weak self] _ in
            DispatchQueue.main.async { self?.applyBlur() }
        }.store(in: &bag)
        settings.$tone.sink { [weak self] _ in
            DispatchQueue.main.async { self?.applyBlur() }
        }.store(in: &bag)
        applyBlur()

        settings.$mode.sink { [weak self] _ in
            DispatchQueue.main.async { self?.layout() }
        }.store(in: &bag)
        model.$title.sink { [weak self] _ in
            MarqueeSync.shared.restart()      // new song/podcast: scrolling starts again after 3 s
            DispatchQueue.main.async { self?.applyVisibility() }
        }.store(in: &bag)
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.layout() }
            }
    }

    /// Blur strength 0...1 (menu: 0-100 % in 10 % steps) -> Gaussian radius of the pure backdrop blur.
    /// Only the farthest-back layer (the wallpaper) is blurred; no tint or colour is added.
    /// 0 = no blur view at all.
    private func applyBlur() {
        let b = min(max(settings.blur, 0), 1)
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        blurView.isHidden = b <= 0 || reduce
        blurView.radius = CGFloat(b) * 40
        lpLog("blur \(Int(b * 100))% -> radius \(blurView.radius) hidden=\(blurView.isHidden) supported=\(blurView.isSupported)")
    }

    private func layout() {
        guard let s = NSScreen.main?.frame else { return }
        backdrop.setFrame(s, display: true)
        backdrop.contentView?.frame = CGRect(origin: .zero, size: s.size)
        let pad: CGFloat = 20
        // The window is always full size (card at its bottom, same spot as before); switching between compact and
        // full artwork is animated inside the window instead of resizing it.
        let size = PlayerCard.fullWindowSize
        let origin = CGPoint(x: s.midX - size.width / 2, y: s.minY + s.height * 0.27 - 204 / 2)
        blurView.frame = CGRect(x: pad, y: pad, width: PlayerCard.size.width, height: PlayerCard.size.height)
        card.setFrame(CGRect(origin: origin, size: size), display: true)
    }

    private func applyVisibility() {
        let on = isShown && model.hasTrack
        card.alphaValue = on ? 1 : 0
        card.ignoresMouseEvents = !on
        backdrop.alphaValue = isShown ? 1 : 0
    }

    func show() {
        isShown = true
        applyBlur()
        layout()
        applyVisibility()
        model.poll()
        MarqueeSync.shared.restart()          // scrolling starts 3 s after the player appears
        space?.show()
        AudioSpectrum.shared.start()      // listen only while the overlay is visible
    }

    func hide() {
        isShown = false
        applyVisibility()
        space?.hide()
        AudioSpectrum.shared.stop()
    }

    /// Lets you test the overlay without locking the Mac.
    func preview(seconds: Double = 8) {
        show()
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in self?.hide() }
    }
}

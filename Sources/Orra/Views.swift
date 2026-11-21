import SwiftUI

// MARK: - Clear card
// Drawn by hand instead of .glassEffect: the system glass follows System Settings > Appearance >
// Liquid Glass (Clear/Tinted) and goes milky whenever that is on Tinted.
// This is only the optional colour layer (black/white at `dim` opacity; set Dimming to 0.0 for none).
// The blur is a PureBlurView (gaussian blur of the wallpaper only, no tint) that LockScreenController
// puts UNDER this view at window level (a blur view nested inside SwiftUI modifiers loses its backdrop).
extension View {
    func lockGlass(cornerRadius: CGFloat, dim: Double, light: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self.background {
            (light ? Color.white : Color.black).opacity(dim)
                .clipShape(shape)
        }
    }
}

// MARK: - Glass edge (thin 3D-ish rim: white top/bottom, black left/right)
// A hairline white outline all the way round, plus a white crescent along the top and bottom and a black
// crescent along the left and right. Each crescent is the card shape minus a copy of itself shifted by
// `peak` pt, so it is `peak` thick at the middle of its edge and tapers to nothing toward the corners.
// `strength` (menu: Border Opacity) scales all of them together.
// Tweak `peak` (thickness at the middles), the outline lineWidth, or the opacities below.
struct GlassEdge: View {
    var corner: CGFloat
    var peak: CGFloat = 1.5
    /// 0...1 multiplier on the border's opacity (menu: Border Opacity)
    var strength: Double = 1

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        ZStack {
            shape.strokeBorder(Color.white.opacity(0.18 * strength), lineWidth: 0.5)
            crescent(shape, color: .white, dx: 0, dy: peak)     // top: shape minus itself moved down
            crescent(shape, color: .white, dx: 0, dy: -peak)    // bottom: shape minus itself moved up
            crescent(shape, color: .black, dx: peak, dy: 0)     // left: shape minus itself moved right
            crescent(shape, color: .black, dx: -peak, dy: 0)    // right: shape minus itself moved left
        }
        .allowsHitTesting(false)
    }

    private func crescent(_ shape: RoundedRectangle, color: Color, dx: CGFloat, dy: CGFloat) -> some View {
        color.opacity(0.6 * strength)
            .mask {
                ZStack {
                    shape.fill(Color.black)
                    shape.fill(Color.black)
                        .offset(x: dx, y: dy)
                        .blendMode(.destinationOut)
                }
                .compositingGroup()
            }
    }
}

private func fmt(_ t: Double) -> String {
    let s = Int(max(0, t))
    if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
    return String(format: "%d:%02d", s / 60, s % 60)
}

// MARK: - Clock
struct ClockView: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            VStack(spacing: -6) {
                Text(ctx.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                    .font(.system(size: 26, weight: .semibold, design: .serif))
                    .foregroundStyle(.white.opacity(0.85))
                Text(ctx.date.formatted(.dateTime.hour(.defaultDigits(amPM: .omitted)).minute()))
                    .font(.system(size: 136, weight: .bold, design: .serif))
                    .foregroundStyle(
                        LinearGradient(colors: [.white.opacity(0.95), .white.opacity(0.7)],
                                       startPoint: .top, endPoint: .bottom))
                    .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
            }
        }
    }
}

// MARK: - Backdrop
// Full-screen artwork mode no longer paints any background: the wallpaper stays visible and the
// artwork + card are drawn by PlayerCard(full: true). The backdrop window is kept (empty) so the
// rest of the setup is unchanged.
struct BackdropView: View {
    @ObservedObject var model: NowPlayingModel
    @ObservedObject var settings: Settings
    var body: some View { Color.clear.ignoresSafeArea() }
}

/// Window content of the card window: picks the compact card or the full artwork layout.
struct CardRoot: View {
    @ObservedObject var model: NowPlayingModel
    @ObservedObject var settings: Settings
    var body: some View {
        PlayerCard(model: model, settings: settings, full: settings.mode == .fullArt)
            .animation(.smooth(duration: 0.5), value: settings.mode)
    }
}

// MARK: - Marquee (calm back-and-forth scroll for text that does not fit)
private struct MarqueeWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// One shared clock for every marquee, so the title and the creator move together and the scroll keeps
/// going when the view switches between compact and full artwork (the clock lives outside the views).
///
/// Cycle: wait `startDelay` s -> every text that is too long glides to its end, holds `endHold` s, glides
/// back (all at the same `speed`) -> a text that finished first waits for the longest one -> wait
/// `startDelay` s -> next loop starts for all of them at the same time.
@MainActor
final class MarqueeSync {
    static let shared = MarqueeSync()
    static let speed: Double = 24        // points per second
    static let startDelay: Double = 3    // seconds before a loop starts (and between loops)
    static let endHold: Double = 1.5     // seconds each text rests at its far end

    private(set) var start = Date()
    private var overflows: [String: CGFloat] = [:]

    /// Restart the cycle (player shown, or a new song/podcast): scrolling begins after `startDelay`.
    func restart() { start = Date() }

    func report(_ key: String, overflow: CGFloat) { overflows[key] = overflow }

    private var longestLoop: Double {
        overflows.values.filter { $0 > 0 }
            .map { 2 * Double($0) / Self.speed + Self.endHold }.max() ?? 0
    }

    /// How far (pt) a text with `overflow` pt of hidden width is scrolled at `date`.
    func offset(overflow: CGFloat, at date: Date) -> CGFloat {
        guard overflow > 0 else { return 0 }
        let cycle = Self.startDelay + max(longestLoop, 2 * Double(overflow) / Self.speed + Self.endHold)
        let x = date.timeIntervalSince(start).truncatingRemainder(dividingBy: cycle)
        let u = x - Self.startDelay
        if u < 0 { return 0 }
        let travel = Double(overflow) / Self.speed
        if u < travel { return CGFloat(u * Self.speed) }
        if u < travel + Self.endHold { return overflow }
        if u < 2 * travel + Self.endHold { return overflow - CGFloat((u - travel - Self.endHold) * Self.speed) }
        return 0   // finished: rests at the start until the longest text is done
    }
}

/// Shows `content` at its natural size. If it is wider than the available space it scrolls
/// according to MarqueeSync; otherwise it is simply aligned.
struct Marquee<Content: View>: View {
    var key: String
    var alignment: Alignment
    var height: CGFloat
    @ViewBuilder var content: () -> Content
    @State private var contentWidth: CGFloat = 0

    var body: some View {
        GeometryReader { g in
            // a text only counts as "too long" if it really is clipped (ignore sub-point rounding noise
            // and the first layout pass, where the container width is still 0)
            let raw = contentWidth - g.size.width
            let overflow: CGFloat = (g.size.width > 1 && raw > 2) ? raw : 0
            // report on every layout pass (plain store, no state change): only visible marquees report,
            // so a view that was just replaced by the other mode can never leave a stale value behind
            let _ = MarqueeSync.shared.report(key, overflow: overflow)
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: overflow <= 0)) { ctx in
                let off = MarqueeSync.shared.offset(overflow: overflow, at: ctx.date)
                // soft edge only on a side where text is actually hidden: at rest the first letter
                // (left) / last letter (right) stays fully visible
                let fade: CGFloat = 14
                let left = min(off, fade)
                let right = min(max(overflow - off, 0), fade)
                content()
                    .fixedSize()
                    .offset(x: -off)
                    .frame(width: g.size.width, alignment: overflow > 0 ? .leading : alignment)
                    .mask(
                        HStack(spacing: 0) {
                            LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                                .frame(width: left)
                            Rectangle().fill(Color.black)
                            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                                .frame(width: right)
                        }
                    )
            }
            // invisible copy of the text, only used to measure its natural width
            .background(alignment: .leading) {
                content()
                    .fixedSize()
                    .opacity(0)
                    .background(GeometryReader { p in
                        Color.clear.preference(key: MarqueeWidthKey.self, value: p.size.width)
                    })
                    .allowsHitTesting(false)
            }
            .onPreferenceChange(MarqueeWidthKey.self) { w in
                if abs(w - contentWidth) > 0.5 { contentWidth = w }
            }
        }
        .frame(height: height)
        .clipped()
    }
}

// MARK: - Explicit badge (small rounded square with an E)
struct ExplicitBadge: View {
    var body: some View {
        Text("E")
            .font(.system(size: 10, weight: .heavy, design: .rounded))
            .foregroundStyle(.background)
            .frame(width: 14, height: 14)
            .background(RoundedRectangle(cornerRadius: 3, style: .continuous).fill(Color.primary.opacity(0.55)))
            .accessibilityLabel("Explicit")
    }
}

// MARK: - Audio visualiser (7 bars; flat dots when paused)
struct WaveformBars: View {
    var playing: Bool
    @ObservedObject private var spec = AudioSpectrum.shared
    private var live: Bool { spec.available && spec.receiving }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: !playing || live)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 1.3) {
                ForEach(0..<AudioSpectrum.bandCount, id: \.self) { i in
                    let level: CGFloat = !playing ? 0
                        : (live ? CGFloat(spec.levels[i])
                                          : CGFloat(0.45 + 0.4 * sin(t * 5 + Double(i) * 1.1)))
                    Capsule()
                        .fill(Color.primary.opacity(0.4))
                        .frame(width: 2, height: 2 + 16 * level)
                }
            }
            .frame(height: 18)
            .animation(.smooth(duration: 0.25), value: playing)
        }
    }
}

// MARK: - Player card
// Proportions measured from the reference: 360 x 164 pt, ~26 pt corners.
struct PlayerCard: View {
    @ObservedObject var model: NowPlayingModel
    @ObservedObject var settings: Settings
    var full: Bool = false
    @State private var dragFrac: Double?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var systemScheme

    /// true = white card (dark text), false = black card (white text)
    private var light: Bool {
        switch settings.tone {
        case .white: return true
        case .black: return false
        case .auto:  return systemScheme == .light
        }
    }

    /// true = dark text/buttons, false = white text/buttons (Automatic follows the card colour)
    private var darkText: Bool {
        switch settings.textTone {
        case .white: return false
        case .black: return true
        case .auto:  return light
        }
    }

    static let size = CGSize(width: 360, height: 164)
    /// Full-artwork layout: the normal compact card (same size, same position) with the artwork above it.
    static let artSize: CGFloat = 360   // same width as the card
    static let artGap: CGFloat = 40     // gap between artwork and card (artwork sits higher)
    /// Window = compact window (400 x 204, card at the bottom) + artwork stacked on top.
    static let fullWindowSize = CGSize(width: 400,
                                       height: 20 + artSize + artGap + size.height + 20)
    private var cardSize: CGSize { Self.size }
    private let corner: CGFloat = 26

    private var dragging: Bool { dragFrac != nil }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        let card = Group {
            if reduceTransparency {
                content.background(Color(white: light ? 0.92 : 0.09), in: shape)
            } else {
                content.lockGlass(cornerRadius: corner, dim: settings.dim, light: light)
            }
        }
        .overlay(
            GlassEdge(corner: corner, peak: 1.5, strength: settings.borderOpacity)
                .frame(width: cardSize.width, height: cardSize.height))
        // The window is always the full size and the card always sits at its bottom, so the card never moves.
        // In full-art mode the big artwork rises out of the top of the card (animated by CardRoot).
        card
            .overlay(alignment: .top) {
                if full {
                    artworkButton(bigArtwork, to: .compact)   // tap the big artwork -> back to compact
                        .offset(y: -(Self.artSize + Self.artGap))
                        .transition(.scale(scale: 0.5, anchor: .bottom).combined(with: .opacity))
                }
            }
            .padding(20)   // room for the glass shadow inside the window
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    private var bigArtwork: some View {
        Group {
            if let img = model.artwork {
                Image(nsImage: img).resizable().scaledToFill()
            } else {
                Rectangle().fill(Color.white.opacity(0.12))
                    .overlay(Image(systemName: "music.note").font(.system(size: 64)).opacity(0.6))
            }
        }
        .frame(width: Self.artSize, height: Self.artSize)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .shadow(color: .black.opacity(0.3), radius: 18, y: 8)
    }

    private var content: some View {
        compactContent
            .frame(width: cardSize.width, height: cardSize.height, alignment: .top)
            .foregroundStyle(.primary)
            .environment(\.colorScheme, darkText ? .light : .dark)
    }

    private var compactContent: some View {
        VStack(spacing: 0) {
            header
                .padding(.top, 13).padding(.leading, 13).padding(.trailing, 21)
            progress
                .padding(.top, 6).padding(.leading, 20).padding(.trailing, 21)
            controls
                .padding(.top, 9)
            Spacer(minLength: 0)
        }
    }

    // MARK: header
    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            if !full {
                artworkButton(artwork, to: .fullArt)           // tap the thumbnail -> full artwork view
                    .transition(.opacity)
            }
            VStack(alignment: .leading, spacing: 1) {
                Marquee(key: "title", alignment: full ? .center : .leading, height: 22) {
                    HStack(spacing: 5) {
                        Text(model.title)
                            .font(.system(size: 17, weight: .semibold))
                        if model.isExplicit { ExplicitBadge() }
                    }
                }
                Marquee(key: "creator", alignment: full ? .center : .leading, height: 20) {
                    Text(model.creator)
                        .font(.system(size: 16))
                        .foregroundStyle(Color.primary.opacity(0.5))
                }
            }
            // full mode: text is centred in the card (+8 pt leading evens out the header's 13/21 pt padding;
            // 34 pt on each side keeps long titles clear of the waveform)
            .padding(.horizontal, full ? 34 : 0)
            .padding(.leading, full ? 8 : 0)
            .frame(maxWidth: .infinity, minHeight: 57, maxHeight: 57, alignment: .center)
            if !full { WaveformBars(playing: model.isPlaying).padding(.top, 21) }
        }
        .overlay(alignment: .topTrailing) {
            if full { WaveformBars(playing: model.isPlaying).padding(.top, 21) }
        }
    }

    /// Wraps the artwork in a button that switches between compact and full-artwork view.
    private func artworkButton<V: View>(_ view: V, to mode: LockMode) -> some View {
        Button { settings.mode = mode } label: { view.contentShape(Rectangle()) }
            .buttonStyle(.plain)
    }

    private var artwork: some View {
        Group {
            if let img = model.artwork {
                Image(nsImage: img).resizable().scaledToFill()
            } else {
                Rectangle().fill(Color.primary.opacity(0.15))
                    .overlay(Image(systemName: "music.note").opacity(0.6))
            }
        }
        .frame(width: 57, height: 57)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: progress (thickens + whitens while scrubbing)
    private var progress: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
            let live = model.currentPosition(at: ctx.date)
            let frac = dragFrac ?? (model.duration > 0 ? live / model.duration : 0)
            let pos = dragFrac.map { $0 * model.duration } ?? live
            HStack(spacing: 8) {
                Text(fmt(pos))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(minWidth: 32, alignment: .leading)
                    .layoutPriority(1)
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color.primary.opacity(0.18))
                        Rectangle()
                            .fill(dragging ? Color.primary : Color.primary.opacity(0.62))
                            .frame(width: g.size.width * min(max(frac, 0), 1))
                    }
                    .frame(height: dragging ? 12 : 7)
                    .clipShape(Capsule())
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .overlay(
                        ScrubArea(
                            onMove: { f in
                                model.isScrubbing = true
                                dragFrac = f
                            },
                            onEnd: { f in
                                dragFrac = nil
                                model.seek(to: f * model.duration)
                            })
                    )
                    .animation(.smooth(duration: 0.2), value: dragging)
                }
                .frame(height: 24)
                Text("\u{2212}" + fmt(model.duration - pos))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(minWidth: 40, alignment: .trailing)
                    .layoutPriority(1)
            }
            .font(.system(size: 12, weight: .semibold).monospacedDigit())
            .foregroundStyle(dragging ? Color.primary : Color.primary.opacity(0.5))
            .animation(.smooth(duration: 0.2), value: dragging)
        }
    }

    // MARK: controls
    private var controls: some View {
        ZStack {
            HStack(spacing: 17.5) {
                control("backward.fill", 30) { model.previous() }
                control(model.isPlaying ? "pause.fill" : "play.fill", 36) { model.playPause() }
                control("forward.fill", 30) { model.next() }
            }
        }
        .frame(height: 40)
    }

    private func control(_ symbol: String, _ size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 56, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Native mouse handling for the seek bar (more reliable than SwiftUI gestures
// inside a borderless, non-activating overlay window)
struct ScrubArea: NSViewRepresentable {
    var onMove: (Double) -> Void
    var onEnd: (Double) -> Void

    func makeNSView(context: Context) -> ScrubNSView {
        let v = ScrubNSView()
        v.onMove = onMove; v.onEnd = onEnd
        return v
    }
    func updateNSView(_ v: ScrubNSView, context: Context) {
        v.onMove = onMove; v.onEnd = onEnd
    }
}

final class ScrubNSView: NSView {
    var onMove: ((Double) -> Void)?
    var onEnd: ((Double) -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    private func frac(_ e: NSEvent) -> Double {
        let x = convert(e.locationInWindow, from: nil).x
        return Double(min(max(x / max(bounds.width, 1), 0), 1))
    }
    override func mouseDown(with e: NSEvent)    { lpLog("scrub down"); onMove?(frac(e)) }
    override func mouseDragged(with e: NSEvent) { onMove?(frac(e)) }
    override func mouseUp(with e: NSEvent)      { lpLog("scrub up \(frac(e))"); onEnd?(frac(e)) }
}

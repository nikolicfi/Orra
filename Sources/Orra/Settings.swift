import Foundation

enum LockMode: String, CaseIterable {
    case compact, fullArt
    var title: String { self == .compact ? "Compact card" : "Full-screen artwork" }
}

enum GlassStyle: String, CaseIterable {
    case system, clear, tinted
    var title: String {
        switch self {
        case .system: return "Follow macOS setting"
        case .clear:  return "Clear"
        case .tinted: return "Tinted"
        }
    }
}

enum CardTone: String, CaseIterable {
    case black, white, auto
    var title: String {
        switch self {
        case .black: return "Black"
        case .white: return "White"
        case .auto:  return "Automatic"
        }
    }
}

/// Colour of the text, icons and buttons on the card (independent of the card tint).
enum TextTone: String, CaseIterable {
    case white, black, auto
    var title: String {
        switch self {
        case .white: return "White"
        case .black: return "Black"
        case .auto:  return "Automatic"
        }
    }
}

@MainActor
final class Settings: ObservableObject {
    @Published var mode: LockMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "mode") }
    }
    @Published var glass: GlassStyle {
        didSet { UserDefaults.standard.set(glass.rawValue, forKey: "glass") }
    }
    /// Card colour: black, white, or follow the macOS light/dark theme.
    @Published var tone: CardTone {
        didSet { UserDefaults.standard.set(tone.rawValue, forKey: "tone") }
    }
    /// Opacity of the colour layer behind the card, 0...1 (default 0.1).
    @Published var dim: Double {
        didSet { UserDefaults.standard.set(dim, forKey: "dim") }
    }
    /// Background blur amount, 0...1 (menu offers 0-100 % in 10 % steps).
    @Published var blur: Double {
        didSet { UserDefaults.standard.set(blur, forKey: "blur") }
    }
    /// Text / icon / button colour: white, black, or automatic (follows the card colour).
    @Published var textTone: TextTone {
        didSet { UserDefaults.standard.set(textTone.rawValue, forKey: "textTone") }
    }
    /// Opacity of the white glass border, 0...1 (1 = full strength, 0 = no border).
    @Published var borderOpacity: Double {
        didSet { UserDefaults.standard.set(borderOpacity, forKey: "borderOpacity") }
    }
    init() {
        // Defaults on first launch (everything stays adjustable from the menu afterwards).
        // Bump styleVersion to roll new defaults out to existing installs once.
        let d = UserDefaults.standard
        if d.integer(forKey: "styleVersion") < 4 {
            d.set(CardTone.white.rawValue, forKey: "tone")   // white card
            d.set(TextTone.white.rawValue, forKey: "textTone") // white text & buttons
            d.set(0.3, forKey: "borderOpacity")              // opacity 30 %
            d.set(0.1, forKey: "dim")                        // dimming 0.1
            d.set(0.2, forKey: "blur")                       // blur 20 %
            d.set(4, forKey: "styleVersion")
        }
        tone = CardTone(rawValue: UserDefaults.standard.string(forKey: "tone") ?? "") ?? .white
        dim  = UserDefaults.standard.object(forKey: "dim") as? Double ?? 0.1
        blur = UserDefaults.standard.object(forKey: "blur") as? Double ?? 0.2
        textTone = TextTone(rawValue: UserDefaults.standard.string(forKey: "textTone") ?? "") ?? .white
        borderOpacity = UserDefaults.standard.object(forKey: "borderOpacity") as? Double ?? 0.3
        glass = GlassStyle(rawValue: UserDefaults.standard.string(forKey: "glass") ?? "") ?? .clear
        mode = LockMode(rawValue: UserDefaults.standard.string(forKey: "mode") ?? "") ?? .compact
    }
}

import SwiftUI

// Light, calm palette: warm paper background, white cards, soft shadows,
// a single confident green accent, muted supporting colors.
enum Theme {
    static let bg = Color(hex: 0xF6F7F2)        // warm paper
    static let bg2 = Color(hex: 0xEEF1E8)       // slightly deeper paper
    static let panel = Color.white
    static let line = Color(hex: 0xE5E8DE)      // hairline
    static let ink = Color(hex: 0x25301F)       // deep green-gray text
    static let inkDim = Color(hex: 0x8A9384)    // secondary text
    static let lime = Color(hex: 0x2E9C5C)      // primary accent (fresh green)
    static let limeDim = Color(hex: 0x8FCBA8)
    static let magenta = Color(hex: 0xE2647F)   // captain rose
    static let cyan = Color(hex: 0x5490BC)      // info blue
    static let red = Color(hex: 0xD96057)
    static let amber = Color(hex: 0xDD9A3E)
    static let green = Color(hex: 0x2E9C5C)
    static let pitchDark = Color(hex: 0xCFE7C6)  // soft pitch stripes
    static let pitchLight = Color(hex: 0xD9EDD0)

    static let teamColors: [String: Color] = [
        "ARS": Color(hex: 0xEF0107), "AVL": Color(hex: 0x67122e), "BOU": Color(hex: 0xB50E12),
        "BRE": Color(hex: 0xe30613), "BHA": Color(hex: 0x0057B8), "CHE": Color(hex: 0x034694),
        "COV": Color(hex: 0x59a3d8), "CRY": Color(hex: 0x1B458F), "EVE": Color(hex: 0x003399),
        "FUL": Color(hex: 0x37383b), "HUL": Color(hex: 0xf18a00), "IPS": Color(hex: 0x3a64a3),
        "LEE": Color(hex: 0xc8a24c), "LIV": Color(hex: 0xC8102E), "MCI": Color(hex: 0x6CABDD),
        "MUN": Color(hex: 0xDA291C), "NEW": Color(hex: 0x241F20), "NFO": Color(hex: 0xDD0000),
        "TOT": Color(hex: 0x132257), "SUN": Color(hex: 0xeb172b), "WHU": Color(hex: 0x7A263A),
        "WOL": Color(hex: 0xFDB913), "BUR": Color(hex: 0x6C1D45), "SOU": Color(hex: 0xD71920),
        "LEI": Color(hex: 0x003090),
    ]

    static func teamColor(_ short: String) -> Color {
        teamColors[short] ?? Color(hex: 0x9AA694)
    }

    static func diffColor(_ d: Int) -> Color {
        switch d {
        case 2: return green
        case 4: return amber
        case 5: return red
        default: return Color(hex: 0x97A091)
        }
    }
}

extension Color {
    init(hex: UInt) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

extension Font {
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
    static func label(_ size: CGFloat = 10) -> Font {
        .system(size: size, weight: .semibold)
    }
}

struct PanelStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Theme.panel)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.line, lineWidth: 1))
            .shadow(color: Color.black.opacity(0.04), radius: 10, x: 0, y: 3)
    }
}

extension View {
    func panel() -> some View { modifier(PanelStyle()) }
}

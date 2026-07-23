import SwiftUI

enum Theme {
    static let bg = Color(red: 0.039, green: 0.055, blue: 0.043)        // #0A0E0B
    static let bg2 = Color(red: 0.063, green: 0.086, blue: 0.063)       // #101610
    static let panel = Color(red: 0.075, green: 0.106, blue: 0.078)     // #131B14
    static let line = Color(red: 0.141, green: 0.188, blue: 0.122)      // #24301F
    static let ink = Color(red: 0.929, green: 0.953, blue: 0.894)       // #EDF3E4
    static let inkDim = Color(red: 0.557, green: 0.627, blue: 0.541)    // #8EA08A
    static let lime = Color(red: 0.831, green: 1.0, blue: 0.247)        // #D4FF3F
    static let limeDim = Color(red: 0.616, green: 0.749, blue: 0.165)   // #9DBF2A
    static let magenta = Color(red: 1.0, green: 0.239, blue: 0.541)     // #FF3D8A
    static let cyan = Color(red: 0.310, green: 0.847, blue: 0.878)      // #4FD8E0
    static let red = Color(red: 1.0, green: 0.365, blue: 0.365)         // #FF5D5D
    static let amber = Color(red: 1.0, green: 0.722, blue: 0.310)       // #FFB84F
    static let green = Color(red: 0.435, green: 0.890, blue: 0.533)     // #6FE388
    static let pitchDark = Color(red: 0.075, green: 0.137, blue: 0.086)
    static let pitchLight = Color(red: 0.086, green: 0.157, blue: 0.102)

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
        teamColors[short] ?? Color(hex: 0x3a4a38)
    }

    static func diffColor(_ d: Int) -> Color {
        switch d {
        case 2: return green
        case 4: return amber
        case 5: return red
        default: return inkDim
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
        .system(size: size, weight: weight, design: .monospaced)
    }
    static func label(_ size: CGFloat = 10) -> Font {
        .system(size: size, weight: .semibold)
    }
}

struct PanelStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Theme.panel)
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.line, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

extension View {
    func panel() -> some View { modifier(PanelStyle()) }
}

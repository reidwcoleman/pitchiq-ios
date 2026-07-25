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

    /// Green → red across the 1-5 fixture difficulty scale.
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


// MARK: - shared building blocks

/// Section heading: small, tracked, quiet. Used everywhere a card starts.
struct SectionLabel: View {
    let text: String
    var accent: Color = Theme.inkDim
    var body: some View {
        Text(text.uppercased())
            .font(.label(9)).tracking(1.6)
            .foregroundColor(accent)
    }
}

/// A number with a caption underneath — the app's basic unit of information.
struct StatTile: View {
    let value: String
    let caption: String
    var color: Color = Theme.lime
    var footnote: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.mono(22, .bold)).foregroundColor(color)
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(caption.uppercased())
                .font(.label(8.5)).tracking(1.1).foregroundColor(Theme.inkDim)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            if let footnote {
                Text(footnote).font(.system(size: 10)).foregroundColor(Theme.inkDim.opacity(0.85))
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13)
        .panel()
    }
}

/// Small coloured pill used for positions, chips, verdicts.
struct Tag: View {
    let text: String
    var color: Color = Theme.lime
    var filled = false

    var body: some View {
        Text(text)
            .font(.mono(9, .bold))
            .foregroundColor(filled ? .white : color)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(filled ? color : color.opacity(0.13))
            .clipShape(Capsule())
    }
}

/// A horizontal 0…1 meter. Reads faster than a percentage on its own.
struct Meter: View {
    let fraction: Double
    var color: Color = Theme.lime
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.bg2)
                Capsule().fill(color)
                    .frame(width: max(geo.size.width * min(max(fraction, 0), 1), 2))
            }
        }
        .frame(height: height)
    }
}

/// Empty-state block, so a tool that has nothing to say still says something.
struct EmptyNote: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 22)).foregroundColor(Theme.limeDim)
            Text(title).font(.system(size: 14, weight: .bold)).foregroundColor(Theme.ink)
            Text(detail)
                .font(.system(size: 12.5)).foregroundColor(Theme.inkDim)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28).padding(.horizontal, 22)
        .panel()
    }
}

extension Position {
    var color: Color {
        switch self {
        case .gk: return Theme.amber
        case .def: return Theme.cyan
        case .mid: return Theme.lime
        case .fwd: return Theme.magenta
        }
    }
}

extension Player {
    var posColor: Color { Position(rawValue: pos)?.color ?? Theme.inkDim }
}

import SwiftUI

// MARK: - Design system
//
// One palette, one type scale, one spacing scale, and every colour defined in
// both appearances. The app used to be a set of hard-coded light values with
// `.preferredColorScheme(.light)` bolted on top, which is a way of saying "we
// never finished this" to anyone who runs their phone dark — which, for a
// football app opened on a Saturday evening, is most people.
//
// The identity is unchanged: warm paper, one confident green, muted supporting
// colours. Dark mode is not a tint of it; it is the same idea built from a
// deep pitch-green rather than an inverted grey.

extension Color {
    /// A colour that resolves differently in each appearance.
    init(light: UInt, dark: UInt) {
        self.init(uiColor: UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }

    init(hex: UInt) { self.init(uiColor: UIColor(hex: hex)) }
}

extension UIColor {
    convenience init(hex: UInt) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: 1)
    }
}

enum Theme {

    // MARK: surfaces
    //
    // Three levels, and they mean different things in each appearance. In light
    // the page is warm paper and cards lift off it with white and a shadow; in
    // dark the page is nearly black and cards lift by getting *lighter*, since
    // shadows do nothing on a dark ground.

    static let bg = Color(light: 0xF6F7F2, dark: 0x0D110F)
    static let bg2 = Color(light: 0xEBEFE4, dark: 0x151B17)
    static let panel = Color(light: 0xFFFFFF, dark: 0x1A211C)
    static let panelRaised = Color(light: 0xFFFFFF, dark: 0x222A24)
    static let line = Color(light: 0xE3E7DB, dark: 0x2B342D)
    static let lineStrong = Color(light: 0xD2D8C8, dark: 0x3A453D)

    // MARK: ink

    static let ink = Color(light: 0x1E2A1A, dark: 0xEEF3EB)
    static let inkDim = Color(light: 0x7C8878, dark: 0x8B9789)
    static let inkFaint = Color(light: 0xA9B3A4, dark: 0x616C5F)

    // MARK: accents

    static let lime = Color(light: 0x2E9C5C, dark: 0x45C97E)
    static let limeDim = Color(light: 0x8FCBA8, dark: 0x2C6E48)
    static let magenta = Color(light: 0xD6486A, dark: 0xF2718F)
    static let cyan = Color(light: 0x3F81B0, dark: 0x69AEDC)
    static let red = Color(light: 0xD2483E, dark: 0xF07268)
    static let amber = Color(light: 0xC8862A, dark: 0xEBAE4E)
    static let green = lime

    // MARK: the pitch

    static let pitchDeep = Color(light: 0x2E7D4F, dark: 0x123322)
    static let pitchLight = Color(light: 0x389059, dark: 0x17402A)
    static let pitchLine = Color(light: 0xFFFFFF, dark: 0xB9D6C5)

    // MARK: shadows
    //
    // Light mode lifts with a soft shadow. Dark mode cannot — a black shadow on
    // a black page is invisible — so it lifts with a hairline instead, and the
    // shadow opacity drops to nothing.

    static func cardShadow(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .clear : Color(hex: 0x2A3B26).opacity(0.07)
    }

    static let teamColors: [String: Color] = [
        "ARS": Color(hex: 0xEF0107), "AVL": Color(hex: 0x95BFE5), "BOU": Color(hex: 0xB50E12),
        "BRE": Color(hex: 0xe30613), "BHA": Color(hex: 0x0057B8), "CHE": Color(hex: 0x034694),
        "COV": Color(hex: 0x59a3d8), "CRY": Color(hex: 0x1B458F), "EVE": Color(hex: 0x003399),
        "FUL": Color(hex: 0x7A7C80), "HUL": Color(hex: 0xf18a00), "IPS": Color(hex: 0x3a64a3),
        "LEE": Color(hex: 0xc8a24c), "LIV": Color(hex: 0xC8102E), "MCI": Color(hex: 0x6CABDD),
        "MUN": Color(hex: 0xDA291C), "NEW": Color(hex: 0x41474C), "NFO": Color(hex: 0xDD0000),
        "TOT": Color(hex: 0x8E96AC), "SUN": Color(hex: 0xeb172b), "WHU": Color(hex: 0x7A263A),
        "WOL": Color(hex: 0xFDB913), "BUR": Color(hex: 0x6C1D45), "SOU": Color(hex: 0xD71920),
        "LEI": Color(hex: 0x003090),
    ]

    static func teamColor(_ short: String) -> Color {
        teamColors[short] ?? Color(light: 0x8D9A88, dark: 0x6E7C6A)
    }

    /// Green → red across the 1-5 fixture difficulty scale.
    static func diffColor(_ d: Int) -> Color {
        switch d {
        case 1: return green
        case 2: return green
        case 4: return amber
        case 5: return red
        default: return Color(light: 0x8D9A88, dark: 0x768372)
        }
    }

    // MARK: spacing
    //
    // Six steps. Anything not on the scale is a mistake, and before this there
    // were padding values of 5, 6, 7, 8, 10, 11, 12, 13, 14 and 16 in the same
    // three screens.

    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 22
        static let xxl: CGFloat = 30
    }

    enum Radius {
        static let small: CGFloat = 8
        static let card: CGFloat = 18
        static let chip: CGFloat = 11
    }
}

// MARK: - type scale

extension Font {
    /// Rounded, tabular figures. Every number in the app uses this, so columns
    /// of them line up instead of shivering as the digits change.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
    static func label(_ size: CGFloat = 10) -> Font {
        .system(size: size, weight: .semibold)
    }

    /// The scale. Named by role, not by size, so a heading can be retuned in
    /// one place instead of in forty call sites.
    static let display = Font.system(size: 30, weight: .black, design: .rounded)
    static let title = Font.system(size: 20, weight: .heavy)
    static let headline = Font.system(size: 16, weight: .bold)
    static let bodyText = Font.system(size: 14)
    static let small = Font.system(size: 12.5)
    static let caption = Font.system(size: 11)
}

extension View {
    /// Digits that do not change width as they change value.
    func figures() -> some View { monospacedDigit() }
}

// MARK: - surfaces

struct PanelStyle: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    var radius: CGFloat = Theme.Radius.card
    var raised = false

    func body(content: Content) -> some View {
        content
            .background(raised ? Theme.panelRaised : Theme.panel)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(Theme.line, lineWidth: 1)
            )
            .shadow(color: Theme.cardShadow(scheme), radius: 14, x: 0, y: 5)
    }
}

/// A card that carries an accent: a hairline in the accent colour and the
/// faintest wash of it behind, so the important card on a screen reads as
/// important without shouting.
struct AccentPanelStyle: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    let accent: Color

    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    Theme.panel
                    LinearGradient(colors: [accent.opacity(scheme == .dark ? 0.16 : 0.09),
                                            accent.opacity(0)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .stroke(accent.opacity(scheme == .dark ? 0.45 : 0.32), lineWidth: 1)
            )
            .shadow(color: Theme.cardShadow(scheme), radius: 14, x: 0, y: 5)
    }
}

extension View {
    func panel(radius: CGFloat = Theme.Radius.card, raised: Bool = false) -> some View {
        modifier(PanelStyle(radius: radius, raised: raised))
    }
    func accentPanel(_ accent: Color) -> some View {
        modifier(AccentPanelStyle(accent: accent))
    }
}

// MARK: - shared building blocks

/// Section heading: small, tracked, quiet. Used everywhere a card starts.
struct SectionLabel: View {
    let text: String
    var accent: Color = Theme.inkDim
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9.5, weight: .heavy))
            .tracking(1.5)
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
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.mono(23, .heavy)).foregroundColor(color).figures()
                .lineLimit(1).minimumScaleFactor(0.55)
            Text(caption.uppercased())
                .font(.system(size: 8.5, weight: .heavy)).tracking(1.1)
                .foregroundColor(Theme.inkDim)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            if let footnote {
                Text(footnote).font(.system(size: 10)).foregroundColor(Theme.inkFaint)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.m)
        .background(Theme.bg2)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
    }
}

/// Small coloured pill used for positions, chips, verdicts.
struct Tag: View {
    let text: String
    var color: Color = Theme.lime
    var filled = false

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .black)).tracking(0.4)
            .foregroundColor(filled ? .white : color)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(filled ? color : color.opacity(0.15))
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
                Capsule().fill(Theme.line)
                Capsule()
                    .fill(LinearGradient(colors: [color.opacity(0.75), color],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(geo.size.width * min(max(fraction, 0), 1), 3))
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
        VStack(spacing: Theme.Space.s) {
            Image(systemName: icon)
                .font(.system(size: 24, weight: .light))
                .foregroundColor(Theme.limeDim)
            Text(title).font(.headline).foregroundColor(Theme.ink)
            Text(detail)
                .font(.small).foregroundColor(Theme.inkDim)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Space.xxl).padding(.horizontal, Theme.Space.xl)
        .panel()
    }
}

/// The app's segmented control. The system one cannot be tinted to match a
/// palette without fighting UIKit, and it is on four screens.
struct SegmentBar: View {
    let titles: [String]
    @Binding var selection: Int
    var accent: Color = Theme.lime
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(titles.indices, id: \.self) { i in
                let active = selection == i
                Text(titles[i])
                    .font(.system(size: 13.5, weight: active ? .bold : .semibold))
                    .foregroundColor(active ? Theme.ink : Theme.inkDim)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background {
                        if active {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(Theme.panel)
                                .shadow(color: .black.opacity(0.07), radius: 3, y: 1)
                                .matchedGeometryEffect(id: "seg", in: ns)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        Haptics.select()
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                            selection = i
                        }
                    }
            }
        }
        .padding(3)
        .background(Theme.bg2)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

enum Haptics {
    static func select() {
        UISelectionFeedbackGenerator().selectionChanged()
    }
    static func tap(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }
    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
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

// MARK: - loading

/// A shape of the screen that is coming, pulsing gently. A bare spinner on an
/// empty page tells the reader nothing about what they are waiting for; a
/// skeleton tells them it is a card, a rail and a team.
struct LoadingSkeleton: View {
    @State private var on = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            block(height: 128)
            HStack(spacing: 6) {
                ForEach(0..<5, id: \.self) { _ in block(height: 74, radius: 13) }
            }
            block(height: 300)
        }
        .opacity(on ? 0.95 : 0.55)
        .animation(.easeInOut(duration: 1.05).repeatForever(autoreverses: true), value: on)
        .onAppear { on = true }
        .accessibilityLabel("Loading")
    }

    func block(height: CGFloat, radius: CGFloat = Theme.Radius.card) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Theme.bg2)
            .frame(maxWidth: .infinity)
            .frame(height: height)
    }
}

/// A paragraph of explanation folded behind a quiet toggle.
///
/// The app knows a great deal about why it says what it says, and it was
/// telling you all of it before you had seen a single row. Explanation is
/// worth keeping and worth hiding: the reader who wants it taps once, and the
/// reader who doesn't gets to the list.
struct WhyNote: View {
    let text: String
    var label = "Why this list"
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Button {
                Haptics.tap()
                withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) { open.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "info.circle").font(.system(size: 10, weight: .bold))
                    Text(label).font(.system(size: 11, weight: .bold))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .black))
                        .rotationEffect(.degrees(open ? 180 : 0))
                }
                .foregroundColor(Theme.inkDim)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                Text(.init(text))
                    .font(.system(size: 11.5)).foregroundColor(Theme.inkDim)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

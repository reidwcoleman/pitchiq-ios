import SwiftUI

enum SquadSheet: Identifiable {
    case detail(Player, canSwap: Bool)
    case swap(Player)
    var id: Int {
        switch self {
        case .detail(let p, _): return p.id
        case .swap(let p): return -p.id
        }
    }
}

/// The Team tab: pick any gameweek in the plan and see the exact squad to hold
/// that week, the single instruction that gets you there, and the reasoning.
struct SquadView: View {
    @EnvironmentObject var state: AppState
    @State private var sheet: SquadSheet?
    @State private var selected = 0

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                AppHeader(subtitle: state.squadSource)
                if let plan = state.plan, !plan.gws.isEmpty {
                    let idx = min(selected, plan.gws.count - 1)
                    let gp = plan.gws[idx]
                    let isFirst = idx == 0

                    ActionCard(gwPlan: gp, isFirst: isFirst, plan: plan)
                        .padding(.horizontal, 14)
                    gwPicker(plan, idx: idx)
                    PitchGrid(xi: gp.xi, captainId: gp.captain.id, viceId: viceId(gp)) { p in
                        sheet = .detail(p, canSwap: isFirst && !state.isConnected)
                    }
                    .padding(.horizontal, 14)
                    BenchRow(bench: gp.bench, boosted: gp.chip == "bboost") { p in
                        sheet = .detail(p, canSwap: isFirst && !state.isConnected)
                    }
                    .padding(.horizontal, 14)
                    gwTiles(gp).padding(.horizontal, 14)
                    ReasonCard(title: "Why", notes: gp.reasons).padding(.horizontal, 14)
                    SelectionCard().padding(.horizontal, 14)
                    ChipStrip(plan: plan).padding(.horizontal, 14)
                    SeasonSummary(plan: plan).padding(.horizontal, 14)
                } else if case .loading = state.phase {
                    LoadingSkeleton().padding(.horizontal, 14)
                } else {
                    EmptyNote(icon: "questionmark.circle",
                              title: "No feasible squad",
                              detail: "Raise the budget or allow flagged players in Settings.")
                        .padding(.horizontal, 14)
                }
            }
            .padding(.bottom, 26)
        }
        .background(Theme.bg)
        .onChange(of: state.gwFrom) { _ in selected = 0 }
        .sheet(item: $sheet) { s in
            switch s {
            case .detail(let p, let canSwap):
                PlayerDetailSheet(player: p, canSwap: canSwap) { out in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { sheet = .swap(out) }
                }
            case .swap(let p):
                SwapSheet(out: p)
            }
        }
    }

    func viceId(_ gp: GWPlan) -> Int {
        let sorted = gp.xi.sorted { $0.proj > $1.proj }
        return sorted.count > 1 ? sorted[1].id : -1
    }

    /// The season as a rail you scrub through. Each gameweek shows its
    /// projected score as a column whose height is that score against the best
    /// week on the rail, so the shape of the run is visible at a glance —
    /// previously they were six identical white boxes with a number in them and
    /// the shape of the season was invisible.
    func gwPicker(_ plan: SeasonPlan, idx: Int) -> some View {
        let peak = max(plan.gws.map(\.projPts).max() ?? 1, 1)
        let floor = min(plan.gws.map(\.projPts).min() ?? 0, peak - 1)
        return VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionLabel(text: "The season ahead").padding(.horizontal, Theme.Space.l)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(plan.gws.enumerated()), id: \.element.gw) { i, gp in
                        Button {
                            Haptics.select()
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                selected = i
                            }
                        } label: {
                            gwChip(gp, active: i == idx,
                                   height: (gp.projPts - floor) / max(peak - floor, 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, Theme.Space.l)
                .padding(.vertical, 2)
            }
        }
    }

    func gwChip(_ gp: GWPlan, active: Bool, height: Double) -> some View {
        let accent: Color = gp.chip != nil ? Theme.magenta
            : (gp.transfers.isEmpty ? Theme.inkFaint : Theme.cyan)
        return VStack(spacing: 4) {
            Text("GW \(gp.gw)")
                .font(.system(size: 9.5, weight: .heavy)).figures()
                .foregroundColor(active ? .white.opacity(0.9) : Theme.inkDim)
            Text(String(format: "%.0f", gp.projPts))
                .font(.mono(17, .heavy)).figures()
                .foregroundColor(active ? .white : Theme.ink)
            // this week's score against the best week on the rail
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(active ? Color.white.opacity(0.28) : Theme.line)
                    .frame(height: 3)
                Capsule()
                    .fill(active ? Color.white : Theme.lime)
                    .frame(width: 8 + 26 * min(max(height, 0), 1), height: 3)
            }
            .frame(width: 34)
            Group {
                if let chip = gp.chip {
                    Text(chipShortName(chip))
                        .font(.system(size: 8, weight: .black)).foregroundColor(.white)
                        .padding(.horizontal, 5).padding(.vertical, 1.5)
                        .background(Theme.magenta).clipShape(Capsule())
                } else if !gp.transfers.isEmpty {
                    HStack(spacing: 2) {
                        Image(systemName: "arrow.left.arrow.right")
                            .font(.system(size: 6.5, weight: .black))
                        Text("\(gp.transfers.count)").font(.system(size: 8.5, weight: .black))
                    }
                    .foregroundColor(active ? .white.opacity(0.92) : accent)
                } else {
                    Text("hold").font(.system(size: 8.5, weight: .bold))
                        .foregroundColor(active ? .white.opacity(0.75) : Theme.inkFaint)
                }
            }
            .frame(height: 12)
        }
        .frame(width: 58)
        .padding(.vertical, 8)
        .background(active ? Theme.lime : Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(active ? Color.clear : Theme.line, lineWidth: 1)
        )
        .shadow(color: active ? Theme.lime.opacity(0.3) : .clear, radius: 8, y: 3)
    }

    func gwTiles(_ gp: GWPlan) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            StatTile(value: String(format: "%.0f", gp.projPts),
                     caption: "GW \(gp.gw) projected", color: Theme.lime,
                     footnote: "Best XI with the captain doubled\(gp.hitPts > 0 ? ", after a −\(gp.hitPts) hit" : "").")
            StatTile(value: gp.formation, caption: "Formation", color: Theme.cyan,
                     footnote: "Auto-picked from who scores most this week.")
            StatTile(value: "\(gp.ftsLeft)", caption: "Free transfers", color: Theme.cyan,
                     footnote: gp.ftsLeft >= 5 ? "At the cap — an unused one is lost." : "Bank up to five.")
            StatTile(value: String(format: "£%.1fm", Double(gp.bank) / 10),
                     caption: "In the bank",
                     color: gp.bank >= 15 ? Theme.amber : Theme.lime,
                     footnote: gp.bank >= 15 ? "Idle money scores nothing." : "Little left over — fully invested.")
        }
    }
}

// MARK: - the week's instruction

struct ActionCard: View {
    @EnvironmentObject var state: AppState
    let gwPlan: GWPlan
    let isFirst: Bool
    let plan: SeasonPlan
    @State private var expanded = false

    /// A wildcard is fifteen rows, and fifteen rows of small print pushed the
    /// one thing the screen exists for — your team — clean off the bottom of
    /// the phone. Long lists start folded.
    private var foldLimit: Int { 4 }
    private var needsFolding: Bool { gwPlan.transfers.count > foldLimit }
    private var shown: [TransferMove] {
        needsFolding && !expanded ? Array(gwPlan.transfers.prefix(foldLimit)) : gwPlan.transfers
    }

    var accent: Color {
        if gwPlan.chip != nil { return Theme.magenta }
        if gwPlan.hitPts > 0 { return Theme.amber }
        return gwPlan.transfers.isEmpty ? Theme.cyan : Theme.lime
    }

    var icon: String {
        switch gwPlan.chip {
        case "wildcard": return "wand.and.stars"
        case "freehit": return "sparkles"
        case "bboost": return "person.3.fill"
        case "3xc": return "crown.fill"
        default: return gwPlan.transfers.isEmpty ? "tray.and.arrow.down.fill" : "arrow.left.arrow.right"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                SectionLabel(text: isFirst ? "Do this now · GW \(gwPlan.gw)" : "GW \(gwPlan.gw)",
                             accent: accent)
                Spacer()
                if let chip = gwPlan.chip {
                    Tag(text: chipDisplayName(chip).uppercased(), color: Theme.magenta, filled: true)
                }
            }
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon).font(.system(size: 17, weight: .semibold))
                    .foregroundColor(accent).frame(width: 24)
                Text(gwPlan.action)
                    .font(.system(size: 18, weight: .heavy)).foregroundColor(Theme.ink)
                    .lineSpacing(1)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !gwPlan.transfers.isEmpty {
                VStack(spacing: 6) {
                    ForEach(shown) { t in TransferRow(move: t, chip: gwPlan.chip) }
                }
                if needsFolding {
                    Button {
                        Haptics.tap()
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                            expanded.toggle()
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Text(expanded
                                 ? "Show fewer"
                                 : "Show all \(gwPlan.transfers.count) moves")
                            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 9, weight: .black))
                        }
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(accent)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity)
                        .background(accent.opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            if gwPlan.transfers.isEmpty && gwPlan.chip == nil,
               let next = plan.firstMoveGw, next > gwPlan.gw {
                let weeks = next - gwPlan.gw
                Text("Next change: GW \(next), \(weeks) gameweek\(weeks == 1 ? "" : "s") away. Until then the free transfers bank — the plan spends \(plan.totalTransfers) of them across the season as fixture runs turn.")
                    .font(.system(size: 12)).foregroundColor(Theme.inkDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if isFirst, state.isConnected, !gwPlan.transfers.isEmpty {
                HandoffButton(
                    summary: gwPlan.transfers
                        .map { "\($0.out.name) → \($0.inn.name)" }
                        .joined(separator: ", "),
                    title: gwPlan.chip == nil ? "Make it in FPL" : "Open FPL",
                    accent: accent)
                    .padding(.top, 2)
            }
            if isFirst && !state.isConnected {
                Text("Connect your FPL team in Settings and this becomes advice on your own fifteen instead of a suggested squad.")
                    .font(.system(size: 11.5)).foregroundColor(Theme.inkDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accentPanel(accent)
    }
}

struct TransferRow: View {
    let move: TransferMove
    var chip: String?

    var body: some View {
        HStack(spacing: 6) {
            if move.out.flagged {
                Image(systemName: "cross.case.fill").font(.system(size: 9)).foregroundColor(Theme.red)
            }
            TeamBadge(teamId: move.out.team, size: 15).opacity(0.55)
            Text(move.out.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Theme.inkDim).strikethrough()
                .lineLimit(1)
            Image(systemName: "arrow.right").font(.system(size: 9, weight: .black))
                .foregroundColor(Theme.lime)
            TeamBadge(teamId: move.inn.team, size: 15)
            Text(move.inn.name).font(.system(size: 13, weight: .bold))
                .foregroundColor(Theme.ink).lineLimit(1)
            Text("£\(move.inn.price)").font(.mono(10, .medium))
                .foregroundColor(Theme.inkFaint).figures()
            Spacer(minLength: 4)
            if chip != "wildcard" {
                Text(String(format: "%+.1f", move.gain))
                    .font(.mono(11, .bold))
                    .foregroundColor(move.gain >= 0 ? Theme.green : Theme.red)
            }
            if chip == "wildcard" {
                Tag(text: "WC", color: Theme.magenta)
            } else {
                Tag(text: move.paid ? "−4" : "FREE",
                    color: move.paid ? Theme.red : Theme.lime, filled: move.paid)
            }
        }
    }
}

// MARK: - reasoning

struct ReasonCard: View {
    let title: String
    let notes: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: title).padding(.bottom, 8)
            ForEach(Array(notes.enumerated()), id: \.offset) { i, n in
                HStack(alignment: .top, spacing: Theme.Space.s) {
                    Circle().fill(Theme.lime).frame(width: 4, height: 4)
                        .padding(.top, 6)
                    Text(n).font(.system(size: 13)).foregroundColor(Theme.ink)
                        .lineSpacing(2.5)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, Theme.Space.s)
                if i < notes.count - 1 {
                    Rectangle().fill(Theme.line).frame(height: 1)
                }
            }
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }
}

// MARK: - how the squad was chosen

/// The selection is measured, not asserted: several ways of valuing a player
/// are tried and each resulting squad is played through the rest of the season
/// before one is picked. Showing the alternatives and what they scored is the
/// only honest way to present that.
struct SelectionCard: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        let trials = state.insights.openingTrials
        if state.isConnected || trials.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 11) {
                SectionLabel(text: "How this XV was chosen")
                Text("Three ways of weighing the season were tried. Each built a squad, and each squad was played through every remaining gameweek — transfers, chips, injuries and blanks included. The highest score wins.")
                    .font(.system(size: 12)).foregroundColor(Theme.inkDim)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(trials) { t in
                    HStack(spacing: 9) {
                        Image(systemName: t.profile == state.insights.chosenProfile
                              ? "largecircle.fill.circle" : "circle")
                            .font(.system(size: 12))
                            .foregroundColor(t.profile == state.insights.chosenProfile
                                             ? Theme.lime : Theme.line)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(t.profile).font(.system(size: 13, weight: .bold))
                                .foregroundColor(Theme.ink)
                            Text(t.blurb).font(.system(size: 10.5)).foregroundColor(Theme.inkDim)
                                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 6)
                        Text(String(format: "%.0f", t.points))
                            .font(.mono(14, .bold))
                            .foregroundColor(t.profile == state.insights.chosenProfile
                                             ? Theme.lime : Theme.inkDim)
                    }
                }
                if state.insights.chosenProfile == "Your current XV" {
                    Divider().background(Theme.line)
                    Text("Your fifteen is within \(Int(AppState.switchMargin)) points of the best alternative across the whole run, so it keeps its place. A squad that rebuilds itself every time a price ticks loses more to transfers than it gains.")
                        .font(.system(size: 12)).foregroundColor(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider().background(Theme.line)
                Text("Every projection behind those numbers is built per gameweek from that player's own fixtures — home or away, against that specific opponent's attack and defence — blended with his minutes security, expected goals and assists per 90, FPL's threat, creativity and BPS indices, set-piece and penalty duty, bonus rate, cards, and recent form.")
                    .font(.system(size: 11.5)).foregroundColor(Theme.inkDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .panel()
        }
    }
}

// MARK: - chips

struct ChipStrip: View {
    let plan: SeasonPlan

    /// You get two of each chip a season, so held ones come in pairs — listing
    /// "Free Hit, Free Hit" reads like a bug.
    var heldSummary: String {
        var counts: [String: Int] = [:]
        for c in plan.heldChips { counts[c, default: 0] += 1 }
        return counts.keys.sorted()
            .map { counts[$0]! > 1 ? "\(chipDisplayName($0)) ×\(counts[$0]!)" : chipDisplayName($0) }
            .joined(separator: ", ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "Chip plan")
            if plan.chips.isEmpty {
                Text("Nothing scheduled yet. A chip is only worth playing when it clearly gains points, and on today's fixtures no week is worth one. They're re-checked every refresh, and as each deadline nears the bar drops so none expire unused.")
                    .font(.system(size: 12.5)).foregroundColor(Theme.inkDim)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(plan.chips) { c in
                    HStack(spacing: 9) {
                        Tag(text: chipShortName(c.chip), color: Theme.magenta, filled: true)
                        Text(chipDisplayName(c.chip))
                            .font(.system(size: 13, weight: .bold)).foregroundColor(Theme.ink)
                        Text("GW \(c.gw)").font(.mono(11, .medium)).foregroundColor(Theme.inkDim)
                        Spacer()
                        if c.forced {
                            Text("before it expires").font(.system(size: 10)).foregroundColor(Theme.amber)
                        }
                        Text(String(format: "+%.0f", c.gain))
                            .font(.mono(12, .bold)).foregroundColor(Theme.green)
                    }
                }
            }
            if !plan.heldChips.isEmpty {
                Divider().background(Theme.line)
                Text("Held back: \(heldSummary). Nothing in their windows clears the bar yet — double gameweeks in particular only get announced once postponed matches are rescheduled.")
                    .font(.system(size: 12)).foregroundColor(Theme.inkDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }
}

struct SeasonSummary: View {
    let plan: SeasonPlan

    var body: some View {
        HStack(spacing: 10) {
            StatTile(value: String(format: "%.0f", plan.totalPts),
                     caption: "Projected to GW38", color: Theme.lime)
            StatTile(value: String(format: "%.0f", plan.perGw),
                     caption: "Per gameweek", color: Theme.cyan)
            StatTile(value: "\(plan.totalTransfers)",
                     caption: plan.totalHits > 0 ? "Transfers · −\(plan.totalHits)" : "Transfers · no hits",
                     color: Theme.ink)
        }
    }
}

// MARK: - pitch
//
// The team screen is the one people open the app for, and it was a pale green
// rectangle with two white lines on it. A pitch is a specific, recognisable
// thing — mown stripes running away from you, a centre circle, a penalty box at
// the far end, the grass darker at the edges — and drawing it properly costs
// one Shape and a gradient.

struct PitchMarkings: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width, h = rect.height
        let inset: CGFloat = 10
        let field = CGRect(x: inset, y: inset, width: w - inset * 2, height: h - inset * 2)

        p.addRoundedRect(in: field, cornerSize: CGSize(width: 6, height: 6))

        // halfway line and centre circle, placed where a keeper's own half ends
        let midY = field.minY + field.height * 0.62
        p.move(to: CGPoint(x: field.minX, y: midY))
        p.addLine(to: CGPoint(x: field.maxX, y: midY))
        let r = min(field.width * 0.17, field.height * 0.12)
        p.addEllipse(in: CGRect(x: field.midX - r, y: midY - r, width: r * 2, height: r * 2))
        p.addEllipse(in: CGRect(x: field.midX - 2, y: midY - 2, width: 4, height: 4))

        // the box behind the goalkeeper
        let boxW = field.width * 0.52, boxH = field.height * 0.13
        p.addRect(CGRect(x: field.midX - boxW / 2, y: field.minY, width: boxW, height: boxH))
        let sixW = field.width * 0.26, sixH = boxH * 0.42
        p.addRect(CGRect(x: field.midX - sixW / 2, y: field.minY, width: sixW, height: sixH))
        // the arc at the top of the box
        var arc = Path()
        arc.addArc(center: CGPoint(x: field.midX, y: field.minY + boxH * 0.72),
                   radius: field.width * 0.13, startAngle: .degrees(20),
                   endAngle: .degrees(160), clockwise: false)
        p.addPath(arc)
        return p
    }
}

struct PitchBackground: View {
    var body: some View {
        ZStack {
            // mown stripes, running across the pitch and fading with distance
            GeometryReader { geo in
                let bands = 9
                VStack(spacing: 0) {
                    ForEach(0..<bands, id: \.self) { i in
                        (i % 2 == 0 ? Theme.pitchLight : Theme.pitchDeep)
                            .frame(height: geo.size.height / CGFloat(bands))
                    }
                }
            }
            // depth: the far end of the pitch sits in shade
            LinearGradient(colors: [Color.black.opacity(0.18), Color.black.opacity(0),
                                    Color.black.opacity(0.10)],
                           startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Color.white.opacity(0.10), Color.clear],
                           center: .init(x: 0.5, y: 0.28), startRadius: 4, endRadius: 320)
            PitchMarkings().stroke(Theme.pitchLine.opacity(0.5), lineWidth: 1.4)
        }
    }
}

struct PitchGrid: View {
    let xi: [Player]
    let captainId: Int
    let viceId: Int
    var onTap: (Player) -> Void = { _ in }

    var rows: [[Player]] {
        (1...4).map { pos in xi.filter { $0.pos == pos } }
    }

    func cardWidth(_ n: Int) -> CGFloat {
        let available = UIScreen.main.bounds.width - 28 - 16 - CGFloat(max(n - 1, 0)) * 6
        return min(80, available / CGFloat(max(n, 1)))
    }

    var body: some View {
        VStack(spacing: 14) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 6) {
                    ForEach(row) { p in
                        PlayerCard(player: p,
                                   isCaptain: p.id == captainId,
                                   isVice: p.id == viceId,
                                   width: cardWidth(row.count))
                            .onTapGesture { Haptics.tap(); onTap(p) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .padding(.horizontal, 8)
        .background(PitchBackground())
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .stroke(Color.black.opacity(0.18), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.16), radius: 16, x: 0, y: 6)
    }
}

/// One player on the grass. Small, dense, and legible against a green ground —
/// which is why it is a light card rather than a transparent label.
struct PlayerCard: View {
    let player: Player
    var isCaptain = false
    var isVice = false
    var compact = false
    var width: CGFloat = 80

    var body: some View {
        VStack(spacing: 3) {
            PlayerShot(player: player, size: 36)
            Text(player.name)
                .font(.system(size: 10.5, weight: .bold)).foregroundColor(Theme.ink)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text("\(player.teamShort) · £\(player.price)")
                .font(.mono(8.5, .medium)).foregroundColor(Theme.inkDim).figures()
            Text(String(format: "%.1f", player.proj))
                .font(.mono(11, .heavy)).foregroundColor(Theme.lime).figures()
                .frame(maxWidth: .infinity).padding(.vertical, 2.5)
                .background(Theme.lime.opacity(0.13))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .padding(.horizontal, 5).padding(.vertical, 6)
        .frame(width: compact ? 74 : width)
        .background(Theme.panel.opacity(0.96))
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(Color.white.opacity(0.35), lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.22), radius: 5, x: 0, y: 2)
        .overlay(alignment: .topLeading) {
            if player.flagged {
                Image(systemName: "cross.case.fill")
                    .font(.system(size: 8, weight: .bold)).foregroundColor(.white)
                    .frame(width: 16, height: 16)
                    .background(Theme.red).clipShape(Circle())
                    .overlay(Circle().stroke(Color.white.opacity(0.6), lineWidth: 1))
                    .offset(x: -4, y: -4)
            }
        }
        .overlay(alignment: .topTrailing) {
            if isCaptain || isVice {
                Text(isCaptain ? "C" : "V")
                    .font(.system(size: 10, weight: .black)).foregroundColor(.white)
                    .frame(width: 18, height: 18)
                    .background(isCaptain ? Theme.magenta : Theme.cyan)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Color.white.opacity(0.55), lineWidth: 1))
                    .shadow(color: Color.black.opacity(0.25), radius: 3, x: 0, y: 1)
                    .offset(x: 5, y: -5)
            }
        }
    }
}

struct BenchRow: View {
    let bench: [Player]
    var boosted = false
    var onTap: (Player) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                SectionLabel(text: "Bench")
                if boosted { Tag(text: "SCORING", color: Theme.magenta, filled: true) }
            }
            HStack(spacing: 10) {
                ForEach(bench) { p in
                    PlayerCard(player: p, compact: true).onTapGesture { onTap(p) }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(boosted ? Theme.magenta.opacity(0.06) : Theme.bg2)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(boosted ? Theme.magenta.opacity(0.4) : Theme.line,
                              style: StrokeStyle(lineWidth: 1, dash: boosted ? [] : [5]))
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - swap sheet

struct SwapSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    let out: Player
    @State private var search = ""

    var candidates: [Player] {
        var list = state.swapCandidates(for: out)
        if !search.isEmpty {
            let q = search.lowercased()
            list = list.filter {
                $0.name.lowercased().contains(q) || $0.teamShort.lowercased().contains(q)
            }
        }
        return Array(list.prefix(60))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    Tag(text: "OUT", color: Theme.red, filled: true)
                    Text("\(out.name) · \(out.teamShort) · £\(out.price)")
                        .font(.system(size: 14, weight: .heavy)).foregroundColor(Theme.ink)
                    Spacer()
                    Text(String(format: "GW%d  %.1f", state.gwFrom, out.proj))
                        .font(.mono(12, .bold)).foregroundColor(Theme.inkDim)
                }
                .padding(.horizontal, 16)

                SearchField(text: $search, placeholder: "Search replacements")
                    .padding(.horizontal, 16)

                if candidates.isEmpty {
                    EmptyNote(icon: "magnifyingglass",
                              title: search.isEmpty ? "Nothing affordable" : "No matches",
                              detail: search.isEmpty
                              ? "Free up budget by downgrading another player first."
                              : "Nothing matches “\(search)”.")
                        .padding(.horizontal, 16)
                }
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(candidates) { p in
                            Button {
                                state.applySwap(out: out, inn: p)
                                dismiss()
                            } label: { row(p) }
                        }
                    }
                    .padding(.horizontal, 16).padding(.bottom, 16)
                }
            }
            .padding(.top, 14)
            .background(Theme.bg)
            .navigationTitle("Swap player")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.tint(Theme.lime)
                }
            }
        }
    }

    func row(_ p: Player) -> some View {
        let gwV = p.projByGw[state.gwFrom] ?? 0
        let d = gwV - out.proj
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(p.name).font(.system(size: 14, weight: .heavy)).foregroundColor(Theme.ink)
                    if p.flagged {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9)).foregroundColor(Theme.amber)
                    }
                }
                Text("\(p.teamShort) · £\(p.price) · next \(state.horizon): \(String(format: "%.1f", p.proj))")
                    .font(.mono(10, .medium)).foregroundColor(Theme.inkDim)
            }
            Spacer()
            Text(String(format: "%@%.1f", d >= 0 ? "+" : "", d))
                .font(.mono(13, .bold)).foregroundColor(d >= 0 ? Theme.green : Theme.red)
            Text(String(format: "%.1f", gwV))
                .font(.mono(14, .bold)).foregroundColor(Theme.lime)
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .panel()
    }
}

struct SearchField: View {
    @Binding var text: String
    var placeholder: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundColor(Theme.inkDim)
            TextField(placeholder, text: $text)
                .font(.system(size: 14)).foregroundColor(Theme.ink)
                .autocorrectionDisabled()
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13)).foregroundColor(Theme.inkDim)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(Theme.panel)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Theme.line, lineWidth: 1))
    }
}

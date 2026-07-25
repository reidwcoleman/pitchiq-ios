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
                    ChipStrip(plan: plan).padding(.horizontal, 14)
                    SeasonSummary(plan: plan).padding(.horizontal, 14)
                } else if case .loading = state.phase {
                    ProgressView().tint(Theme.lime).frame(maxWidth: .infinity, minHeight: 260)
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

    func gwPicker(_ plan: SeasonPlan, idx: Int) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(plan.gws.enumerated()), id: \.element.gw) { i, gp in
                    Button {
                        withAnimation(.easeInOut(duration: 0.14)) { selected = i }
                    } label: {
                        gwChip(gp, active: i == idx)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 2)
        }
    }

    func gwChip(_ gp: GWPlan, active: Bool) -> some View {
        VStack(spacing: 3) {
            Text("GW \(gp.gw)").font(.mono(12, .bold))
            Text(String(format: "%.0f", gp.projPts)).font(.mono(9, .medium))
            if let chip = gp.chip {
                Text(chipShortName(chip))
                    .font(.mono(8, .heavy)).foregroundColor(.white)
                    .padding(.horizontal, 5).padding(.vertical, 1.5)
                    .background(Theme.magenta).clipShape(Capsule())
            } else if !gp.transfers.isEmpty {
                Text("\(gp.transfers.count) ⇄")
                    .font(.mono(8, .bold))
                    .foregroundColor(active ? .white.opacity(0.9) : Theme.cyan)
            } else {
                Text("hold").font(.mono(8, .medium))
                    .foregroundColor(active ? .white.opacity(0.75) : Theme.inkDim)
            }
        }
        .foregroundColor(active ? .white : Theme.ink)
        .padding(.horizontal, 13).padding(.vertical, 8)
        .background(active ? Theme.lime : Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .stroke(active ? Theme.lime : Theme.line, lineWidth: 1))
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
                    .font(.system(size: 17, weight: .heavy)).foregroundColor(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !gwPlan.transfers.isEmpty {
                VStack(spacing: 6) {
                    ForEach(gwPlan.transfers) { t in TransferRow(move: t, chip: gwPlan.chip) }
                }
            }
            if isFirst && !state.isConnected {
                Text("Connect your FPL team in Settings and this becomes advice on your own fifteen instead of a suggested squad.")
                    .font(.system(size: 11.5)).foregroundColor(Theme.inkDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(accent.opacity(0.35), lineWidth: 1.5))
        .shadow(color: Color.black.opacity(0.05), radius: 10, x: 0, y: 3)
    }
}

struct TransferRow: View {
    let move: TransferMove
    var chip: String?

    var body: some View {
        HStack(spacing: 7) {
            if move.out.flagged {
                Image(systemName: "cross.case.fill").font(.system(size: 10)).foregroundColor(Theme.red)
            }
            Text(move.out.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Theme.inkDim).strikethrough()
                .lineLimit(1)
            Image(systemName: "arrow.right").font(.system(size: 9, weight: .bold))
                .foregroundColor(Theme.lime)
            Text(move.inn.name).font(.system(size: 13, weight: .bold))
                .foregroundColor(Theme.ink).lineLimit(1)
            Text("£\(move.inn.price)").font(.mono(10, .medium)).foregroundColor(Theme.inkDim)
            Spacer(minLength: 4)
            Text(String(format: "+%.1f", move.gain))
                .font(.mono(11, .bold)).foregroundColor(Theme.green)
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
                HStack(alignment: .top, spacing: 8) {
                    Text("▸").foregroundColor(Theme.lime).font(.system(size: 11))
                    Text(n).font(.system(size: 13)).foregroundColor(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 7)
                if i < notes.count - 1 { Divider().background(Theme.line) }
            }
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
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

struct PitchGrid: View {
    let xi: [Player]
    let captainId: Int
    let viceId: Int
    var onTap: (Player) -> Void = { _ in }

    var rows: [[Player]] {
        (1...4).map { pos in xi.filter { $0.pos == pos } }
    }

    func cardWidth(_ n: Int) -> CGFloat {
        let available = UIScreen.main.bounds.width - 28 - 20 - CGFloat(max(n - 1, 0)) * 8
        return min(84, available / CGFloat(max(n, 1)))
    }

    var body: some View {
        VStack(spacing: 16) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 8) {
                    ForEach(row) { p in
                        PlayerCard(player: p,
                                   isCaptain: p.id == captainId,
                                   isVice: p.id == viceId,
                                   width: cardWidth(row.count))
                            .onTapGesture { onTap(p) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .background(pitchBackground)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color(hex: 0xBFDCB4), lineWidth: 1))
        .shadow(color: Color.black.opacity(0.05), radius: 12, x: 0, y: 4)
    }

    var pitchBackground: some View {
        ZStack {
            VStack(spacing: 0) {
                ForEach(0..<8, id: \.self) { i in
                    (i % 2 == 0 ? Theme.pitchLight : Theme.pitchDark)
                }
            }
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.75), lineWidth: 1.5)
                .padding(10)
            Circle().stroke(Color.white.opacity(0.6), lineWidth: 1.5)
                .frame(width: 110, height: 110)
        }
    }
}

struct PlayerCard: View {
    let player: Player
    var isCaptain = false
    var isVice = false
    var compact = false
    var width: CGFloat = 82

    var body: some View {
        VStack(spacing: 4) {
            ShirtShape()
                .fill(Theme.teamColor(player.teamShort))
                .overlay(ShirtShape().stroke(Color.black.opacity(0.08), lineWidth: 1))
                .frame(width: 30, height: 26)
            Text(player.name)
                .font(.system(size: 11, weight: .bold)).foregroundColor(Theme.ink)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text("\(player.teamShort) £\(player.price)")
                .font(.mono(8.5, .medium)).foregroundColor(Theme.inkDim)
            Text(String(format: "%.1f", player.proj))
                .font(.mono(11, .bold)).foregroundColor(Theme.lime)
                .frame(maxWidth: .infinity).padding(.vertical, 2)
                .background(Theme.lime.opacity(0.09))
                .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .padding(6)
        .frame(width: compact ? 76 : width)
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: Color.black.opacity(0.08), radius: 5, x: 0, y: 2)
        .overlay(alignment: .topLeading) {
            if player.flagged {
                Image(systemName: "cross.case.fill")
                    .font(.system(size: 9)).foregroundColor(.white)
                    .frame(width: 17, height: 17)
                    .background(Theme.red).clipShape(Circle())
                    .offset(x: -4, y: -4)
            }
        }
        .overlay(alignment: .topTrailing) {
            if isCaptain || isVice {
                Text(isCaptain ? "C" : "V")
                    .font(.system(size: 11, weight: .heavy)).foregroundColor(.white)
                    .frame(width: 20, height: 20)
                    .background(isCaptain ? Theme.magenta : Theme.cyan)
                    .clipShape(Circle())
                    .shadow(color: Color.black.opacity(0.15), radius: 3, x: 0, y: 1)
                    .offset(x: 6, y: -6)
            }
        }
    }
}

struct ShirtShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width, h = rect.height
        p.move(to: CGPoint(x: w * 0.25, y: 0))
        p.addLine(to: CGPoint(x: w * 0.75, y: 0))
        p.addLine(to: CGPoint(x: w, y: h * 0.22))
        p.addLine(to: CGPoint(x: w * 0.86, y: h * 0.42))
        p.addLine(to: CGPoint(x: w * 0.82, y: h * 0.3))
        p.addLine(to: CGPoint(x: w * 0.82, y: h))
        p.addLine(to: CGPoint(x: w * 0.18, y: h))
        p.addLine(to: CGPoint(x: w * 0.18, y: h * 0.3))
        p.addLine(to: CGPoint(x: w * 0.14, y: h * 0.42))
        p.addLine(to: CGPoint(x: 0, y: h * 0.22))
        p.closeSubpath()
        return p
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
        .preferredColorScheme(.light)
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

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

// The merged Team tab: pick any gameweek in the plan, see the exact squad you
// should hold that week, the transfers that get you there, and why.
struct SquadView: View {
    @EnvironmentObject var state: AppState
    @State private var sheet: SquadSheet?
    @State private var selected = 0

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                ControlsBar()
                if case .optimizing = state.phase {
                    VStack(spacing: 14) {
                        ProgressView().tint(Theme.lime)
                        Text("Scoring 500+ players & planning \(state.planWindow) gameweeks…")
                            .font(.mono(12)).foregroundColor(Theme.inkDim)
                    }
                    .frame(maxWidth: .infinity, minHeight: 300)
                } else if let plan = state.plan, !plan.gws.isEmpty {
                    let idx = min(selected, plan.gws.count - 1)
                    let gp = plan.gws[idx]
                    let isFirst = idx == 0

                    planHeader(plan)
                    gwPicker(plan, idx: idx)
                    TransfersCard(gwPlan: gp, isFirst: isFirst, fromUser: plan.fromUserSquad)
                        .padding(.horizontal, 14)

                    let sortedXI = gp.xi.sorted { $0.proj > $1.proj }
                    PitchGrid(xi: gp.xi,
                              captainId: gp.captain.id,
                              viceId: sortedXI.count > 1 ? sortedXI[1].id : -1) { p in
                        sheet = .detail(p, canSwap: isFirst)
                    }
                    .padding(.horizontal, 14)

                    BenchRow(bench: gp.bench) { p in sheet = .detail(p, canSwap: isFirst) }
                        .padding(.horizontal, 14)

                    gwTiles(gp, isFirst: isFirst)
                        .padding(.horizontal, 14)

                    WhyCard(gwPlan: gp, isFirst: isFirst, fromUser: plan.fromUserSquad)
                        .padding(.horizontal, 14)
                } else {
                    Text("No feasible squad — raise the budget or allow flagged players.")
                        .font(.system(size: 14)).foregroundColor(Theme.inkDim)
                        .padding(.top, 60)
                }
            }
            .padding(.bottom, 24)
        }
        .background(Theme.bg)
        .onChange(of: state.gwFrom) { _ in selected = 0 }
        .sheet(item: $sheet) { s in
            switch s {
            case .detail(let p, let canSwap):
                PlayerDetailSheet(player: p, canSwap: canSwap) { out in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { sheet = .swap(out) }
                }
            case .swap(let p):
                SwapSheet(out: p)
            }
        }
    }

    func planHeader(_ plan: SeasonPlan) -> some View {
        HStack(spacing: 8) {
            Text(state.isEdited ? "YOUR TEAM · \(plan.gws.count)-WEEK PLAN" : "AI TEAM · \(plan.gws.count)-WEEK PLAN")
                .font(.label(9)).tracking(1.5)
                .foregroundColor(state.isEdited ? Theme.cyan : Theme.inkDim)
            Spacer()
            Text(String(format: "Σ %.0f pts · %d transfers%@", plan.totalPts, plan.totalTransfers,
                        plan.totalHits > 0 ? " · -\(plan.totalHits) hits" : ""))
                .font(.mono(10, .medium)).foregroundColor(Theme.inkDim)
            if state.isEdited {
                Button { state.resetToAI() } label: {
                    Text("Reset")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(Theme.lime)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Theme.lime.opacity(0.12))
                        .clipShape(Capsule())
                }
            }
        }
        .padding(.horizontal, 18)
    }

    func gwPicker(_ plan: SeasonPlan, idx: Int) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(plan.gws.enumerated()), id: \.element.gw) { i, gp in
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { selected = i }
                    } label: {
                        VStack(spacing: 3) {
                            Text("GW \(gp.gw)").font(.mono(12, .bold))
                            Text(String(format: "%.0f pts", gp.projPts)).font(.mono(9, .medium))
                            if !gp.transfers.isEmpty {
                                Text("\(gp.transfers.count) ⇄")
                                    .font(.mono(8, .bold))
                                    .foregroundColor(i == idx ? .white.opacity(0.9) : Theme.cyan)
                            }
                        }
                        .foregroundColor(i == idx ? .white : Theme.ink)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(i == idx ? Theme.lime : Theme.panel)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12)
                            .stroke(i == idx ? Theme.lime : Theme.line, lineWidth: 1))
                        .shadow(color: Color.black.opacity(i == idx ? 0.1 : 0.03), radius: 5, x: 0, y: 2)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 2)
        }
    }

    func gwTiles(_ gp: GWPlan, isFirst: Bool) -> some View {
        let cost = state.squad.map { Double($0.cost) / 10 }
        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            tile(String(format: "%.1f", gp.projPts), "GW \(gp.gw) XI PTS (C×2)", Theme.lime)
            tile(gp.formation, "FORMATION", Theme.cyan)
            tile("\(gp.ftsLeft)", "FREE TRANSFERS BANKED", Theme.cyan)
            if isFirst, let cost {
                tile("£\(String(format: "%.1f", cost))m", "SQUAD COST", Theme.lime)
            } else {
                tile(gp.hitPts > 0 ? "-\(gp.hitPts)" : "\(gp.transfers.count)",
                     gp.hitPts > 0 ? "HIT COST THIS WEEK" : "TRANSFERS THIS WEEK",
                     gp.hitPts > 0 ? Theme.red : Theme.lime)
            }
        }
    }

    func tile(_ v: String, _ k: String, _ c: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(v).font(.mono(24, .bold)).foregroundColor(c)
            Text(k).font(.label(9)).tracking(1.2).foregroundColor(Theme.inkDim)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .panel()
    }
}

// MARK: - transfers card

struct TransfersCard: View {
    @EnvironmentObject var state: AppState
    let gwPlan: GWPlan
    let isFirst: Bool
    let fromUser: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("TRANSFERS · GW \(gwPlan.gw)").font(.label(9)).tracking(1.5).foregroundColor(Theme.inkDim)
            if isFirst && !fromUser {
                Label("Starting squad — no transfers needed. Tap any player to make it yours.",
                      systemImage: "flag.checkered")
                    .font(.system(size: 12.5, weight: .medium)).foregroundColor(Theme.ink)
            } else if gwPlan.transfers.isEmpty {
                Label("None this week — bank the free transfer (\(gwPlan.ftsLeft) saved up).",
                      systemImage: "tray.and.arrow.down")
                    .font(.system(size: 12.5, weight: .medium)).foregroundColor(Theme.ink)
            } else {
                ForEach(gwPlan.transfers) { t in
                    HStack(spacing: 7) {
                        Text(t.out.name)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(Theme.inkDim).strikethrough()
                        Image(systemName: "arrow.right")
                            .font(.system(size: 10, weight: .bold)).foregroundColor(Theme.lime)
                        Text(t.inn.name).font(.system(size: 13, weight: .bold)).foregroundColor(Theme.ink)
                        Text("\(t.inn.teamShort) £\(t.inn.price)")
                            .font(.mono(10, .medium)).foregroundColor(Theme.inkDim)
                        Spacer()
                        Text(String(format: "+%.1f", t.gain))
                            .font(.mono(11, .bold)).foregroundColor(Theme.green)
                        Text(t.paid ? "-4" : "FREE")
                            .font(.mono(9, .bold))
                            .foregroundColor(t.paid ? .white : Theme.lime)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(t.paid ? Theme.red : Theme.lime.opacity(0.14))
                            .clipShape(Capsule())
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }
}

// MARK: - why this team

struct WhyCard: View {
    @EnvironmentObject var state: AppState
    let gwPlan: GWPlan
    let isFirst: Bool
    let fromUser: Bool

    func fixtureDesc(_ p: Player, gw: Int) -> String {
        let fxs = state.gridFixtures(teamId: p.team, gws: [gw]).first ?? []
        if fxs.isEmpty { return "blank gameweek" }
        if fxs.count > 1 { return "double gameweek (" + fxs.map { state.teamShort($0.opp) }.joined(separator: " & ") + ")" }
        let fx = fxs[0]
        return "\(fx.home ? "home vs" : "away at") \(state.teamName(fx.opp)) (FDR \(fx.diff))"
    }

    var notes: [String] {
        var out: [String] = []
        let cap = gwPlan.captain
        out.append("Captain \(cap.name) — highest projected scorer this week (\(String(format: "%.1f", cap.proj)) pts, doubled): \(fixtureDesc(cap, gw: gwPlan.gw)), xGI/90 \(String(format: "%.2f", cap.xgi90)), PPG \(String(format: "%.1f", cap.ppg)) last season.")

        let favourable = gwPlan.xi.filter { p in
            let fxs = state.gridFixtures(teamId: p.team, gws: [gwPlan.gw]).first ?? []
            return !fxs.isEmpty && fxs.allSatisfy { $0.diff <= 3 }
        }.count
        out.append("\(favourable) of 11 starters have favourable fixtures (FDR ≤ 3) in GW \(gwPlan.gw) — every projection is weighted by exactly who each team plays, home or away.")

        if let topDef = gwPlan.xi.filter({ $0.pos <= 2 }).max(by: { $0.proj < $1.proj }) {
            out.append("Best defensive pick: \(topDef.name) (\(String(format: "%.1f", topDef.proj)) pts) — \(fixtureDesc(topDef, gw: gwPlan.gw)); clean-sheet odds come from how few goals that opponent is expected to score.")
        }

        for t in gwPlan.transfers {
            out.append("\(t.out.name) → \(t.inn.name): +\(String(format: "%.1f", t.gain)) projected pts over the remaining weeks (\(t.paid ? "worth the -4 hit" : "free transfer")). \(t.inn.name)'s run: \(fixtureDesc(t.inn, gw: gwPlan.gw)).")
        }
        if gwPlan.transfers.isEmpty && !isFirst {
            out.append("No move gains enough to beat holding — the free transfer banks instead (\(gwPlan.ftsLeft) saved, max 5, max 2 moves a week).")
        }
        if isFirst {
            out.append(fromUser
                ? "This is your team — the plan works from it and only suggests changes that clearly add points."
                : "This 15 was chosen to score now AND stay strong for all \(state.planWindow) weeks, so you barely need transfers.")
        }

        out.append(state.isPreseason
            ? "Model inputs: last season's xG/xA per-90, minutes security, points-per-game and bonus rates, adjusted for each opponent's difficulty. Player form joins the blend automatically once matches are played."
            : "Model inputs: current form blended with xG/xA per-90 rates, minutes security, bonus rates and each opponent's difficulty (home/away adjusted).")
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("WHY THIS TEAM").font(.label(10)).tracking(2).foregroundColor(Theme.inkDim)
                .padding(.bottom, 8)
            ForEach(Array(notes.enumerated()), id: \.offset) { i, n in
                HStack(alignment: .top, spacing: 8) {
                    Text("▸").foregroundColor(Theme.lime).font(.system(size: 12))
                    Text(n).font(.system(size: 13)).foregroundColor(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 7)
                if i < notes.count - 1 { Divider().background(Theme.line) }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
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

    // size cards to the row so 4- and 5-player lines never clip the screen
    func cardWidth(_ n: Int) -> CGFloat {
        let available = UIScreen.main.bounds.width - 28 - 20 - CGFloat(max(n - 1, 0)) * 8
        return min(84, available / CGFloat(max(n, 1)))
    }

    var body: some View {
        VStack(spacing: 18) {
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
        .padding(.vertical, 22)
        .background(
            ZStack {
                VStack(spacing: 0) {
                    ForEach(0..<8, id: \.self) { i in
                        (i % 2 == 0 ? Theme.pitchLight : Theme.pitchDark)
                    }
                }
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.white.opacity(0.75), lineWidth: 1.5)
                    .padding(10)
                Circle()
                    .stroke(Color.white.opacity(0.65), lineWidth: 1.5)
                    .frame(width: 110, height: 110)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color(hex: 0xBFDCB4), lineWidth: 1))
        .shadow(color: Color.black.opacity(0.05), radius: 12, x: 0, y: 4)
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
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(Theme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text("\(player.teamShort) £\(player.price)")
                .font(.mono(8.5, .medium))
                .foregroundColor(Theme.inkDim)
            Text(String(format: "%.1f", player.proj))
                .font(.mono(11, .bold))
                .foregroundColor(Theme.lime)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 2)
                .background(Theme.lime.opacity(0.09))
                .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .padding(6)
        .frame(width: compact ? 76 : width)
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: Color.black.opacity(0.08), radius: 5, x: 0, y: 2)
        .overlay(alignment: .topTrailing) {
            if isCaptain || isVice {
                Text(isCaptain ? "C" : "V")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundColor(.white)
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
    var onTap: (Player) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 8) {
            Text("BENCH").font(.label(9)).tracking(3).foregroundColor(Theme.inkDim)
            HStack(spacing: 10) {
                ForEach(bench) { p in
                    PlayerCard(player: p, compact: true)
                        .onTapGesture { onTap(p) }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Theme.bg2)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Theme.line, style: StrokeStyle(lineWidth: 1, dash: [5]))
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
            list = list.filter { $0.name.lowercased().contains(q) || $0.teamShort.lowercased().contains(q) }
        }
        return Array(list.prefix(60))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    Text("OUT").font(.mono(9, .bold)).foregroundColor(Theme.red)
                    Text("\(out.name) · \(out.teamShort) · £\(out.price)")
                        .font(.system(size: 14, weight: .heavy)).foregroundColor(Theme.ink)
                    Spacer()
                    Text(String(format: "GW%d: %.1f pts", state.gwFrom, out.proj))
                        .font(.mono(12, .bold)).foregroundColor(Theme.inkDim)
                }
                .padding(.horizontal, 16)

                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundColor(Theme.inkDim)
                    TextField("Search replacements", text: $search)
                        .font(.system(size: 14)).foregroundColor(Theme.ink)
                        .autocorrectionDisabled()
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(Theme.panel)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Theme.line, lineWidth: 1))
                .padding(.horizontal, 16)

                if candidates.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").font(.system(size: 24)).foregroundColor(Theme.inkDim)
                        Text(search.isEmpty
                             ? "No affordable replacements — free up budget by downgrading another player first."
                             : "No matches for “\(search)”.")
                            .font(.system(size: 13)).foregroundColor(Theme.inkDim)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 30)
                    }
                    .frame(maxWidth: .infinity, minHeight: 180)
                }
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(candidates) { p in
                            Button {
                                state.applySwap(out: out, inn: p)
                                dismiss()
                            } label: {
                                HStack(spacing: 10) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Text(p.name).font(.system(size: 14, weight: .heavy)).foregroundColor(Theme.ink)
                                            if p.flagged {
                                                Image(systemName: "exclamationmark.triangle.fill")
                                                    .font(.system(size: 9)).foregroundColor(Theme.amber)
                                            }
                                        }
                                        Text("\(p.teamShort) · £\(p.price) · PPG \(String(format: "%.1f", p.ppg)) · next \(state.horizon): \(String(format: "%.1f", p.proj))")
                                            .font(.mono(10, .medium)).foregroundColor(Theme.inkDim)
                                    }
                                    Spacer()
                                    let gwV = p.projByGw[state.gwFrom] ?? 0
                                    let d = gwV - out.proj
                                    Text(String(format: "%@%.1f", d >= 0 ? "+" : "", d))
                                        .font(.mono(13, .bold))
                                        .foregroundColor(d >= 0 ? Theme.green : Theme.red)
                                    Text(String(format: "%.1f", gwV))
                                        .font(.mono(14, .bold)).foregroundColor(Theme.lime)
                                        .frame(width: 44, alignment: .trailing)
                                }
                                .padding(.horizontal, 14).padding(.vertical, 10)
                                .panel()
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
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
}

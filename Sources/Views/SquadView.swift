import SwiftUI

enum SquadSheet: Identifiable {
    case detail(Player)
    case swap(Player)
    var id: Int {
        switch self {
        case .detail(let p): return p.id
        case .swap(let p): return -p.id
        }
    }
}

struct SquadView: View {
    @EnvironmentObject var state: AppState
    @State private var sheet: SquadSheet?

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                ControlsBar()
                if case .optimizing = state.phase {
                    VStack(spacing: 14) {
                        ProgressView().tint(Theme.lime)
                        Text("Scoring 500+ players & optimizing…")
                            .font(.mono(12)).foregroundColor(Theme.inkDim)
                    }
                    .frame(maxWidth: .infinity, minHeight: 300)
                } else if let r = state.squad {
                    HStack(spacing: 8) {
                        Text(state.isEdited ? "YOUR TEAM · GW \(state.gwFrom) POINTS" : "AI PICK · GW \(state.gwFrom) POINTS · TAP A PLAYER")
                            .font(.label(9)).tracking(1.5)
                            .foregroundColor(state.isEdited ? Theme.cyan : Theme.inkDim)
                        Spacer()
                        if state.isEdited {
                            Button {
                                state.resetToAI()
                            } label: {
                                Text("Reset to AI")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(Theme.lime)
                                    .padding(.horizontal, 10).padding(.vertical, 5)
                                    .background(Theme.lime.opacity(0.12))
                                    .clipShape(Capsule())
                            }
                        }
                    }
                    .padding(.horizontal, 18)
                    PitchGrid(result: r) { sheet = .detail($0) }
                        .padding(.horizontal, 14)
                    BenchRow(bench: r.bench) { sheet = .detail($0) }
                        .padding(.horizontal, 14)
                    StatTiles(result: r, budget: state.budget, gw: state.gwFrom)
                        .padding(.horizontal, 14)
                    ModelNotes(result: r)
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
        .sheet(item: $sheet) { s in
            switch s {
            case .detail(let p):
                PlayerDetailSheet(player: p, canSwap: true) { out in
                    // detail sheet dismisses itself first; re-present as swap
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { sheet = .swap(out) }
                }
            case .swap(let p):
                SwapSheet(out: p)
            }
        }
    }
}

struct PitchGrid: View {
    let result: SquadResult
    var onTap: (Player) -> Void = { _ in }

    var rows: [[Player]] {
        (1...4).map { pos in result.xi.filter { $0.pos == pos } }
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
                                   isCaptain: p.id == result.captain.id,
                                   isVice: p.id == result.vice.id,
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

struct StatTiles: View {
    let result: SquadResult
    let budget: Double
    var gw = 0

    var body: some View {
        let xiPts = result.total + result.captain.proj
        let bank = budget * 10 - Double(result.cost)
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            tile(String(format: "%.1f", xiPts), "GW \(gw) XI PTS (C×2)", Theme.lime)
            tile(result.formation, "FORMATION", Theme.cyan)
            tile("£\(String(format: "%.1f", Double(result.cost) / 10))m", "SQUAD COST", Theme.lime)
            tile("£\(String(format: "%.1f", bank / 10))m", "IN THE BANK", Theme.cyan)
        }
    }

    func tile(_ v: String, _ k: String, _ c: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(v).font(.mono(24, .bold)).foregroundColor(c)
            Text(k).font(.label(9)).tracking(1.5).foregroundColor(Theme.inkDim)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .panel()
    }
}

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

struct ModelNotes: View {
    @EnvironmentObject var state: AppState
    let result: SquadResult

    var notes: [String] {
        let gwEnd = min(state.gwFrom + state.horizon - 1, 38)
        let range = state.horizon > 1 ? "GW \(state.gwFrom)–\(gwEnd)" : "GW \(state.gwFrom)"
        let excluded = state.players.filter(\.flagged).count
        return [
            "Points shown are for GW \(state.gwFrom) only — change the gameweek at the top to see any other week. Squad selection still looks across \(range).",
            "Tap any player for full stats, every upcoming fixture, and the swap option.",
            "Captain: \(result.captain.name) — highest projection in the XI. Vice: \(result.vice.name).",
            state.isPreseason
                ? "Pre-season mode: model leans on 2025/26 xG/xA, minutes and PPG; new signings & promoted clubs lean on FPL's expected-points feed."
                : "In-season mode: recent form is blended into every projection.",
            state.fitOnly
                ? "\(excluded) flagged players (injured/doubtful/suspended) excluded — tap 'Fit only' to include them."
                : "Flagged players included, weighted by % chance of playing.",
            "Constraints: £\(Int(state.budget))m budget, 2 GK / 5 DEF / 5 MID / 3 FWD, max 3 per club.",
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("MODEL NOTES").font(.label(10)).tracking(2).foregroundColor(Theme.inkDim)
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

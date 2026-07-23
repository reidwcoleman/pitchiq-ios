import SwiftUI

struct SquadView: View {
    @EnvironmentObject var state: AppState

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
                    PitchGrid(result: r)
                        .padding(.horizontal, 14)
                    BenchRow(bench: r.bench)
                        .padding(.horizontal, 14)
                    StatTiles(result: r, budget: state.budget)
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
    }
}

struct PitchGrid: View {
    let result: SquadResult

    var rows: [[Player]] {
        (1...4).map { pos in result.xi.filter { $0.pos == pos } }
    }

    var body: some View {
        VStack(spacing: 18) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 10) {
                    ForEach(row) { p in
                        PlayerCard(player: p,
                                   isCaptain: p.id == result.captain.id,
                                   isVice: p.id == result.vice.id)
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
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Theme.ink.opacity(0.12), lineWidth: 1.5)
                    .padding(10)
                Circle()
                    .stroke(Theme.ink.opacity(0.10), lineWidth: 1.5)
                    .frame(width: 110, height: 110)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color(hex: 0x27402a), lineWidth: 1))
    }
}

struct PlayerCard: View {
    let player: Player
    var isCaptain = false
    var isVice = false
    var compact = false

    var body: some View {
        VStack(spacing: 4) {
            ShirtShape()
                .fill(Theme.teamColor(player.teamShort))
                .overlay(ShirtShape().stroke(Color.white.opacity(0.2), lineWidth: 1))
                .frame(width: 30, height: 26)
            Text(player.name)
                .font(.system(size: 11, weight: .heavy))
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
        .frame(width: compact ? 76 : 82)
        .background(Theme.bg.opacity(0.88))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Theme.line, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 11))
        .overlay(alignment: .topTrailing) {
            if isCaptain || isVice {
                Text(isCaptain ? "C" : "V")
                    .font(.system(size: 11, weight: .black))
                    .foregroundColor(.black)
                    .frame(width: 20, height: 20)
                    .background(isCaptain ? Theme.magenta : Theme.cyan)
                    .clipShape(Circle())
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

    var body: some View {
        VStack(spacing: 8) {
            Text("BENCH").font(.label(9)).tracking(3).foregroundColor(Theme.inkDim)
            HStack(spacing: 10) {
                ForEach(bench) { p in PlayerCard(player: p, compact: true) }
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

    var body: some View {
        let xiPts = result.total + result.captain.proj
        let bank = budget * 10 - Double(result.cost)
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            tile(String(format: "%.1f", xiPts), "PROJ. XI PTS (C×2)", Theme.lime)
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

struct ModelNotes: View {
    @EnvironmentObject var state: AppState
    let result: SquadResult

    var notes: [String] {
        let gwEnd = min(state.gwFrom + state.horizon - 1, 38)
        let range = state.horizon > 1 ? "GW \(state.gwFrom)–\(gwEnd)" : "GW \(state.gwFrom)"
        let excluded = state.players.filter(\.flagged).count
        return [
            "Projections cover \(range), summed per real fixture (doubles boost, blanks zero).",
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

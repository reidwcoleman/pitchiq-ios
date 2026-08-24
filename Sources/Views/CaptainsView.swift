import SwiftUI

/// Captaincy is the single highest-variance decision in the game, so this tab
/// shows the shape of each candidate's week, not just its average: the ceiling
/// you're chasing, the chance of a haul, and the chance of a blank. Ranking on
/// the mean alone hides the difference between a defender who returns six every
/// week and a striker who returns two or fifteen.
struct CaptainsView: View {
    @EnvironmentObject var state: AppState
    @State private var detail: Player?
    @State private var fromSquad = true

    var picks: [Advisor.CaptainPick] {
        let squad = fromSquad ? state.squad?.squad : nil
        return Advisor.captainBoard(squad: squad, players: state.players, gw: state.gwFrom, limit: 12)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                AppHeader(subtitle: "Captain · GW \(state.gwFrom)")
                Picker("", selection: $fromSquad) {
                    Text(state.isConnected ? "Your squad" : "Your XV").tag(true)
                    Text("Whole league").tag(false)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)

                let list = picks
                if let top = list.first { headline(top) }
                VStack(spacing: 8) {
                    ForEach(Array(list.enumerated()), id: \.element.id) { i, c in
                        CaptainRow(rank: i + 1, pick: c, maxCeiling: list.map(\.ceiling).max() ?? 1)
                            .onTapGesture { detail = c.player }
                    }
                }
                .padding(.horizontal, 14)

                ReasonCard(title: "How to read this", notes: [
                    "Expected is the average score across every way the gameweek could go — the number the optimiser maximises.",
                    "Ceiling is the 90th percentile: reach it one week in ten. It's what you're really buying when you captain a forward.",
                    "Haul is the chance of ten or more. Blank is the chance of two or fewer, which includes not being picked at all.",
                    "Effective ownership estimates how much of the field has the same captain. Against a high-EO pick you gain nothing when it hauls and lose heavily when it doesn't — which is the whole argument for a differential captain when you're chasing.",
                ])
                .padding(.horizontal, 14)
            }
            .padding(.bottom, 26)
        }
        .background(Theme.bg)
        .sheet(item: $detail) { p in PlayerDetailSheet(player: p) }
    }

    func headline(_ c: Advisor.CaptainPick) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(text: "The pick", accent: Theme.magenta)
            HStack(spacing: 12) {
                PlayerShot(player: c.player, size: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text(c.player.name).font(.system(size: 21, weight: .black)).foregroundColor(Theme.ink)
                    Text("\(c.player.teamName) · \(c.player.posShort) · £\(c.player.price)")
                        .font(.system(size: 11.5)).foregroundColor(Theme.inkDim)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(String(format: "%.1f", c.expected * 2))
                        .font(.mono(26, .bold)).foregroundColor(Theme.magenta)
                    Text("AS CAPTAIN").font(.label(8)).tracking(1).foregroundColor(Theme.inkDim)
                }
            }
            HStack(spacing: 10) {
                StatTile(value: String(format: "%.0f", c.ceiling), caption: "Ceiling", color: Theme.lime)
                StatTile(value: "\(Int(c.haulProb * 100))%", caption: "Haul 10+", color: Theme.cyan)
                StatTile(value: "\(Int(c.blankProb * 100))%", caption: "Blank ≤2", color: Theme.amber)
            }
            Text(verdict(c)).font(.system(size: 13)).foregroundColor(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.magenta.opacity(0.3), lineWidth: 1.5))
        .padding(.horizontal, 14)
    }

    func verdict(_ c: Advisor.CaptainPick) -> String {
        let fx = state.gridFixtures(teamId: c.player.team, gws: [state.gwFrom]).first ?? []
        var where_ = "no fixture this week"
        if fx.count > 1 {
            where_ = "two fixtures this week — " + fx.map { state.teamShort($0.opp) }.joined(separator: " and ")
        } else if let f = fx.first {
            where_ = "\(f.home ? "home to" : "away at") \(state.teamName(f.opp)), difficulty \(f.diff)"
        }
        let risk = c.blankProb > 0.35
            ? "It's the volatile choice: a real chance of nothing, and the ceiling to justify it."
            : "It's the dependable choice — the floor is high even when the goals don't come."
        let eo = c.effectiveOwnership > 40
            ? String(format: " Roughly %.0f%% of the field will have the same armband, so this is the safe rather than the bold play.", c.effectiveOwnership)
            : String(format: " Only about %.0f%% effective ownership, so it gains ground when it comes off.", c.effectiveOwnership)
        return "\(c.player.name) is \(where_). \(risk)\(eo)"
    }
}

struct CaptainRow: View {
    @EnvironmentObject var state: AppState
    let rank: Int
    let pick: Advisor.CaptainPick
    let maxCeiling: Double

    var body: some View {
        HStack(spacing: 12) {
            Text(String(format: "%02d", rank))
                .font(.mono(15, .bold))
                .foregroundColor(rank == 1 ? Theme.magenta : Theme.inkDim)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text(pick.player.name).font(.system(size: 14, weight: .heavy)).foregroundColor(Theme.ink)
                    Text(pick.player.teamShort).font(.mono(10, .medium)).foregroundColor(Theme.inkDim)
                    Tag(text: pick.risk, color: pick.blankProb > 0.35 ? Theme.amber : Theme.cyan)
                }
                Meter(fraction: pick.ceiling / max(maxCeiling, 1), color: Theme.limeDim)
                HStack(spacing: 10) {
                    label("\(Int(pick.haulProb * 100))%", "haul")
                    label("\(Int(pick.blankProb * 100))%", "blank")
                    label(String(format: "%.0f", pick.ceiling), "ceiling")
                    label(String(format: "%.0f%%", pick.effectiveOwnership), "EO")
                }
            }
            VStack(alignment: .trailing, spacing: 1) {
                Text(String(format: "%.1f", pick.expected * 2))
                    .font(.mono(18, .bold)).foregroundColor(Theme.lime)
                Text("×2").font(.label(8)).foregroundColor(Theme.inkDim)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(Theme.panel)
        .overlay(RoundedRectangle(cornerRadius: 14)
            .stroke(rank == 1 ? Theme.magenta.opacity(0.45) : Theme.line, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    func label(_ v: String, _ k: String) -> some View {
        HStack(spacing: 3) {
            Text(v).font(.mono(10, .bold)).foregroundColor(Theme.ink)
            Text(k).font(.label(7.5)).foregroundColor(Theme.inkDim)
        }
    }
}

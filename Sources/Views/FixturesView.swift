import SwiftUI

/// Fixture difficulty, but from the model rather than from FPL's 1-5 badge.
/// Each club carries an attack rating and a defence rating in expected goals per
/// match, so the ticker can say *why* a run is good: a green row for a striker
/// is not the same green row a defender wants.
struct FixturesView: View {
    @EnvironmentObject var state: AppState
    var embedded = false
    @State private var lens = 0        // 0 = overall, 1 = for attackers, 2 = for defenders
    @State private var span = 6

    var gws: [Int] { Array(state.gwFrom..<min(state.gwFrom + span, 39)) }

    struct TeamRun: Identifiable {
        let id: Int
        let team: FPLTeam
        let cells: [[FixtureInfo]]
        let score: Double            // lower is better
        let attack: Double
        let defence: Double
    }

    var runs: [TeamRun] {
        guard let boot = state.boot else { return [] }
        let list = boot.teams.map { t -> TeamRun in
            let cells = state.gridFixtures(teamId: t.id, gws: gws)
            let all = cells.flatMap { $0 }
            let form = state.teamForm(t.id)
            // Attackers care about how leaky the opponents are; defenders care
            // about how toothless they are. Overall averages the two.
            var total = 0.0
            for fx in all {
                let opp = state.teamForm(fx.opp)
                let leaky = opp?.defence ?? TeamRatings.leagueGoals
                let sharp = opp?.attack ?? TeamRatings.leagueGoals
                let home = fx.home ? -0.08 : 0.08
                switch lens {
                case 1: total += (2 * TeamRatings.leagueGoals - leaky) + home
                case 2: total += sharp + home
                default: total += ((2 * TeamRatings.leagueGoals - leaky) + sharp) / 2 + home
                }
            }
            // a blank gameweek is the worst possible fixture
            let blanks = gws.count - cells.filter { !$0.isEmpty }.count
            let score = all.isEmpty ? 99
                : total / Double(all.count) + Double(blanks) * 0.25
            return TeamRun(id: t.id, team: t, cells: cells, score: score,
                           attack: form?.attack ?? 0, defence: form?.defence ?? 0)
        }
        return list.sorted { $0.score != $1.score ? $0.score < $1.score : $0.id < $1.id }
    }

    var lensNote: String {
        switch lens {
        case 1: return "Ranked by how much the opponents concede. Green rows are where to buy attackers."
        case 2: return "Ranked by how little the opponents score. Green rows are where to buy defenders and keepers."
        default: return "Ranked on both sides of the ball, with home advantage folded in."
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if !embedded {
                AppHeader(subtitle: "Fixtures · GW \(state.gwFrom)–\(gws.last ?? state.gwFrom)")
            }
            Picker("", selection: $lens) {
                Text("Overall").tag(0)
                Text("For attack").tag(1)
                Text("For defence").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)

            HStack {
                Text(lensNote).font(.system(size: 11.5)).foregroundColor(Theme.inkDim)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Menu {
                    ForEach([4, 6, 8, 10], id: \.self) { n in
                        Button("\(n) GWs") { span = n }
                    }
                } label: {
                    Text("\(span) GW").font(.mono(11, .bold)).foregroundColor(Theme.lime)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Theme.lime.opacity(0.1)).clipShape(Capsule())
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 9)

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(runs) { run in row(run) }
                }
                .padding(.horizontal, 14).padding(.bottom, 22)
            }
        }
        .background(Theme.bg)
    }

    func row(_ run: TeamRun) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Theme.teamColor(run.team.short_name))
                    .frame(width: 4, height: 16)
                Text(run.team.name).font(.system(size: 14, weight: .heavy)).foregroundColor(Theme.ink)
                Spacer()
                Text(String(format: "%.2f xG", run.attack))
                    .font(.mono(9.5, .medium)).foregroundColor(Theme.lime)
                Text(String(format: "%.2f xGA", run.defence))
                    .font(.mono(9.5, .medium)).foregroundColor(Theme.cyan)
            }
            HStack(spacing: 5) {
                ForEach(Array(zip(gws, run.cells)), id: \.0) { gw, fxs in
                    VStack(spacing: 3) {
                        Text("\(gw)").font(.mono(7.5, .medium)).foregroundColor(Theme.inkDim)
                        if fxs.isEmpty {
                            Text("—").font(.mono(9, .bold)).foregroundColor(Theme.inkDim)
                                .frame(maxWidth: .infinity).padding(.vertical, 4)
                                .background(Theme.bg2)
                                .clipShape(RoundedRectangle(cornerRadius: 5))
                        } else {
                            ForEach(Array(fxs.enumerated()), id: \.offset) { _, fx in
                                Text("\(state.teamShort(fx.opp))\(fx.home ? "" : "ᵃ")")
                                    .font(.mono(9, .bold))
                                    .foregroundColor(Theme.diffColor(fx.diff))
                                    .frame(maxWidth: .infinity).padding(.vertical, 4)
                                    .background(Theme.diffColor(fx.diff).opacity(0.14))
                                    .clipShape(RoundedRectangle(cornerRadius: 5))
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(12)
        .panel()
    }
}

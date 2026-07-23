import SwiftUI

struct FixturesView: View {
    @EnvironmentObject var state: AppState

    var gws: [Int] {
        let span = max(state.horizon, 6)
        return Array(state.gwFrom..<min(state.gwFrom + span, 39))
    }

    struct TeamRun: Identifiable {
        let id: Int
        let team: FPLTeam
        let cells: [[FixtureInfo]]
        let avg: Double
    }

    var runs: [TeamRun] {
        guard let boot = state.boot else { return [] }
        return boot.teams.map { t in
            let cells = state.gridFixtures(teamId: t.id, gws: gws)
            let all = cells.flatMap { $0 }
            let avg = all.isEmpty ? 5.0 : Double(all.reduce(0) { $0 + $1.diff }) / Double(all.count)
            return TeamRun(id: t.id, team: t, cells: cells, avg: avg)
        }
        .sorted { $0.avg < $1.avg }
    }

    var body: some View {
        VStack(spacing: 0) {
            ControlsBar()
            Text("Fixture difficulty, easiest runs first. Target attackers from green rows; defenders from teams facing green.")
                .font(.system(size: 12)).foregroundColor(Theme.inkDim)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.bottom, 10)
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(runs) { run in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(run.team.name)
                                    .font(.system(size: 14, weight: .heavy)).foregroundColor(Theme.ink)
                                Spacer()
                                Text(String(format: "avg %.2f", run.avg))
                                    .font(.mono(10, .medium)).foregroundColor(Theme.inkDim)
                            }
                            HStack(spacing: 5) {
                                ForEach(Array(zip(gws, run.cells)), id: \.0) { gw, fxs in
                                    VStack(spacing: 3) {
                                        Text("GW\(gw)").font(.mono(7, .medium)).foregroundColor(Theme.inkDim)
                                        if fxs.isEmpty {
                                            Text("—").font(.mono(9, .bold)).foregroundColor(Theme.inkDim)
                                                .frame(maxWidth: .infinity).padding(.vertical, 4)
                                                .background(Color.white.opacity(0.04))
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
                        .padding(.horizontal, 14)
                    }
                }
                .padding(.bottom, 20)
            }
        }
        .background(Theme.bg)
    }
}

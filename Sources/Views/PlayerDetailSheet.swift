import SwiftUI

struct PlayerDetailSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    let player: Player
    var canSwap = false
    var onSwap: (Player) -> Void = { _ in }

    /// Full-data version from the model (the tapped card may carry a single-GW projection).
    var full: Player { state.players.first { $0.id == player.id } ?? player }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    if !full.news.isEmpty { newsBox }
                    projSection
                    statSection
                    fixtureSection
                    if canSwap {
                        Button {
                            dismiss()
                            onSwap(player)
                        } label: {
                            Label("Swap this player", systemImage: "arrow.left.arrow.right")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundColor(.black)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Theme.lime)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
                .padding(16)
            }
            .background(Theme.bg)
            .navigationTitle(full.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }.tint(Theme.lime)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    var header: some View {
        HStack(spacing: 14) {
            ShirtShape()
                .fill(Theme.teamColor(full.teamShort))
                .overlay(ShirtShape().stroke(Color.white.opacity(0.2), lineWidth: 1))
                .frame(width: 52, height: 46)
            VStack(alignment: .leading, spacing: 4) {
                Text(full.name).font(.system(size: 22, weight: .black)).foregroundColor(Theme.ink)
                Text("\(full.teamName) · \(full.posShort) · £\(full.price) · \(String(format: "%.1f", full.own))% owned")
                    .font(.mono(11, .medium)).foregroundColor(Theme.inkDim)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(String(format: "%.1f", full.proj))
                    .font(.mono(24, .bold)).foregroundColor(Theme.lime)
                Text("PROJ · NEXT \(state.horizon)").font(.label(7)).tracking(1).foregroundColor(Theme.inkDim)
            }
        }
        .padding(14)
        .panel()
    }

    var newsBox: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12)).foregroundColor(Theme.amber)
            Text(full.news).font(.system(size: 12.5)).foregroundColor(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.amber.opacity(0.08))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.amber.opacity(0.35), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    var projSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PROJECTED POINTS BY GAMEWEEK").font(.label(9)).tracking(1.5).foregroundColor(Theme.inkDim)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(full.projByGw.keys.sorted(), id: \.self) { gw in
                        VStack(spacing: 3) {
                            Text("GW\(gw)").font(.mono(8, .medium)).foregroundColor(Theme.inkDim)
                            Text(String(format: "%.1f", full.projByGw[gw] ?? 0))
                                .font(.mono(13, .bold))
                                .foregroundColor(gw == state.gwFrom ? Theme.lime : Theme.ink)
                        }
                        .padding(.horizontal, 11).padding(.vertical, 7)
                        .background(gw == state.gwFrom ? Theme.lime.opacity(0.1) : Theme.panel)
                        .overlay(RoundedRectangle(cornerRadius: 9)
                            .stroke(gw == state.gwFrom ? Theme.limeDim : Theme.line, lineWidth: 1))
                        .clipShape(RoundedRectangle(cornerRadius: 9))
                    }
                }
            }
        }
    }

    var statSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("2025/26 SEASON").font(.label(9)).tracking(1.5).foregroundColor(Theme.inkDim)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 8) {
                stat("\(full.totalPoints)", "TOTAL PTS")
                stat(String(format: "%.1f", full.ppg), "PPG")
                stat(String(format: "%.1f", full.form), "FORM")
                stat("\(full.mins)", "MINUTES")
                stat("\(full.starts)", "STARTS")
                stat("\(full.bonus)", "BONUS")
                stat("\(full.goals)", "GOALS")
                stat("\(full.assists)", "ASSISTS")
                stat(String(format: "%.2f", full.xgi90), "xGI / 90")
                stat(String(format: "%.1f", full.xg), "xG")
                stat(String(format: "%.1f", full.xa), "xA")
                full.pos == 1 ? stat("\(full.saves)", "SAVES") : stat("\(full.cleanSheets)", "CLEAN SHEETS")
            }
        }
    }

    func stat(_ v: String, _ k: String) -> some View {
        VStack(spacing: 3) {
            Text(v).font(.mono(15, .bold)).foregroundColor(Theme.ink)
            Text(k).font(.label(7.5)).tracking(1).foregroundColor(Theme.inkDim)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .panel()
    }

    var fixtureSection: some View {
        let fixtures = state.upcomingFixtures(teamId: full.team)
        return VStack(alignment: .leading, spacing: 8) {
            Text("UPCOMING FIXTURES").font(.label(9)).tracking(1.5).foregroundColor(Theme.inkDim)
            VStack(spacing: 5) {
                ForEach(Array(fixtures.enumerated()), id: \.offset) { _, item in
                    HStack {
                        Text("GW\(item.gw)").font(.mono(11, .medium)).foregroundColor(Theme.inkDim)
                            .frame(width: 46, alignment: .leading)
                        Text("\(item.fx.home ? "vs" : "@") \(state.teamName(item.fx.opp))")
                            .font(.system(size: 13, weight: .semibold)).foregroundColor(Theme.ink)
                        Spacer()
                        Text(item.fx.home ? "HOME" : "AWAY")
                            .font(.mono(8, .medium)).foregroundColor(Theme.inkDim)
                        Text("FDR \(item.fx.diff)")
                            .font(.mono(10, .bold))
                            .foregroundColor(Theme.diffColor(item.fx.diff))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Theme.diffColor(item.fx.diff).opacity(0.14))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .panel()
                }
            }
        }
    }
}

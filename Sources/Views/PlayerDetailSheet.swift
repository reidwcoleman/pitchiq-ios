import SwiftUI

struct PlayerDetailSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    let player: Player
    var canSwap = false
    var onSwap: (Player) -> Void = { _ in }

    /// The full-data version from the model — a tapped pitch card carries a
    /// single-gameweek projection rather than the horizon total.
    var full: Player { state.players.first { $0.id == player.id } ?? player }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    if !full.news.isEmpty { newsBox }
                    outlookSection
                    projSection
                    signalSection
                    statSection
                    fixtureSection
                    if canSwap { swapButton }
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
        .preferredColorScheme(.light)
    }

    var header: some View {
        HStack(spacing: 14) {
            ShirtShape()
                .fill(Theme.teamColor(full.teamShort))
                .overlay(ShirtShape().stroke(Color.black.opacity(0.08), lineWidth: 1))
                .frame(width: 50, height: 44)
            VStack(alignment: .leading, spacing: 4) {
                Text(full.name).font(.system(size: 21, weight: .black)).foregroundColor(Theme.ink)
                Text("\(full.teamName) · \(full.posShort) · £\(full.price)")
                    .font(.system(size: 11.5)).foregroundColor(Theme.inkDim)
                HStack(spacing: 5) {
                    if full.penTaker { Tag(text: "PENALTIES", color: Theme.amber) }
                    if full.setPieces { Tag(text: "SET PIECES", color: Theme.cyan) }
                    if full.flagged { Tag(text: "FLAGGED", color: Theme.red, filled: true) }
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(String(format: "%.1f", full.proj))
                    .font(.mono(24, .bold)).foregroundColor(Theme.lime)
                Text("NEXT \(state.horizon)").font(.label(7.5)).tracking(1).foregroundColor(Theme.inkDim)
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

    /// The part of the card that isn't just a stat dump: what the model thinks
    /// happens next, and how confident it is.
    var outlookSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "Next gameweek")
            HStack(spacing: 10) {
                StatTile(value: String(format: "%.1f", full.projByGw.at(state.gwFrom)),
                         caption: "Expected", color: Theme.lime)
                StatTile(value: String(format: "%.0f", full.ceiling),
                         caption: "Ceiling", color: Theme.cyan)
                StatTile(value: "\(Int(full.haulProb * 100))%",
                         caption: "Haul 10+", color: Theme.magenta)
            }
            VStack(alignment: .leading, spacing: 7) {
                meterRow("Starting place", full.startSecurity, Theme.lime,
                         security(full.startSecurity))
                if abs(full.formMult - 1) > 0.02 {
                    meterRow(full.formMult > 1 ? "In form" : "Out of form",
                             min(abs(full.formMult - 1) / 0.45, 1),
                             full.formMult > 1 ? Theme.green : Theme.red,
                             String(format: "%+.0f%% on goals, assists and bonus",
                                    (full.formMult - 1) * 100))
                }
                meterRow("Chance of a blank", full.blankProb, Theme.amber,
                         String(format: "%.0f%% chance of two points or fewer", full.blankProb * 100))
                meterRow("Ownership", min(full.own / 60, 1), Theme.cyan,
                         String(format: "%.1f%% of managers own him", full.own))
                if full.priceMomentum != 0 {
                    meterRow(full.priceMomentum > 0 ? "Price rising" : "Price falling",
                             abs(full.priceMomentum), full.priceMomentum > 0 ? Theme.green : Theme.red,
                             "\(Int(abs(full.priceMomentum) * 100))% of the way to a change")
                }
            }
        }
    }

    /// Plain-language reading of the squad-status number, which is a blend of
    /// start rate, starts per 90 played and minutes per appearance.
    func security(_ v: Double) -> String {
        switch v {
        case 0.85...: return "nailed on — starts and finishes matches"
        case 0.65..<0.85: return "regular starter, occasionally hooked early"
        case 0.45..<0.65: return "in and out of the side"
        default: return "squad player — the minutes aren't there"
        }
    }

    func meterRow(_ title: String, _ frac: Double, _ color: Color, _ note: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundColor(Theme.ink)
                Spacer()
                Text(note).font(.system(size: 10.5)).foregroundColor(Theme.inkDim)
            }
            Meter(fraction: frac, color: color, height: 5)
        }
    }

    /// What the model is actually reading on this player. Without it the
    /// projection is a number with no argument behind it.
    var signalSection: some View {
        var rows: [(String, String)] = []
        rows.append(("Expected goals / 90", String(format: "%.2f", full.mins > 0 ? full.xg / Double(full.mins) * 90 : 0)))
        rows.append(("Expected assists / 90", String(format: "%.2f", full.mins > 0 ? full.xa / Double(full.mins) * 90 : 0)))
        rows.append(("Threat index", String(format: "%.0f", full.threat)))
        rows.append(("Creativity index", String(format: "%.0f", full.creativity)))
        rows.append(("Minutes per appearance", String(format: "%.0f'", full.expMins)))
        if full.penTaker { rows.append(("Penalties", "first choice")) }
        if full.setPieces { rows.append(("Set pieces", "on duty")) }
        if full.costChangeStart != 0 {
            rows.append(("Price since season start",
                         String(format: "%+.1fm", Double(full.costChangeStart) / 10)))
        }
        return VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "What the model reads")
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                    HStack {
                        Text(r.0).font(.system(size: 12.5)).foregroundColor(Theme.inkDim)
                        Spacer()
                        Text(r.1).font(.mono(12, .bold)).foregroundColor(Theme.ink)
                    }
                    .padding(.vertical, 7)
                    if i < rows.count - 1 { Divider().background(Theme.line) }
                }
            }
            .padding(.horizontal, 13)
            .panel()
            Text("Each of these feeds the per-gameweek projection above, scaled by the opponent that week and whether the match is home or away.")
                .font(.system(size: 11)).foregroundColor(Theme.inkDim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    var projSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Projected points by gameweek")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(full.projByGw.keys.prefix(16), id: \.self) { gw in
                        let v = full.projByGw.at(gw)
                        VStack(spacing: 3) {
                            Text("GW\(gw)").font(.mono(8, .medium)).foregroundColor(Theme.inkDim)
                            Text(String(format: "%.1f", v))
                                .font(.mono(13, .bold))
                                .foregroundColor(gw == state.gwFrom ? Theme.lime : Theme.ink)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 7)
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
            SectionLabel(text: state.isPreseason ? "Last season" : "This season")
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
                if full.pos == 1 {
                    stat("\(full.saves)", "SAVES")
                } else {
                    stat("\(full.cleanSheets)", "CLEAN SHEETS")
                }
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
            SectionLabel(text: "Upcoming fixtures")
            VStack(spacing: 5) {
                ForEach(Array(fixtures.enumerated()), id: \.offset) { _, item in
                    HStack {
                        Text("GW\(item.gw)").font(.mono(11, .medium)).foregroundColor(Theme.inkDim)
                            .frame(width: 44, alignment: .leading)
                        Text("\(item.fx.home ? "vs" : "@") \(state.teamName(item.fx.opp))")
                            .font(.system(size: 13, weight: .semibold)).foregroundColor(Theme.ink)
                        Spacer()
                        Text(String(format: "%.1f", full.projByGw.at(item.gw)))
                            .font(.mono(11, .bold)).foregroundColor(Theme.lime)
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

    var swapButton: some View {
        Button {
            dismiss()
            onSwap(player)
        } label: {
            Label("Swap this player", systemImage: "arrow.left.arrow.right")
                .font(.system(size: 15, weight: .semibold)).foregroundColor(.white)
                .frame(maxWidth: .infinity).padding(.vertical, 14)
                .background(Theme.lime)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}

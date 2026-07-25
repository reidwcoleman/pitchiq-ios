import SwiftUI

/// The Transfers tab — the workbench. Everything here is about the fifteen you
/// hold right now: what's wrong with them, the best single move, whether a
/// second move pays for its −4, who's about to change price, and which good
/// players nobody owns.
struct TransfersView: View {
    @EnvironmentObject var state: AppState
    @State private var section = 0
    @State private var detail: Player?

    var body: some View {
        VStack(spacing: 0) {
            AppHeader(subtitle: state.isConnected ? "Your moves" : "Suggested moves")
            Picker("", selection: $section) {
                Text("Moves").tag(0)
                Text("Squad check").tag(1)
                Text("Market").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.bottom, 10)

            ScrollView {
                VStack(spacing: 12) {
                    switch section {
                    case 0: movesSection
                    case 1: checkSection
                    default: marketSection
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 26)
            }
        }
        .background(Theme.bg)
        .sheet(item: $detail) { p in PlayerDetailSheet(player: p) }
    }

    // MARK: - moves

    @ViewBuilder var movesSection: some View {
        let board = state.insights.board
        if !state.isConnected {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "link").font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Theme.cyan).frame(width: 20)
                Text("These moves are measured against the squad PitchIQ recommends, which is already optimal — so the gains look small. Connect your FPL team in Settings and this becomes a ranked list of the transfers **you** should make.")
                    .font(.system(size: 12.5)).foregroundColor(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.cyan.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 13))
        }
        if board.options.isEmpty {
            EmptyNote(icon: "checkmark.seal",
                      title: "Nothing worth doing",
                      detail: board.holdReason.isEmpty
                      ? "No legal transfer improves this squad over the rest of the season. Bank the free transfer."
                      : board.holdReason)
        } else {
            if !board.holdReason.isEmpty {
                verdictCard(board.holdReason, color: Theme.cyan, icon: "tray.and.arrow.down.fill",
                            title: "Recommendation: hold")
            } else if let best = board.bestSingle {
                verdictCard(
                    "\(best.out.name) → \(best.inn.name) is the strongest single move available: "
                    + String(format: "+%.1f points over the rest of the season, +%.1f over the next %d gameweeks.",
                             best.gainWeighted, best.gainWindow, state.horizon),
                    color: Theme.lime, icon: "arrow.left.arrow.right",
                    title: "Recommendation: make one transfer")
            }

            hitCard

            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "Every move, ranked")
                Text("Sorted by what each move adds to your **starting eleven** across the coming gameweeks — not by the incoming player's own projection. Bench points don't count unless you play Bench Boost. Tap a row for the reasoning.")
                    .font(.system(size: 11.5)).foregroundColor(Theme.inkDim)
                ForEach(board.options.prefix(20)) { o in
                    TransferOptionRow(option: o, horizon: state.horizon)
                        .onTapGesture { detail = o.inn }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .panel()
        }
    }

    @ViewBuilder var hitCard: some View {
        let pairs = state.insights.board.pairs
        if let best = pairs.first {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "Is a second transfer worth −4?",
                             accent: best.worthIt ? Theme.green : Theme.red)
                HStack(spacing: 8) {
                    Text(best.worthIt ? "Yes" : "No")
                        .font(.system(size: 22, weight: .black))
                        .foregroundColor(best.worthIt ? Theme.green : Theme.red)
                    Text(String(format: "%+.1f pts after the hit", best.netAfterHit))
                        .font(.mono(13, .bold)).foregroundColor(Theme.inkDim)
                }
                VStack(spacing: 5) {
                    pairLine(best.first)
                    pairLine(best.second)
                }
                Text(String(format: "Together these two gain %.1f points over the next %d gameweeks. A hit costs a flat 4, so the pair %@.",
                            best.totalWindowGain, state.horizon,
                            best.worthIt ? "comes out ahead" : "does not pay for itself — use one free transfer and wait"))
                    .font(.system(size: 12)).foregroundColor(Theme.inkDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .panel()
        }
    }

    func pairLine(_ o: Advisor.TransferOption) -> some View {
        HStack(spacing: 6) {
            Text(o.out.name).font(.system(size: 12.5, weight: .semibold))
                .foregroundColor(Theme.inkDim).strikethrough().lineLimit(1)
            Image(systemName: "arrow.right").font(.system(size: 8, weight: .bold))
                .foregroundColor(Theme.lime)
            Text(o.inn.name).font(.system(size: 12.5, weight: .bold))
                .foregroundColor(Theme.ink).lineLimit(1)
            Spacer()
            Text(String(format: "%+.1f", o.gainWindow))
                .font(.mono(11, .bold))
                .foregroundColor(o.gainWindow >= 0 ? Theme.green : Theme.red)
        }
    }

    func verdictCard(_ text: String, color: Color, icon: String, title: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionLabel(text: title, accent: color)
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon).font(.system(size: 16, weight: .semibold))
                    .foregroundColor(color).frame(width: 22)
                Text(text).font(.system(size: 14, weight: .semibold)).foregroundColor(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(color.opacity(0.35), lineWidth: 1.5))
    }

    // MARK: - squad check

    @ViewBuilder var checkSection: some View {
        let checks = state.insights.audit
        if checks.isEmpty {
            EmptyNote(icon: "checkmark.shield.fill", title: "Squad looks healthy",
                      detail: "No injuries, no dead weight, no idle money and no blank gameweeks in the fifteen.")
        } else {
            ForEach(checks) { c in
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        Image(systemName: icon(c.severity))
                            .font(.system(size: 13, weight: .semibold)).foregroundColor(color(c.severity))
                        Text(c.title).font(.system(size: 14, weight: .heavy)).foregroundColor(Theme.ink)
                        Spacer()
                        Tag(text: label(c.severity), color: color(c.severity))
                    }
                    Text(c.detail).font(.system(size: 12.5)).foregroundColor(Theme.inkDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .panel()
            }
        }
        if !state.isConnected {
            Text("These checks run on the recommended squad. Connect your FPL team in Settings to audit your own.")
                .font(.system(size: 11.5)).foregroundColor(Theme.inkDim)
                .padding(.horizontal, 4)
        }
    }

    func icon(_ s: Int) -> String {
        s >= 2 ? "exclamationmark.triangle.fill" : (s == 1 ? "eye.fill" : "info.circle.fill")
    }
    func color(_ s: Int) -> Color { s >= 2 ? Theme.red : (s == 1 ? Theme.amber : Theme.cyan) }
    func label(_ s: Int) -> String { s >= 2 ? "ACT NOW" : (s == 1 ? "WATCH" : "NOTED") }

    // MARK: - market

    @ViewBuilder var marketSection: some View {
        let risers = state.insights.risers
        let fallers = state.insights.fallers
        if risers.isEmpty && fallers.isEmpty {
            EmptyNote(icon: "chart.line.uptrend.xyaxis", title: "No price movement yet",
                      detail: "FPL publishes transfer counts once the game opens for the season. Risers and fallers will appear here as managers start moving.")
        } else {
            priceCard("About to rise", risers, Theme.green, "arrow.up.right",
                      "Buy before the deadline and you keep the extra value.")
            priceCard("About to fall", fallers, Theme.red, "arrow.down.right",
                      "Selling after a fall costs you 0.1m of team value permanently.")
        }

        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "Differentials")
            Text("Players projecting like top picks who fewer than 8% of managers own. Rank is within their position.")
                .font(.system(size: 11.5)).foregroundColor(Theme.inkDim)
            ForEach(state.insights.differentials.prefix(10)) { d in
                HStack(spacing: 10) {
                    Tag(text: d.player.posShort, color: d.player.posColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(d.player.name).font(.system(size: 14, weight: .heavy)).foregroundColor(Theme.ink)
                        Text("\(d.player.teamShort) · £\(d.player.price) · #\(d.rank) in position")
                            .font(.mono(10, .medium)).foregroundColor(Theme.inkDim)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(String(format: "%.1f", d.player.proj))
                            .font(.mono(15, .bold)).foregroundColor(Theme.lime)
                        Text(String(format: "%.1f%% owned", d.player.own))
                            .font(.mono(9, .medium)).foregroundColor(Theme.magenta)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { detail = d.player }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()

        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "Best value")
            Text("Projected points per £m over the next \(state.horizon) gameweeks — where the budget works hardest.")
                .font(.system(size: 11.5)).foregroundColor(Theme.inkDim)
            ForEach(state.insights.valuePicks.prefix(8)) { p in
                HStack(spacing: 10) {
                    Tag(text: p.posShort, color: p.posColor)
                    Text(p.name).font(.system(size: 14, weight: .heavy)).foregroundColor(Theme.ink)
                    Text("£\(p.price)").font(.mono(11, .medium)).foregroundColor(Theme.inkDim)
                    Spacer()
                    Text(String(format: "%.2f", p.valueScore))
                        .font(.mono(14, .bold)).foregroundColor(Theme.cyan)
                    Text("pts/£m").font(.label(8)).foregroundColor(Theme.inkDim)
                }
                .contentShape(Rectangle())
                .onTapGesture { detail = p }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    @ViewBuilder
    func priceCard(_ title: String, _ moves: [Advisor.PriceMove], _ color: Color,
                   _ icon: String, _ note: String) -> some View {
        if !moves.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: icon).font(.system(size: 11, weight: .bold)).foregroundColor(color)
                    SectionLabel(text: title, accent: color)
                }
                Text(note).font(.system(size: 11.5)).foregroundColor(Theme.inkDim)
                ForEach(moves.prefix(6)) { m in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(m.player.name).font(.system(size: 13, weight: .bold))
                                .foregroundColor(Theme.ink)
                            Text("\(m.player.teamShort) £\(m.player.price)")
                                .font(.mono(10, .medium)).foregroundColor(Theme.inkDim)
                            Spacer()
                            Text("\(Int(m.progress * 100))%")
                                .font(.mono(11, .bold)).foregroundColor(color)
                        }
                        Meter(fraction: m.progress, color: color)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .panel()
        }
    }
}

// MARK: - rows

struct TransferOptionRow: View {
    let option: Advisor.TransferOption
    let horizon: Int
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Tag(text: option.outStarts ? option.out.posShort : "BENCH",
                    color: option.outStarts ? option.out.posColor : Theme.inkDim)
                Text(option.out.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.inkDim).strikethrough().lineLimit(1)
                Image(systemName: "arrow.right").font(.system(size: 9, weight: .bold))
                    .foregroundColor(Theme.lime)
                Text(option.inn.name).font(.system(size: 13.5, weight: .heavy))
                    .foregroundColor(Theme.ink).lineLimit(1)
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(String(format: "%+.1f", option.gainWeighted))
                        .font(.mono(13, .bold))
                        .foregroundColor(option.gainWeighted > 0.05 ? Theme.green
                                         : (option.gainWeighted < -0.05 ? Theme.red : Theme.inkDim))
                    Text("season").font(.label(7.5)).foregroundColor(Theme.inkDim)
                }
            }
            HStack(spacing: 12) {
                metric(String(format: "%+.1f", option.gainNext), "next GW")
                metric(String(format: "%+.1f", option.gainWindow), "\(horizon) GWs")
                metric(option.spend == 0 ? "level"
                       : String(format: "%+.1fm", Double(option.spend) / 10), "price")
                Spacer()
                Button { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .bold)).foregroundColor(Theme.inkDim)
                }
            }
            if expanded {
                ForEach(Array(option.reasons.enumerated()), id: \.offset) { _, r in
                    HStack(alignment: .top, spacing: 6) {
                        Text("▸").font(.system(size: 10)).foregroundColor(Theme.lime)
                        Text(r).font(.system(size: 12)).foregroundColor(Theme.inkDim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) { Divider().background(Theme.line) }
    }

    func metric(_ v: String, _ k: String) -> some View {
        HStack(spacing: 4) {
            Text(v).font(.mono(11, .bold)).foregroundColor(Theme.ink)
            Text(k).font(.label(8)).foregroundColor(Theme.inkDim)
        }
    }
}

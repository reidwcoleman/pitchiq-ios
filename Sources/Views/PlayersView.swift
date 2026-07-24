import SwiftUI

struct PlayersView: View {
    @EnvironmentObject var state: AppState
    @State private var search = ""
    @State private var posFilter = 0
    @State private var maxPrice = 15.5
    @State private var sortMode: SortMode = .proj
    @State private var detail: Player?

    enum SortMode: String, CaseIterable {
        case proj = "Projected pts"
        case ppg = "PPG last season"
        case price = "Price (low → high)"
    }

    var filtered: [Player] {
        var list = state.players.filter { Double($0.cost) / 10 <= maxPrice }
        if posFilter > 0 { list = list.filter { $0.pos == posFilter } }
        if !search.isEmpty {
            let q = search.lowercased()
            list = list.filter {
                $0.name.lowercased().contains(q) || $0.teamShort.lowercased().contains(q)
                    || $0.teamName.lowercased().contains(q)
            }
        }
        switch sortMode {
        case .proj: list.sort { $0.proj > $1.proj }
        case .ppg: list.sort { $0.ppg != $1.ppg ? $0.ppg > $1.ppg : $0.proj > $1.proj }
        case .price: list.sort { $0.cost != $1.cost ? $0.cost < $1.cost : $0.proj > $1.proj }
        }
        return Array(list.prefix(100))
    }

    var body: some View {
        VStack(spacing: 0) {
            ControlsBar()
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 12))
                        .foregroundColor(Theme.inkDim)
                    TextField("Search player or team", text: $search)
                        .font(.system(size: 14))
                        .foregroundColor(Theme.ink)
                        .autocorrectionDisabled()
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(Theme.panel)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Theme.line, lineWidth: 1))

                Picker("", selection: $posFilter) {
                    Text("All").tag(0)
                    Text("GK").tag(1)
                    Text("DEF").tag(2)
                    Text("MID").tag(3)
                    Text("FWD").tag(4)
                }
                .pickerStyle(.menu)
                .tint(Theme.lime)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 6)

            HStack {
                Menu {
                    ForEach(SortMode.allCases, id: \.self) { m in
                        Button(m.rawValue) { sortMode = m }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.up.arrow.down").font(.system(size: 9, weight: .bold))
                        Text("Sort: \(sortMode.rawValue)").font(.mono(11))
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                    }
                    .foregroundColor(Theme.cyan)
                    .padding(.horizontal, 11).padding(.vertical, 7)
                    .background(Theme.panel)
                    .overlay(Capsule().stroke(Theme.line, lineWidth: 1))
                    .clipShape(Capsule())
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(Array(filtered.enumerated()), id: \.element.id) { i, p in
                        PlayerRow(rank: i + 1, player: p)
                            .onTapGesture { detail = p }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 20)
            }
        }
        .background(Theme.bg)
        .sheet(item: $detail) { p in
            PlayerDetailSheet(player: p)
        }
    }
}

struct PlayerRow: View {
    @EnvironmentObject var state: AppState
    let rank: Int
    let player: Player

    var posColor: Color {
        switch player.pos {
        case 1: return Theme.amber
        case 2: return Theme.cyan
        case 3: return Theme.lime
        default: return Theme.magenta
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Text("\(rank)")
                .font(.mono(13, .bold)).foregroundColor(Theme.inkDim)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(player.name).font(.system(size: 14, weight: .heavy)).foregroundColor(Theme.ink)
                    if player.flagged {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9)).foregroundColor(Theme.amber)
                    }
                }
                HStack(spacing: 6) {
                    Text(player.posShort)
                        .font(.mono(9, .bold)).foregroundColor(posColor)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(posColor.opacity(0.13))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                    Text("\(player.teamShort) · £\(player.price) · PPG \(String(format: "%.1f", player.ppg)) · \(String(format: "%.1f", player.own))% owned")
                        .font(.mono(10, .medium)).foregroundColor(Theme.inkDim)
                }
                FixtureChips(fixtures: Array(player.fixtures.prefix(4)))
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(String(format: "%.1f", player.proj))
                    .font(.mono(18, .bold)).foregroundColor(Theme.lime)
                Text("proj pts").font(.label(8)).tracking(1).foregroundColor(Theme.inkDim)
                Text("xGI/90 \(String(format: "%.2f", player.xgi90))")
                    .font(.mono(9, .medium)).foregroundColor(Theme.inkDim)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .panel()
    }
}

struct FixtureChips: View {
    @EnvironmentObject var state: AppState
    let fixtures: [FixtureInfo]

    var body: some View {
        HStack(spacing: 4) {
            if fixtures.isEmpty {
                Text("BLANK").font(.mono(8, .bold)).foregroundColor(Theme.inkDim)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Color.white.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            ForEach(Array(fixtures.enumerated()), id: \.offset) { _, fx in
                Text("\(state.teamShort(fx.opp))\(fx.home ? "" : " (a)")")
                    .font(.mono(8, .bold))
                    .foregroundColor(Theme.diffColor(fx.diff))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Theme.diffColor(fx.diff).opacity(0.14))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
        }
    }
}

import SwiftUI

struct PlayersView: View {
    @EnvironmentObject var state: AppState
    var embedded = false
    @State private var search = ""
    @State private var posFilter = 0
    @State private var maxPrice = 16.0
    @State private var sortMode: SortMode = .proj
    @State private var ownedOnly = false
    @State private var detail: Player?

    enum SortMode: String, CaseIterable {
        case proj = "Projected"
        case value = "Value per £m"
        case ceiling = "Ceiling"
        case form = "Form"
        case owned = "Ownership"
        case price = "Price"
    }

    var squadIds: Set<Int> { Set(state.squad?.squad.map(\.id) ?? []) }

    var filtered: [Player] {
        var list = state.players.filter { Double($0.cost) / 10 <= maxPrice }
        if posFilter > 0 { list = list.filter { $0.pos == posFilter } }
        if ownedOnly { let ids = squadIds; list = list.filter { ids.contains($0.id) } }
        if !search.isEmpty {
            let q = search.lowercased()
            list = list.filter {
                $0.name.lowercased().contains(q) || $0.teamShort.lowercased().contains(q)
                    || $0.teamName.lowercased().contains(q)
            }
        }
        switch sortMode {
        case .proj: list.sort { $0.proj > $1.proj }
        case .value: list.sort { $0.valueScore > $1.valueScore }
        case .ceiling: list.sort { $0.ceiling != $1.ceiling ? $0.ceiling > $1.ceiling : $0.proj > $1.proj }
        case .form: list.sort { $0.form != $1.form ? $0.form > $1.form : $0.proj > $1.proj }
        case .owned: list.sort { $0.own != $1.own ? $0.own > $1.own : $0.proj > $1.proj }
        case .price: list.sort { $0.cost != $1.cost ? $0.cost < $1.cost : $0.proj > $1.proj }
        }
        return Array(list.prefix(120))
    }

    var body: some View {
        VStack(spacing: 0) {
            if !embedded { AppHeader(subtitle: "Rankings · next \(state.horizon) GW") }
            HStack(spacing: 8) {
                SearchField(text: $search, placeholder: "Search player or team")
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
            .padding(.horizontal, 16).padding(.bottom, 8)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Menu {
                        ForEach(SortMode.allCases, id: \.self) { m in
                            Button(m.rawValue) { sortMode = m }
                        }
                    } label: {
                        pill("arrow.up.arrow.down", sortMode.rawValue, Theme.cyan)
                    }
                    Menu {
                        Button("Any price") { maxPrice = 16 }
                        ForEach([12.0, 10.0, 8.0, 6.5, 5.5, 4.5], id: \.self) { p in
                            Button("≤ £\(String(format: "%.1f", p))m") { maxPrice = p }
                        }
                    } label: {
                        pill("sterlingsign.circle",
                             maxPrice >= 16 ? "Any price" : "≤ £\(String(format: "%.1f", maxPrice))m",
                             Theme.cyan)
                    }
                    Button { ownedOnly.toggle() } label: {
                        pill("checkmark.circle", "In my squad",
                             ownedOnly ? Theme.lime : Theme.inkDim)
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.bottom, 10)

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(Array(filtered.enumerated()), id: \.element.id) { i, p in
                        PlayerRow(rank: i + 1, player: p, owned: squadIds.contains(p.id))
                            .onTapGesture { detail = p }
                    }
                }
                .padding(.horizontal, 14).padding(.bottom, 20)
            }
        }
        .background(Theme.bg)
        .sheet(item: $detail) { p in PlayerDetailSheet(player: p) }
    }

    func pill(_ icon: String, _ text: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 9, weight: .semibold))
            Text(text).font(.mono(11))
        }
        .foregroundColor(color)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Theme.panel)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Theme.line, lineWidth: 1))
    }
}

struct PlayerRow: View {
    @EnvironmentObject var state: AppState
    let rank: Int
    let player: Player
    var owned = false

    var body: some View {
        HStack(spacing: 10) {
            Text("\(rank)").font(.mono(12, .bold)).foregroundColor(Theme.inkDim)
                .frame(width: 20)
            PlayerShot(player: player, size: 40)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(player.name).font(.system(size: 14, weight: .heavy)).foregroundColor(Theme.ink)
                    if player.flagged {
                        Image(systemName: "cross.case.fill")
                            .font(.system(size: 9)).foregroundColor(Theme.red)
                    }
                    if player.penTaker {
                        Image(systemName: "p.circle.fill")
                            .font(.system(size: 9)).foregroundColor(Theme.amber)
                    }
                    if owned { Tag(text: "OWNED", color: Theme.lime) }
                }
                HStack(spacing: 6) {
                    Tag(text: player.posShort, color: player.posColor)
                    Text("\(player.teamShort) · £\(player.price) · \(String(format: "%.1f", player.own))%")
                        .font(.mono(10, .medium)).foregroundColor(Theme.inkDim)
                }
                FixtureChips(fixtures: Array(player.fixtures.prefix(5)))
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 2) {
                Text(String(format: "%.1f", player.proj))
                    .font(.mono(18, .bold)).foregroundColor(Theme.lime)
                Text("proj").font(.label(8)).tracking(1).foregroundColor(Theme.inkDim)
                Text(String(format: "%.0f ceil", player.ceiling))
                    .font(.mono(9, .medium)).foregroundColor(Theme.cyan)
            }
        }
        .padding(.horizontal, 13).padding(.vertical, 10)
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
                    .background(Theme.bg2)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            ForEach(Array(fixtures.enumerated()), id: \.offset) { _, fx in
                Text("\(state.teamShort(fx.opp))\(fx.home ? "" : "ᵃ")")
                    .font(.mono(8, .bold))
                    .foregroundColor(Theme.diffColor(fx.diff))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Theme.diffColor(fx.diff).opacity(0.14))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
        }
    }
}

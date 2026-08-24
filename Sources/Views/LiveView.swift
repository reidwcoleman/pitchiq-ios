import SwiftUI

// MARK: - Saturday afternoon
//
// The one screen that isn't about the future. Your eleven, what they have
// scored so far, who is still to play, the bonus FPL hasn't awarded yet, and
// the ten matches it is all coming from.

struct LiveView: View {
    @EnvironmentObject var state: AppState
    @State private var detail: Player?
    @State private var standings: LeagueSummary?
    @State private var ticking = false

    var body: some View {
        VStack(spacing: 0) {
            AppHeader(subtitle: subtitle)
            ScrollView {
                VStack(spacing: 14) {
                    if state.team?.picks?.isEmpty ?? true {
                        connectPrompt
                    } else {
                        scoreboard
                        squadCard
                    }
                    leaguesCard
                    matchTicker
                    topScorers
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 26)
            }
            .refreshable { await state.refreshLive() }
        }
        .background(Theme.bg)
        .sheet(item: $detail) { p in PlayerDetailSheet(player: p) }
        .sheet(item: $standings) { l in StandingsSheet(league: l) }
        .task { await poll() }
    }

    var subtitle: String {
        let gw = state.liveGw
        if state.matchesInPlay { return "LIVE · GW \(gw)" }
        let done = state.liveFixtures.allSatisfy { $0.liveState == .finished }
        return done ? "GW \(gw) FINAL" : "GW \(gw)"
    }

    /// Poll while the app is on screen and matches are being played. Nothing
    /// moves between Monday and Friday, so nothing is requested then either.
    private func poll() async {
        guard !ticking else { return }
        ticking = true
        defer { ticking = false }
        while !Task.isCancelled {
            guard state.matchesInPlay else { return }
            try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await state.refreshLive()
        }
    }

    // MARK: the running total

    var scoreboard: some View {
        let squad = state.liveSquad
        return VStack(spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    SectionLabel(text: state.team?.teamName ?? "Your team", accent: Theme.lime)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(squad.points)")
                            .font(.mono(46, .black)).foregroundColor(Theme.ink)
                        Text("PTS").font(.label(11)).tracking(1.4).foregroundColor(Theme.inkDim)
                    }
                }
                Spacer()
                if let c = squad.captain {
                    VStack(alignment: .trailing, spacing: 3) {
                        Text("CAPTAIN").font(.system(size: 8, weight: .heavy)).tracking(1.2)
                            .foregroundColor(Theme.inkFaint)
                        PlayerShot(player: c.player, size: 42)
                            .overlay(alignment: .bottomLeading) {
                                Text("\(c.counted)")
                                    .font(.mono(11, .black)).foregroundColor(.white).figures()
                                    .padding(.horizontal, 5).padding(.vertical, 2)
                                    .background(Capsule().fill(Theme.magenta))
                                    .overlay(Capsule().stroke(Theme.panel, lineWidth: 1.5))
                                    .offset(x: -6, y: 4)
                            }
                        Text(c.player.name).font(.system(size: 10, weight: .bold))
                            .foregroundColor(Theme.inkDim).lineLimit(1)
                            .frame(maxWidth: 76)
                    }
                }
            }
            // how far through the gameweek the squad is
            Meter(fraction: Double(squad.played) / 11, color: Theme.lime, height: 4)
            HStack(spacing: 8) {
                pill("\(squad.played)/11", "played", Theme.lime)
                pill("\(squad.toPlay)", "to play", squad.toPlay > 0 ? Theme.cyan : Theme.inkDim)
                pill("+\(squad.provisionalBonus)", "prov. bonus", Theme.amber)
                if squad.transferCost > 0 {
                    pill("−\(squad.transferCost)", "hits", Theme.red)
                }
            }
            if let chip = state.team?.activeChip {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles").font(.system(size: 11))
                    Text("\(chipDisplayName(chip)) active this gameweek")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundColor(Theme.magenta)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
        .panel()
    }

    func pill(_ value: String, _ caption: String, _ color: Color) -> some View {
        VStack(spacing: 1) {
            Text(value).font(.mono(15, .bold)).foregroundColor(color)
            Text(caption.uppercased()).font(.label(7.5)).tracking(0.9).foregroundColor(Theme.inkDim)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 7)
        .background(Theme.bg2)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: the eleven

    var squadCard: some View {
        let squad = state.liveSquad
        return VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "Your eleven")
            VStack(spacing: 0) {
                ForEach(squad.starters.sorted { $0.pick.position < $1.pick.position }) { line in
                    LiveRow(line: line).onTapGesture { detail = line.player }
                    if line.id != squad.starters.last?.id { Divider().background(Theme.line) }
                }
            }
            SectionLabel(text: state.team?.activeChip == "bboost" ? "Bench · scoring" : "Bench")
                .padding(.top, 4)
            VStack(spacing: 0) {
                ForEach(squad.bench) { line in
                    LiveRow(line: line, dimmed: line.effectiveMultiplier == 0)
                        .onTapGesture { detail = line.player }
                }
            }
        }
        .padding(14)
        .panel()
    }

    // MARK: mini-leagues

    @ViewBuilder var leaguesCard: some View {
        let leagues = (state.team?.leagues ?? []).filter { !$0.isGlobal && $0.rank > 0 }
        if !leagues.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "Your leagues")
                ForEach(leagues.prefix(6)) { l in
                    HStack(spacing: 10) {
                        Text(l.name)
                            .font(.system(size: 13.5, weight: .semibold)).foregroundColor(Theme.ink)
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        if l.movement != 0 {
                            HStack(spacing: 2) {
                                Image(systemName: l.movement > 0 ? "arrow.up" : "arrow.down")
                                    .font(.system(size: 8, weight: .black))
                                Text("\(abs(l.movement))").font(.mono(10, .bold))
                            }
                            .foregroundColor(l.movement > 0 ? Theme.lime : Theme.red)
                        }
                        Text("\(l.rank)")
                            .font(.mono(14, .bold)).foregroundColor(Theme.ink)
                        Text("of \(l.size)")
                            .font(.mono(10)).foregroundColor(Theme.inkDim)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .bold)).foregroundColor(Theme.line)
                    }
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                    .onTapGesture { standings = l }
                }
            }
            .padding(14)
            .panel()
        }
    }

    // MARK: the matches

    var matchTicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "Gameweek \(state.liveGw)")
            ForEach(Array(state.liveFixtures.enumerated()), id: \.offset) { _, f in
                MatchRow(fixture: f)
            }
        }
        .padding(14)
        .panel()
    }

    // MARK: who is having the afternoon

    @ViewBuilder var topScorers: some View {
        let best = state.players
            .filter { state.live.minutes($0.id) > 0 }
            .map { (player: $0, pts: state.live.points($0.id)) }
            .sorted { $0.pts > $1.pts }
            .prefix(8)
        if !best.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "Top scorers this gameweek")
                ForEach(Array(best.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 10) {
                        PlayerShot(player: row.player, size: 32)
                        Text(row.player.name)
                            .font(.system(size: 13, weight: .bold)).foregroundColor(Theme.ink)
                        Text(row.player.teamShort)
                            .font(.mono(10)).foregroundColor(Theme.inkDim)
                        Spacer()
                        if (state.live.provisionalBonus[row.player.id] ?? 0) > 0 {
                            Tag(text: "+\(state.live.provisionalBonus[row.player.id] ?? 0) B", color: Theme.amber)
                        }
                        Text("\(row.pts)").font(.mono(16, .bold)).foregroundColor(Theme.lime)
                    }
                    .onTapGesture { detail = row.player }
                }
            }
            .padding(14)
            .panel()
        }
    }

    var connectPrompt: some View {
        EmptyNote(icon: "dot.radiowaves.left.and.right",
                  title: "Connect your team for a live score",
                  detail: "Settings → paste your FPL team ID and this becomes your eleven, your captain, your provisional bonus and your mini-league places, updating while the matches are on.")
    }
}

// MARK: - rows

struct LiveRow: View {
    let line: LiveLine
    var dimmed = false

    var body: some View {
        HStack(spacing: 10) {
            PlayerShot(player: line.player, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(line.player.name)
                        .font(.system(size: 13.5, weight: .bold)).foregroundColor(Theme.ink)
                        .lineLimit(1)
                    if line.pick.isCaptain { badge("C", Theme.magenta) }
                    if line.pick.isVice { badge("V", Theme.cyan) }
                    if line.autoSubbedIn { badge("IN", Theme.lime) }
                    if line.autoSubbedOut { badge("OUT", Theme.red) }
                }
                Text(status)
                    .font(.mono(9.5, .medium)).foregroundColor(statusColor)
            }
            Spacer(minLength: 4)
            Text("\(line.counted)")
                .font(.mono(17, .heavy)).figures()
                .foregroundColor(pointsColor)
                .frame(minWidth: 30, alignment: .trailing)
        }
        .padding(.vertical, 7)
        .opacity(dimmed ? 0.55 : 1)
        .contentShape(Rectangle())
    }

    /// A returning player should be visible at a glance in a list of eleven.
    var pointsColor: Color {
        if line.effectiveMultiplier == 0 { return Theme.inkFaint }
        if line.counted >= 6 { return Theme.lime }
        if line.counted <= 1 && line.state == .finished { return Theme.inkFaint }
        return Theme.ink
    }

    func badge(_ t: String, _ c: Color) -> some View {
        Text(t).font(.mono(8, .black)).foregroundColor(.white)
            .padding(.horizontal, 4).padding(.vertical, 1.5)
            .background(c).clipShape(Capsule())
    }

    var status: String {
        switch line.state {
        case .upcoming: return "\(line.player.teamShort) · to play"
        case .live(let m): return line.minutes > 0
            ? "\(line.player.teamShort) · \(line.minutes)' on the pitch"
            : "\(line.player.teamShort) · \(m)' — not on"
        case .finished: return line.minutes > 0
            ? "\(line.player.teamShort) · played \(line.minutes)'"
            : "\(line.player.teamShort) · did not play"
        }
    }

    var statusColor: Color {
        switch line.state {
        case .upcoming: return Theme.inkDim
        case .live: return line.minutes > 0 ? Theme.lime : Theme.amber
        case .finished: return line.minutes > 0 ? Theme.inkDim : Theme.red
        }
    }
}

struct MatchRow: View {
    @EnvironmentObject var state: AppState
    let fixture: APIFixture

    var body: some View {
        HStack(spacing: 8) {
            TeamBadge(teamId: fixture.team_h, size: 20)
            Text(state.teamShort(fixture.team_h))
                .font(.mono(11, .bold)).foregroundColor(Theme.ink)
                .frame(width: 34, alignment: .leading)
            Spacer(minLength: 2)
            Text(score)
                .font(.mono(14, .bold)).foregroundColor(Theme.ink)
            Spacer(minLength: 2)
            Text(state.teamShort(fixture.team_a))
                .font(.mono(11, .bold)).foregroundColor(Theme.ink)
                .frame(width: 34, alignment: .trailing)
            TeamBadge(teamId: fixture.team_a, size: 20)
            Text(clock)
                .font(.mono(9.5, .medium)).foregroundColor(clockColor)
                .frame(width: 48, alignment: .trailing)
        }
        .padding(.vertical, 4)
    }

    var score: String {
        switch fixture.liveState {
        case .upcoming: return "v"
        default: return "\(fixture.team_h_score ?? 0) – \(fixture.team_a_score ?? 0)"
        }
    }

    var clock: String {
        switch fixture.liveState {
        case .finished: return "FT"
        case .live(let m): return m >= 90 ? "90'+" : "\(m)'"
        case .upcoming:
            guard let k = fixture.kickoff else { return "" }
            let f = DateFormatter()
            f.dateFormat = Calendar.current.isDateInToday(k) ? "HH:mm" : "E HH:mm"
            return f.string(from: k)
        }
    }

    var clockColor: Color {
        switch fixture.liveState {
        case .live: return Theme.lime
        case .finished: return Theme.inkDim
        case .upcoming: return Theme.inkDim
        }
    }
}

// MARK: - mini-league standings

/// The table behind a mini-league row. FPL's own app buries this two taps deep
/// on a Saturday; here it is one, and it marks the manager's own row.
struct StandingsSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    let league: LeagueSummary

    @State private var rows: [LeagueStandings.Row] = []
    @State private var loading = true
    @State private var failed = false

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView().tint(Theme.lime)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if failed || rows.isEmpty {
                    EmptyNote(icon: "wifi.exclamationmark", title: "Couldn't load the table",
                              detail: "FPL didn't return standings for this league. It may still be building them after the deadline.")
                        .padding(16)
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(rows) { row in
                                StandingRow(row: row, isMe: row.entry == state.team?.entryId)
                                Divider().background(Theme.line)
                            }
                        }
                        .padding(.horizontal, 14)
                    }
                }
            }
            .background(Theme.bg)
            .navigationTitle(league.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.tint(Theme.lime)
                }
            }
        }
        .task {
            defer { loading = false }
            guard let standings = try? await FPLService.fetchStandings(leagueId: league.id) else {
                failed = true; return
            }
            rows = standings.standings.results
        }
    }
}

struct StandingRow: View {
    let row: LeagueStandings.Row
    var isMe = false

    var body: some View {
        HStack(spacing: 10) {
            Text("\(row.rank)")
                .font(.mono(13, .bold)).foregroundColor(Theme.inkDim)
                .frame(width: 34, alignment: .trailing)
            if row.movement != 0 {
                Image(systemName: row.movement > 0 ? "arrow.up" : "arrow.down")
                    .font(.system(size: 8, weight: .black))
                    .foregroundColor(row.movement > 0 ? Theme.lime : Theme.red)
            } else {
                Image(systemName: "minus").font(.system(size: 7))
                    .foregroundColor(Theme.line)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(row.entry_name)
                    .font(.system(size: 13.5, weight: isMe ? .black : .bold))
                    .foregroundColor(Theme.ink).lineLimit(1)
                Text(row.player_name)
                    .font(.system(size: 10.5)).foregroundColor(Theme.inkDim).lineLimit(1)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 1) {
                Text("\(row.total)").font(.mono(14, .bold)).foregroundColor(Theme.ink)
                Text("+\(row.event_total)").font(.mono(9.5)).foregroundColor(Theme.lime)
            }
        }
        .padding(.vertical, 8).padding(.horizontal, 8)
        .background(isMe ? Theme.lime.opacity(0.10) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

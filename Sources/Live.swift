import Foundation

// MARK: - The gameweek as it happens
//
// An FPL app gets opened most on a Saturday at half past five, and until now
// this one had nothing to say then: it projected the future and ignored the
// afternoon entirely. `event/{gw}/live/` publishes every player's points as
// they are scored, and the fixture list carries the score and the minute, so
// the whole picture is available without an account.

struct LiveStats: Decodable, Equatable {
    var minutes = 0
    var total_points = 0
    var bps = 0
    var goals_scored = 0
    var assists = 0
    var clean_sheets = 0
    var saves = 0
    var bonus = 0
    var yellow_cards = 0
    var red_cards = 0
    var defensive_contribution = 0
    var starts = 0
}

struct LiveElement: Decodable {
    struct Explain: Decodable { let fixture: Int }
    let id: Int
    let stats: LiveStats
    let explain: [Explain]
}

struct EventLive: Decodable {
    let elements: [LiveElement]
}

/// Everything the live screens read, computed once per refresh.
struct LiveBook {
    var gw = 0
    var stats: [Int: LiveStats] = [:]
    /// Which fixture each player is involved in this gameweek. Doubles list
    /// both; the first is enough for bonus, which is scored per match.
    var fixtures: [Int: [Int]] = [:]
    /// Bonus FPL has not yet awarded, worked out from live BPS.
    var provisionalBonus: [Int: Int] = [:]
    var fetched = Date.distantPast
    var isEmpty: Bool { stats.isEmpty }

    func points(_ id: Int) -> Int { (stats[id]?.total_points ?? 0) + (provisionalBonus[id] ?? 0) }
    func minutes(_ id: Int) -> Int { stats[id]?.minutes ?? 0 }

    /// Build from the live payload plus the fixture list, awarding the bonus
    /// that is still provisional.
    init(gw: Int, live: EventLive, fixtures: [APIFixture]) {
        self.gw = gw
        self.fetched = Date()
        var bpsByFixture: [Int: [(id: Int, bps: Int)]] = [:]
        for e in live.elements {
            stats[e.id] = e.stats
            let fs = e.explain.map(\.fixture)
            if !fs.isEmpty { self.fixtures[e.id] = fs }
            for f in fs where e.stats.minutes > 0 {
                bpsByFixture[f, default: []].append((e.id, e.stats.bps))
            }
        }

        // Only matches that are under way and have not had their bonus
        // confirmed. Once FPL adds it, `stats.bonus` carries it and a second
        // award here would double-count.
        let pending = Set(fixtures.filter { f in
            guard let id = f.id else { return false }
            guard f.started == true, f.finished != true else { return false }
            return !(bpsByFixture[id]?.contains { stats[$0.id]?.bonus ?? 0 > 0 } ?? false)
        }.compactMap(\.id))

        for (fixture, players) in bpsByFixture where pending.contains(fixture) {
            provisionalBonus.merge(Self.bonus(for: players)) { a, _ in a }
        }
    }

    init() {}

    /// FPL's bonus rules, ties included: everyone level at the top takes the
    /// full three, and the places they occupy are used up — two players tied on
    /// the highest BPS score three each and the next man down gets one, not two.
    static func bonus(for players: [(id: Int, bps: Int)]) -> [Int: Int] {
        var out: [Int: Int] = [:]
        let awards = [3, 2, 1]
        var slot = 0
        let groups = Dictionary(grouping: players.filter { $0.bps > 0 }, by: \.bps)
            .sorted { $0.key > $1.key }
        for (_, group) in groups {
            guard slot < awards.count else { break }
            for p in group { out[p.id] = awards[slot] }
            slot += group.count
        }
        return out
    }
}

// MARK: - A manager's picks for the live gameweek

struct SquadPick: Codable, Equatable, Identifiable {
    var element: Int
    var position: Int          // 1…11 on the pitch, 12…15 on the bench
    var multiplier: Int        // 0 benched, 1 playing, 2 captain, 3 triple captain
    var isCaptain: Bool
    var isVice: Bool

    var id: Int { element }
    var isBench: Bool { position > 11 }
}

/// One row of the live squad: who, how they are scoring, and where their match
/// has got to.
struct LiveLine: Identifiable {
    var player: Player
    var pick: SquadPick
    var points: Int
    var minutes: Int
    var state: MatchState
    var autoSubbedIn = false
    var autoSubbedOut = false

    var id: Int { player.id }
    /// Points as they will land in the manager's total.
    var counted: Int { points * effectiveMultiplier }
    var effectiveMultiplier: Int {
        if autoSubbedOut { return 0 }
        if autoSubbedIn { return 1 }
        return pick.multiplier
    }
    var hasPlayed: Bool { minutes > 0 }
    var stillToPlay: Bool { state == .upcoming || (state.isLive && minutes == 0) }
}

/// The live gameweek for one manager: the eleven, the bench, the substitutions
/// FPL will make at full time, and the running total.
struct LiveSquad {
    var lines: [LiveLine] = []
    var transferCost = 0
    var chip: String?

    var starters: [LiveLine] { lines.filter { !$0.pick.isBench } }
    var bench: [LiveLine] { lines.filter { $0.pick.isBench }.sorted { $0.pick.position < $1.pick.position } }
    var points: Int { lines.reduce(0) { $0 + $1.counted } - transferCost }
    var played: Int { lines.filter { !$0.pick.isBench && $0.hasPlayed }.count }
    var toPlay: Int { lines.filter { $0.effectiveMultiplier > 0 && $0.stillToPlay }.count }
    var inPlay: Int { lines.filter { $0.effectiveMultiplier > 0 && $0.state.isLive && $0.minutes > 0 }.count }
    var captain: LiveLine? { lines.first { $0.pick.isCaptain } }
    var provisionalBonus: Int = 0

    /// Assemble the squad, then work out the automatic substitutions.
    ///
    /// FPL replaces a starter who did not play with the first bench player who
    /// did, provided the formation stays legal — one keeper, at least three
    /// defenders, at least one forward. Bench order decides who is asked first,
    /// and the keeper only ever swaps with the keeper. The substitutions are
    /// only made once a player's match is over: a striker who is on the bench
    /// at kick-off has not blanked yet.
    init(picks: [SquadPick], players: [Int: Player], live: LiveBook,
         fixtures: [Int: MatchState], transferCost: Int, chip: String?) {
        self.transferCost = transferCost
        self.chip = chip
        lines = picks.compactMap { pick in
            guard let player = players[pick.element] else { return nil }
            let fixtureIds = live.fixtures[pick.element] ?? []
            let state = fixtureIds.compactMap { fixtures[$0] }.min(by: Self.earlier)
                ?? .upcoming
            return LiveLine(player: player, pick: pick,
                            points: live.points(pick.element),
                            minutes: live.minutes(pick.element),
                            state: state)
        }
        provisionalBonus = lines.reduce(0) { $0 + (live.provisionalBonus[$1.player.id] ?? 0) * max($1.pick.multiplier, 0) }
        guard chip != "bboost" else { return }      // a bench boost scores all fifteen
        applyAutoSubs()
    }

    init() {}

    private static func earlier(_ a: MatchState, _ b: MatchState) -> Bool {
        func rank(_ s: MatchState) -> Int {
            switch s { case .upcoming: return 0; case .live: return 1; case .finished: return 2 }
        }
        return rank(a) < rank(b)
    }

    private mutating func applyAutoSubs() {
        var starting = lines.filter { !$0.pick.isBench }
        let benchOrder = lines.filter { $0.pick.isBench }.sorted { $0.pick.position < $1.pick.position }
        var usedBench = Set<Int>()

        // A blank is only a blank once the match is over.
        func blanked(_ l: LiveLine) -> Bool { l.minutes == 0 && l.state == .finished }

        for (i, out) in starting.enumerated() where blanked(out) {
            let replacement = benchOrder.first { candidate in
                guard !usedBench.contains(candidate.player.id),
                      candidate.minutes > 0, !blanked(candidate) else { return false }
                if out.player.pos == 1 || candidate.player.pos == 1 {
                    return out.player.pos == 1 && candidate.player.pos == 1
                }
                var shape = starting.enumerated()
                    .filter { $0.offset != i }
                    .map { $0.element.player.pos }
                shape.append(candidate.player.pos)
                let defs = shape.filter { $0 == 2 }.count
                let fwds = shape.filter { $0 == 4 }.count
                return defs >= 3 && fwds >= 1
            }
            guard let replacement else { continue }
            usedBench.insert(replacement.player.id)
            starting[i].autoSubbedOut = true
            if let j = lines.firstIndex(where: { $0.player.id == out.player.id }) {
                lines[j].autoSubbedOut = true
            }
            if let j = lines.firstIndex(where: { $0.player.id == replacement.player.id }) {
                lines[j].autoSubbedIn = true
            }
        }
    }
}

// MARK: - Fetching

extension FPLService {
    static func fetchLive(gw: Int) async throws -> EventLive {
        let data = try await get("https://fantasy.premierleague.com/api/event/\(gw)/live/")
        return try JSONDecoder().decode(EventLive.self, from: data)
    }

    static func fetchStandings(leagueId: Int) async throws -> LeagueStandings {
        let data = try await get("https://fantasy.premierleague.com/api/leagues-classic/\(leagueId)/standings/")
        return try JSONDecoder().decode(LeagueStandings.self, from: data)
    }

    /// The manager's picks for a specific gameweek, with multipliers — which is
    /// what separates "your fifteen" from "your eleven, your captain and your
    /// bench order".
    static func fetchPicks(entryId: Int, gw: Int) async throws -> EntryPicks {
        let data = try await get("https://fantasy.premierleague.com/api/entry/\(entryId)/event/\(gw)/picks/")
        return try JSONDecoder().decode(EntryPicks.self, from: data)
    }
}

// MARK: - Recent minutes
//
// A season-long start rate is a lagging indicator, and it lags in exactly the
// situation that costs the most points: a player who lost his place a month ago
// still reads as nailed-on for weeks, because thirty starts in the bank drown
// out four on the bench. Between seasons the model already weights the recent
// past far more heavily than the distant past; within a season it was doing the
// opposite, treating August and last Saturday as the same evidence.
//
// The fix needs per-gameweek minutes, and those are already published in the
// payload the live screen reads. Six small requests — one per recent gameweek —
// give the whole league's rotation history, and they only change when a
// gameweek does.

struct RecentMinutes: Codable {
    /// player id → gameweek → minutes. Keyed by gameweek rather than by
    /// position in a list, which is what makes it possible to keep what we
    /// already have and fetch only what we don't.
    var byId: [Int: [Int: Int]] = [:]
    /// The gameweeks held, most recent first.
    var gws: [Int] = []
    /// Which season this belongs to, so a new one starts clean.
    var season = 0

    var throughGw: Int { gws.first ?? 0 }
    var isEmpty: Bool { byId.isEmpty || gws.isEmpty }

    /// How many weeks back the rotation signal is worth carrying.
    static let window = 6

    /// The weight on each gameweek back from the most recent one.
    static let weights: [Double] = [1.0, 0.82, 0.66, 0.5, 0.36, 0.24]

    struct Read {
        var startRate = 0.0     // weighted share of recent matches started
        var minShare = 0.0      // weighted share of 90 minutes played
        var evidence = 0.0      // weighted number of gameweeks behind it
    }

    func read(_ id: Int) -> Read? {
        guard let mins = byId[id], !mins.isEmpty, !gws.isEmpty else { return nil }
        var out = Read()
        var total = 0.0
        for (i, gw) in gws.enumerated() {
            guard i < Self.weights.count else { break }
            let m = mins[gw] ?? 0
            let w = Self.weights[i]
            total += w
            // 60 minutes is the line the game itself draws, and it separates a
            // start from a cameo more reliably than any other single number.
            out.startRate += w * (m >= 60 ? 1 : 0)
            out.minShare += w * min(Double(m) / 90, 1)
        }
        guard total > 0 else { return nil }
        out.startRate /= total
        out.minShare /= total
        out.evidence = total
        return out
    }

    /// Which gameweeks are missing, given where the season has got to. After a
    /// gameweek ends this is one week, not six — the previous version threw the
    /// whole table away and re-downloaded 2.6 MB every time the round changed.
    func missing(through gw: Int, season: Int) -> [Int] {
        guard season == self.season else {
            return Array(stride(from: gw, through: max(gw - Self.window + 1, 1), by: -1))
        }
        let held = Set(gws)
        return stride(from: gw, through: max(gw - Self.window + 1, 1), by: -1)
            .filter { !held.contains($0) }
    }

    mutating func absorb(gw: Int, minutes: [Int: Int]) {
        for (id, m) in minutes { byId[id, default: [:]][gw] = m }
        if !gws.contains(gw) { gws.append(gw) }
        gws.sort(by: >)
        // Forget anything past the window, including the players who only
        // appear in it, so the file cannot grow across a season.
        let keep = Set(gws.prefix(Self.window))
        gws = gws.filter { keep.contains($0) }
        for (id, weeks) in byId {
            let trimmed = weeks.filter { keep.contains($0.key) }
            if trimmed.isEmpty { byId.removeValue(forKey: id) } else { byId[id] = trimmed }
        }
    }
}

extension FPLService {
    /// Top the table up to `gw`, fetching only the gameweeks it does not
    /// already hold — one request after a round ends, none the rest of the
    /// week, and all six only on a fresh install or a new season.
    static func topUpRecentMinutes(_ existing: RecentMinutes, through gw: Int,
                                   season: Int) async -> RecentMinutes? {
        let wanted = existing.missing(through: gw, season: season)
        guard !wanted.isEmpty else { return nil }
        var out = existing.season == season ? existing : RecentMinutes()
        out.season = season
        var gained = false
        for g in wanted {
            guard let payload = try? await fetchLive(gw: g) else { continue }
            var minutes: [Int: Int] = [:]
            for element in payload.elements where element.stats.minutes > 0 {
                minutes[element.id] = element.stats.minutes
            }
            // A gameweek nobody has played yet is not evidence of anything —
            // skip it rather than stopping, or a round that has had its
            // deadline but not its kick-off would hide the weeks before it.
            guard !minutes.isEmpty else { continue }
            out.absorb(gw: g, minutes: minutes)
            gained = true
        }
        return gained ? out : nil
    }
}

import Foundation

// MARK: - Fetching

enum FPLService {
    static func fetch() async throws -> (Bootstrap, [APIFixture]) {
        async let boot: Bootstrap = get("https://fantasy.premierleague.com/api/bootstrap-static/")
        async let fixtures: [APIFixture] = get("https://fantasy.premierleague.com/api/fixtures/")
        return try await (boot, fixtures)
    }

    private static func get<T: Decodable>(_ url: String) async throws -> T {
        var req = URLRequest(url: URL(string: url)!)
        req.setValue("Mozilla/5.0 (PitchIQ iOS)", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONDecoder().decode(T.self, from: data)
    }
}

// MARK: - Projection model
// Per-fixture expected points: blended xG/xA attacking rates, Poisson clean
// sheets from team xGC/90, keeper saves, appearance + bonus rates, minutes
// security, FDR fixture multipliers, anchored 42% to PPG history; thin-data
// players (new signings / promoted clubs) lean on FPL's ep_next feed.

struct ProjectionEngine {
    let boot: Bootstrap
    let fixtures: [APIFixture]
    let gwFrom: Int
    let horizon: Int

    private static let goalPts = [0, 10, 6, 5, 4]
    private static let csPts = [0.0, 4, 4, 1, 0]
    private static let atkMult = [2: 1.22, 3: 1.0, 4: 0.86, 5: 0.72]
    private static let lambdaMult = [2: 0.72, 3: 1.0, 4: 1.28, 5: 1.55]
    private static let histMult = [2: 1.14, 3: 1.0, 4: 0.9, 5: 0.79]

    func teamFixtures(_ teamId: Int, gw: Int) -> [FixtureInfo] {
        fixtures.compactMap { f in
            guard f.event == gw else { return nil }
            if f.team_h == teamId { return FixtureInfo(opp: f.team_a, home: true, diff: f.team_h_difficulty ?? 3) }
            if f.team_a == teamId { return FixtureInfo(opp: f.team_h, home: false, diff: f.team_a_difficulty ?? 3) }
            return nil
        }
    }

    func horizonFixtures(_ teamId: Int) -> [FixtureInfo] {
        (gwFrom..<min(gwFrom + horizon, 39)).flatMap { teamFixtures(teamId, gw: $0) }
    }

    func buildPlayers() -> [Player] {
        let teamById = Dictionary(uniqueKeysWithValues: boot.teams.map { ($0.id, $0) })

        // team xGC/90 estimated from keepers' on-pitch xGC
        var teamXgc90: [Int: Double] = [:]
        for t in boot.teams {
            var xgc = 0.0, mins = 0
            for p in boot.elements where p.team == t.id && p.element_type == 1 {
                xgc += Double(p.expected_goals_conceded ?? "") ?? 0
                mins += p.minutes
            }
            teamXgc90[t.id] = mins > 900 ? xgc / Double(mins) * 90 : 1.45
        }

        var players: [Player] = boot.elements.map { p in
            let mins = Double(p.minutes)
            func per90(_ s: String?) -> Double {
                mins >= 400 ? (Double(s ?? "") ?? 0) / mins * 90 : 0
            }
            let ppg = Double(p.points_per_game ?? "") ?? 0
            let form = Double(p.form ?? "") ?? 0
            let epNext = Double(p.ep_next ?? "") ?? 0

            var avail = 1.0
            if let c = p.chance_of_playing_next_round { avail = Double(c) / 100 }
            if ["i", "s", "u", "n"].contains(p.status) { avail = min(avail, 0.15) }
            let flagged = p.status != "a"

            let expMins = min(mins / 38, 92)
            let pPlay = min(expMins / 30, 1)
            let p60 = min(expMins / 74, 1)
            let minShare = min(expMins / 90, 1)

            let xg90 = per90(p.expected_goals), xa90 = per90(p.expected_assists)
            let g90 = mins >= 400 ? Double(p.goals_scored) / mins * 90 : 0
            let a90 = mins >= 400 ? Double(p.assists) / mins * 90 : 0
            let goals90 = 0.65 * xg90 + 0.35 * g90
            let assists90 = 0.65 * xa90 + 0.35 * a90
            let attack90 = Double(Self.goalPts[p.element_type]) * goals90 + 3 * assists90

            let bonus90 = mins >= 400 ? Double(p.bonus) / mins * 90 : 0
            let saves90 = (p.element_type == 1 && mins >= 400) ? Double(p.saves) / mins * 90 : 0
            let lambda0 = teamXgc90[p.team] ?? 1.45

            func perFixture(_ fx: FixtureInfo) -> Double {
                let homeLean = fx.home ? 1.05 : 0.95
                let atk = attack90 * minShare * (Self.atkMult[fx.diff] ?? 1) * homeLean
                let lambda = lambda0 * (Self.lambdaMult[fx.diff] ?? 1) * (fx.home ? 0.92 : 1.08)
                let cs = Self.csPts[p.element_type] * exp(-lambda) * p60
                var keeper = 0.0
                if p.element_type == 1 { keeper = saves90 / 3 * minShare - lambda / 2 * minShare }
                let concede = p.element_type == 2 ? -(lambda / 2) * 0.5 * minShare : 0
                let appear = pPlay + p60
                let component = appear + atk + cs + keeper + concede + bonus90 * minShare
                let histBase = mins >= 700 ? ppg : max(ppg, epNext)
                let hist = histBase * (Self.histMult[fx.diff] ?? 1) * homeLean * max(pPlay, 0.3)
                let anchor = form > 0 ? 0.6 * hist + 0.4 * form * (Self.histMult[fx.diff] ?? 1) : hist
                var pts = 0.58 * component + 0.42 * anchor
                if mins < 700 { pts = 0.35 * pts + 0.65 * epNext * (Self.histMult[fx.diff] ?? 1) }
                return max(pts * avail, 0)
            }

            let fxs = horizonFixtures(p.team)
            let proj = fxs.reduce(0) { $0 + perFixture($1) }
            let t = teamById[p.team]

            return Player(
                id: p.id, name: p.web_name, pos: p.element_type, team: p.team,
                teamShort: t?.short_name ?? "?", teamName: t?.name ?? "?",
                cost: p.now_cost, proj: proj, perGw: proj / Double(max(horizon, 1)),
                ppg: ppg, xgi90: per90(p.expected_goal_involvements),
                own: Double(p.selected_by_percent ?? "") ?? 0,
                avail: avail, flagged: flagged, mins: p.minutes, fixtures: fxs
            )
        }
        players.sort { $0.proj > $1.proj }
        return players
    }
}

// MARK: - Squad optimizer
// Greedy seed + simulated annealing with single- and double-swap moves so the
// search can fund a premium upgrade by downgrading elsewhere in one move.

enum Optimizer {
    static let quota = [0, 2, 5, 5, 3]

    static func bestXI(_ squad: [Player]) -> (xi: [Player], bench: [Player], total: Double, formation: String)? {
        var by: [[Player]] = [[], [], [], [], []]
        for p in squad { by[p.pos].append(p) }
        for i in 1...4 { by[i].sort { $0.proj > $1.proj } }
        var pre: [[Double]] = [[], [], [], [], []]
        for i in 1...4 {
            var run = 0.0; pre[i] = [0]
            for p in by[i] { run += p.proj; pre[i].append(run) }
        }
        guard by[1].count >= 1 else { return nil }
        var best: (total: Double, d: Int, m: Int, f: Int)?
        for d in 3...5 {
            for m in 2...5 {
                let f = 10 - d - m
                guard f >= 1, f <= 3, by[2].count >= d, by[3].count >= m, by[4].count >= f else { continue }
                let total = pre[1][1] + pre[2][d] + pre[3][m] + pre[4][f]
                if best == nil || total > best!.total { best = (total, d, m, f) }
            }
        }
        guard let b = best else { return nil }
        let xi = [by[1][0]] + by[2].prefix(b.d) + by[3].prefix(b.m) + by[4].prefix(b.f)
        let xiSet = Set(xi.map(\.id))
        var bench = squad.filter { !xiSet.contains($0.id) && $0.pos != 1 }.sorted { $0.proj > $1.proj }
        if by[1].count > 1 { bench.insert(by[1][1], at: 0) }
        return (xi, bench, b.total, "\(b.d)-\(b.m)-\(b.f)")
    }

    static func objective(_ squad: [Player]) -> Double {
        guard let r = bestXI(squad) else { return -1e9 }
        let cap = r.xi.map(\.proj).max() ?? 0
        let benchSum = r.bench.reduce(0) { $0 + $1.proj }
        return r.total + cap + 0.12 * benchSum
    }

    static func feasible(_ squad: [Player], budget: Int) -> Bool {
        guard squad.reduce(0, { $0 + $1.cost }) <= budget else { return false }
        var clubs: [Int: Int] = [:]
        for p in squad {
            clubs[p.team, default: 0] += 1
            if clubs[p.team]! > 3 { return false }
        }
        return true
    }

    static func candidatePool(_ players: [Player], fitOnly: Bool) -> [Player] {
        var pool: [Player] = []
        for pos in 1...4 {
            let byPos = players.filter { $0.pos == pos && (fitOnly ? !$0.flagged : $0.avail > 0.5) }
            let top = byPos.prefix(48)
            let cheap = byPos.sorted { $0.cost != $1.cost ? $0.cost < $1.cost : $0.proj > $1.proj }.prefix(10)
            var seen = Set<Int>()
            for p in Array(top) + Array(cheap) where seen.insert(p.id).inserted { pool.append(p) }
        }
        return pool
    }

    static func greedySeed(_ pool: [Player], budget: Int, jitter: Bool) -> [Player] {
        var byPos: [[Player]] = [[], [], [], [], []]
        for p in pool { byPos[p.pos].append(p) }
        for i in 1...4 {
            byPos[i].sort { $0.proj > $1.proj }
            if jitter { byPos[i] = byPos[i].filter { _ in Double.random(in: 0...1) > 0.25 } }
        }
        var squad: [Player] = []
        var clubs: [Int: Int] = [:]
        var needs = quota

        func cheapestRest() -> Int {
            var sum = 0
            let inSquad = Set(squad.map(\.id))
            for pos in 1...4 {
                let remaining = byPos[pos].filter { !inSquad.contains($0.id) }.sorted { $0.cost < $1.cost }
                for i in 0..<needs[pos] { sum += i < remaining.count ? remaining[i].cost : 9990 }
            }
            return sum
        }

        for pos in 1...4 {
            for _ in 0..<quota[pos] {
                for p in byPos[pos] {
                    guard !squad.contains(p), clubs[p.team, default: 0] < 3 else { continue }
                    let cost = squad.reduce(0) { $0 + $1.cost } + p.cost
                    needs[pos] -= 1
                    let restMin = cheapestRest() - p.cost // p may be counted among cheapest remaining
                    needs[pos] += 1
                    if cost + max(restMin, 0) <= budget {
                        squad.append(p)
                        clubs[p.team, default: 0] += 1
                        needs[pos] -= 1
                        break
                    }
                }
            }
        }
        // pad if incomplete
        for pos in 1...4 {
            while squad.filter({ $0.pos == pos }).count < quota[pos] {
                guard let cand = byPos[pos]
                    .filter({ p in !squad.contains(p) && clubs[p.team, default: 0] < 3 })
                    .min(by: { $0.cost < $1.cost }) else { break }
                squad.append(cand)
                clubs[cand.team, default: 0] += 1
            }
        }
        return squad
    }

    static func optimize(players: [Player], budgetM: Double, fitOnly: Bool) -> SquadResult? {
        let budget = Int((budgetM * 10).rounded())
        let pool = candidatePool(players, fitOnly: fitOnly)
        var byPos: [[Player]] = [[], [], [], [], []]
        for p in pool { byPos[p.pos].append(p) }

        let iters = 12000
        var bestSquad: [Player]?
        var bestScore = -Double.infinity

        for restart in 0..<4 {
            var squad = greedySeed(pool, budget: budget, jitter: restart > 0)
            guard squad.count == 15, feasible(squad, budget: budget) else { continue }
            var score = objective(squad)
            var localBest = squad
            var localBestScore = score

            for it in 0..<iters {
                let T = 1.4 * (1 - Double(it) / Double(iters)) + 0.02
                var next = squad
                let swaps = Double.random(in: 0...1) < 0.35 ? 2 : 1
                var ok = true
                var touched = Set<Int>()
                for _ in 0..<swaps {
                    var i: Int
                    repeat { i = Int.random(in: 0..<15) } while touched.contains(i)
                    touched.insert(i)
                    let cands = byPos[next[i].pos]
                    guard let inn = cands.randomElement(), !next.contains(inn) else { ok = false; break }
                    next[i] = inn
                }
                guard ok, feasible(next, budget: budget) else { continue }
                let ns = objective(next)
                let d = ns - score
                if d > 0 || Double.random(in: 0...1) < exp(d / T) {
                    squad = next; score = ns
                    if ns > localBestScore { localBest = squad; localBestScore = ns }
                }
            }
            if localBestScore > bestScore { bestScore = localBestScore; bestSquad = localBest }
        }

        guard let squad = bestSquad, let r = bestXI(squad) else { return nil }
        let sorted = r.xi.sorted { $0.proj > $1.proj }
        return SquadResult(
            squad: squad, xi: r.xi, bench: r.bench, formation: r.formation,
            total: r.total, captain: sorted[0], vice: sorted[1],
            cost: squad.reduce(0) { $0 + $1.cost }
        )
    }
}

import Foundation

// MARK: - Season simulation
//
// The projection model can be checked against history. The *decision* layer
// cannot: there is no record of what a squad would have scored had it been
// managed differently. So it is checked against simulated seasons instead.
//
// The simulator takes the model's own per-gameweek projections as the truth,
// then adds the two things that make managing a team hard: players sometimes
// don't turn up, and players get injured for weeks at a time. Both policies
// under test see exactly the same information at exactly the same moment — the
// draws are seeded per season, not per policy — so a difference in final points
// is a difference in decision quality and nothing else.
//
// What this can prove: that one transfer policy extracts more points than
// another from identical beliefs. What it cannot prove: that the beliefs are
// right. That is what the historical harness is for.

struct SeasonSim {
    let players: [Player]
    let index: [Int: Int]                    // player id → row
    let doubleGws: Set<Int>
    let from: Int
    let end: Int

    init(players: [Player], from: Int, end: Int = 38, doubleGws: Set<Int> = []) {
        self.players = players
        self.from = from
        self.end = end
        self.doubleGws = doubleGws
        var idx: [Int: Int] = [:]
        for (i, p) in players.enumerated() { idx[p.id] = i }
        self.index = idx
    }

    /// One season's worth of drawn reality: what each player scored each week,
    /// and whether he was fit to be picked at the deadline.
    struct Truth {
        var points: [[Double]]      // player row → gameweek offset
        var available: [[Bool]]     // fit at that week's deadline
        var played: [[Bool]]
    }

    /// Injuries are the reason transfers exist. Without them a squad picked in
    /// August is optimal in May and every policy scores the same.
    static var injuryChancePerGw = 0.035
    static var injuryLengthMean = 3.4

    /// The share of the minutes a squad was expected to play that it actually
    /// plays, under the current injury settings. Real squads land near 0.82 —
    /// the historical backtest shows fifteen players expected to cover 85% of
    /// the available minutes covering 70% — so this is what the simulator is
    /// calibrated against.
    func realisedMinuteShare(seeds: Int = 40) -> Double {
        var expected = 0.0, got = 0.0
        for s in 0..<seeds {
            let truth = draw(seed: UInt64(bitPattern: Int64(s &* 2862933555777941757 &+ 3)))
            for (row, p) in players.enumerated() where p.playProb > 0.4 && p.expMins > 45 {
                for w in 0..<(end - from + 1) {
                    expected += p.playProb
                    got += truth.played[row][w] ? 1 : 0
                }
            }
        }
        return expected > 0 ? got / expected : 0
    }

    func draw(seed: UInt64) -> Truth {
        var rng = SeededRandom(seed: seed)
        let weeks = end - from + 1
        var points = [[Double]](repeating: [Double](repeating: 0, count: weeks), count: players.count)
        var available = [[Bool]](repeating: [Bool](repeating: true, count: weeks), count: players.count)
        var played = available

        for (row, p) in players.enumerated() {
            var out = 0                                   // weeks left injured
            for w in 0..<weeks {
                let gw = from + w
                if out > 0 {
                    out -= 1
                    available[row][w] = false
                    played[row][w] = false
                    continue
                }
                if Double.random(in: 0..<1, using: &rng) < Self.injuryChancePerGw * (1.4 - p.startSecurity) {
                    out = max(1, Int(Self.exponential(mean: Self.injuryLengthMean, rng: &rng).rounded()))
                    available[row][w] = false
                    played[row][w] = false
                    continue
                }
                let mean = p.projByGw.at(gw)
                guard mean > 0.01, p.playProb > 0.01 else { continue }
                let appears = Double.random(in: 0..<1, using: &rng) < p.playProb
                played[row][w] = appears
                guard appears else { continue }
                // Conditional on playing, FPL returns are lumpy: mostly the
                // appearance points, occasionally a haul. A gamma with the
                // model's conditional mean and a variance three times it
                // reproduces that shape closely enough to rank policies.
                let conditional = mean / p.playProb
                points[row][w] = max(0, (Self.gamma(mean: conditional, dispersion: 3, rng: &rng)).rounded())
            }
        }
        return Truth(points: points, available: available, played: played)
    }

    static func exponential(mean: Double, rng: inout SeededRandom) -> Double {
        -mean * log(max(Double.random(in: 0..<1, using: &rng), 1e-9))
    }

    /// Gamma by summing exponentials — shape is small here, so the crude form
    /// is both accurate enough and dependency-free.
    static func gamma(mean: Double, dispersion: Double, rng: inout SeededRandom) -> Double {
        let shape = max(mean / dispersion, 0.05)
        let scale = mean / shape
        var total = 0.0
        var whole = Int(shape)
        let frac = shape - Double(whole)
        while whole > 0 { total += exponential(mean: 1, rng: &rng); whole -= 1 }
        if frac > 0, Double.random(in: 0..<1, using: &rng) < frac {
            total += exponential(mean: 1, rng: &rng)
        }
        return total * scale
    }

    // MARK: - what a manager does

    /// The information a policy is allowed to use at a deadline.
    struct Board {
        let gw: Int
        let squad: [Int]            // player ids
        let bank: Int
        let freeTransfers: Int
        let available: (Int) -> Bool
        let players: [Player]
        let index: [Int: Int]
    }

    struct Move { var out: Int; var inn: Int }

    typealias Policy = (Board) -> [Move]

    /// Play out one season under one policy and return what it scored.
    func run(seed: UInt64, start: [Int], budget: Int, policy: Policy) -> Double {
        let truth = draw(seed: seed)
        var squad = start
        var fts = 1
        var bank = max(budget - squad.reduce(0) { $0 + players[index[$1]!].cost }, 0)
        var total = 0.0

        for gw in from...end {
            let w = gw - from
            if gw > from { fts = min(fts + 1, 5) }

            let board = Board(gw: gw, squad: squad, bank: bank, freeTransfers: fts,
                              available: { id in
                                  guard let row = self.index[id] else { return false }
                                  return truth.available[row][w]
                              },
                              players: players, index: index)
            let moves = policy(board)
            for m in moves {
                guard let slot = squad.firstIndex(of: m.out),
                      let outRow = index[m.out], let inRow = index[m.inn] else { continue }
                squad[slot] = m.inn
                bank += players[outRow].cost - players[inRow].cost
                if fts > 0 { fts -= 1 } else { total -= 4 }
            }

            // Pick the eleven the manager believes is best, then score it for
            // real — with the auto-substitutions the game would make.
            let picks = squad.map { id -> Pick in
                let p = players[index[id]!]
                let fit = truth.available[index[id]!][w]
                return Pick(p, proj: fit ? p.projByGw.at(gw) : 0)
            }
            guard let shape = Optimizer.evaluate(picks) else { continue }
            total += score(squad: squad, shape: shape, truth: truth, week: w, gw: gw)
        }
        return total
    }

    /// Score a gameweek exactly as the game does: the chosen eleven, automatic
    /// substitutions for anyone who didn't appear, and the armband doubled —
    /// falling to the vice-captain when the captain doesn't play.
    private func score(squad: [Int], shape: Optimizer.XI, truth: Truth, week w: Int, gw: Int) -> Double {
        var byPos: [Int: [(id: Int, believed: Double)]] = [:]
        for id in squad {
            let p = players[index[id]!]
            let fit = truth.available[index[id]!][w]
            byPos[p.pos, default: []].append((id, fit ? p.projByGw.at(gw) : 0))
        }
        for k in byPos.keys { byPos[k]!.sort { $0.believed > $1.believed } }

        var starters = [Int]()
        starters += byPos[1]!.prefix(1).map(\.id)
        starters += byPos[2]!.prefix(shape.d).map(\.id)
        starters += byPos[3]!.prefix(shape.m).map(\.id)
        starters += byPos[4]!.prefix(shape.f).map(\.id)
        var bench = squad.filter { !starters.contains($0) }
        bench.sort { a, b in
            let pa = players[index[a]!], pb = players[index[b]!]
            if (pa.pos == 1) != (pb.pos == 1) { return pb.pos == 1 }
            return pa.projByGw.at(gw) > pb.projByGw.at(gw)
        }

        // auto-substitutions
        var counted = starters
        for (i, id) in starters.enumerated() where !truth.played[index[id]!][w] {
            let pos = players[index[id]!].pos
            let replacement = bench.first { cand in
                let cp = players[index[cand]!]
                guard truth.played[index[cand]!][w] else { return false }
                if pos == 1 || cp.pos == 1 { return pos == 1 && cp.pos == 1 }
                var shapeNow = counted.filter { $0 != id }.map { players[index[$0]!].pos }
                shapeNow.append(cp.pos)
                return shapeNow.filter { $0 == 2 }.count >= 3
                    && shapeNow.filter { $0 == 4 }.count >= 1
            }
            if let replacement {
                counted[i] = replacement
                bench.removeAll { $0 == replacement }
            }
        }

        var total = counted.reduce(0.0) { $0 + truth.points[index[$1]!][w] }
        // armband
        let ranked = counted.sorted { players[index[$0]!].projByGw.at(gw) > players[index[$1]!].projByGw.at(gw) }
        if let captain = ranked.first {
            if truth.played[index[captain]!][w] {
                total += truth.points[index[captain]!][w]
            } else if ranked.count > 1 {
                total += truth.points[index[ranked[1]]!][w]
            }
        }
        return total
    }
}

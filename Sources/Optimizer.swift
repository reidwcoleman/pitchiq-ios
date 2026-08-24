import Foundation

// MARK: - Squad evaluation
// The scoring side of squad selection: best legal XI from a 15, the max-3-per-
// club and budget checks, and the entry point that hands the search off to
// `SquadSolver`. `evaluate` runs in the solver's innermost loop, so it does all
// its work in stack scratch space and operates on `Pick` (16 bytes, no
// references) rather than `Player` (four strings and two buffers, six
// retain/release pairs per copy).

enum Optimizer {
    static let quota = [0, 2, 5, 5, 3]

    /// Slot layout inside the scratch buffer: GK 0..<2, DEF 2..<7, MID 7..<12,
    /// FWD 12..<15 — each block held sorted descending by projection.
    private static let slotBase = [0, 0, 2, 7, 12]

    struct XI {
        let total: Double        // best starting XI
        let benchSum: Double     // the other four, raw
        let capProj: Double      // what the armband adds, vice-captain included
        let capBase: Double      // ... ignoring the vice, for A/B testing
        let autosub: Double      // what the bench is expected to be paid
        let d: Int, m: Int, f: Int
        var formation: String { "\(d)-\(m)-\(f)" }
    }

    /// Best legal XI from a 15-man squad, plus what the bench and the armband
    /// are actually worth. Allocation-free.
    ///
    /// Two things here were previously fudged, and both are worth real points:
    ///
    /// **The bench.** It used to be scored at a flat tenth of its projection —
    /// a number with no derivation. What a substitute is really worth is the
    /// chance he is *needed*: FPL brings him on exactly when a starter records
    /// no minutes. With ten outfield starters who each appear about 85% of the
    /// time, the chance at least one of them doesn't is not small, it is around
    /// three in four. So the first man on the bench is worth most of his own
    /// projection, not a tenth of it, and the fourth is worth almost nothing.
    /// Pricing that correctly is the whole argument for a playing bench, and
    /// the old constant argued the opposite.
    ///
    /// **The armband.** Captaincy was scored as one extra copy of the best
    /// player's projection. But if the captain doesn't play, the vice takes the
    /// armband — so what it is really worth is the captain's projection plus
    /// the vice's, weighted by the chance the captain is missing. That is what
    /// makes a nailed-on vice behind a doubtful captain worth owning.
    static func evaluate(_ squad: [Pick]) -> XI? {
        guard squad.count == 15 else { return nil }
        return withUnsafeTemporaryAllocation(of: Double.self, capacity: 30) { buf -> XI? in
            // buf[0..<15]  projections, sorted descending within position block
            // buf[15..<30] the matching appearance probabilities
            var c1 = 0, c2 = 0, c3 = 0, c4 = 0
            var all = 0.0
            for p in squad {
                all += p.proj
                let off: Int, n: Int
                switch p.pos {
                case 1: off = 0;  n = c1; if n >= 2 { return nil }; c1 += 1
                case 2: off = 2;  n = c2; if n >= 5 { return nil }; c2 += 1
                case 3: off = 7;  n = c3; if n >= 5 { return nil }; c3 += 1
                case 4: off = 12; n = c4; if n >= 3 { return nil }; c4 += 1
                default: return nil
                }
                var i = off + n
                while i > off, buf[i - 1] < p.proj {
                    buf[i] = buf[i - 1]
                    buf[i + 15] = buf[i + 14]
                    i -= 1
                }
                buf[i] = p.proj
                buf[i + 15] = Double(p.play)
            }
            guard c1 == 2, c2 == 5, c3 == 5, c4 == 3 else { return nil }

            let gk = buf[0]
            let d3 = buf[2] + buf[3] + buf[4]
            let d4 = d3 + buf[5]
            let d5 = d4 + buf[6]
            let m2 = buf[7] + buf[8]
            let m3 = m2 + buf[9]
            let m4 = m3 + buf[10]
            let m5 = m4 + buf[11]
            let f1 = buf[12]
            let f2 = f1 + buf[13]
            let f3 = f2 + buf[14]

            // the eight legal outfield shapes summing to 10
            var best = d3 + m4 + f3; var bd = 3, bm = 4, bf = 3
            @inline(__always) func consider(_ v: Double, _ dd: Int, _ mm: Int, _ ff: Int) {
                if v > best { best = v; bd = dd; bm = mm; bf = ff }
            }
            consider(d3 + m5 + f2, 3, 5, 2)
            consider(d4 + m3 + f3, 4, 3, 3)
            consider(d4 + m4 + f2, 4, 4, 2)
            consider(d4 + m5 + f1, 4, 5, 1)
            consider(d5 + m2 + f3, 5, 2, 3)
            consider(d5 + m3 + f2, 5, 3, 2)
            consider(d5 + m4 + f1, 5, 4, 1)
            let total = gk + best

            // --- the armband: captain, plus the vice for the weeks he is out
            var top = -1.0, second = -1.0, topPlay = 1.0
            @inline(__always) func offer(_ v: Double, _ play: Double) {
                if v > top { second = top; top = v; topPlay = play }
                else if v > second { second = v }
            }
            offer(buf[0], buf[15])
            for i in 0..<bd { offer(buf[2 + i], buf[17 + i]) }
            for i in 0..<bm { offer(buf[7 + i], buf[22 + i]) }
            for i in 0..<bf { offer(buf[12 + i], buf[27 + i]) }
            let capProj = max(top, 0) + (1 - topPlay) * max(second, 0)

            // --- the bench: how often each seat is actually called on
            //
            // The number of starters who fail to appear is a sum of ten
            // independent indicators; its Poisson approximation is accurate to
            // well within the noise here and costs three multiplications.
            var blanks = 0.0
            for i in 0..<bd { blanks += 1 - buf[17 + i] }
            for i in 0..<bm { blanks += 1 - buf[22 + i] }
            for i in 0..<bf { blanks += 1 - buf[27 + i] }
            let e = exp(-blanks)
            let atLeast1 = 1 - e
            let atLeast2 = 1 - e * (1 + blanks)
            let atLeast3 = 1 - e * (1 + blanks + blanks * blanks / 2)

            // Outfield substitutes in the order a manager would rank them.
            var subs: [Double] = []
            subs.reserveCapacity(3)
            for i in bd..<5 { subs.append(buf[2 + i]) }
            for i in bm..<5 { subs.append(buf[7 + i]) }
            for i in bf..<3 { subs.append(buf[12 + i]) }
            subs.sort(by: >)
            var autosub = (1 - buf[15]) * buf[1]           // the reserve keeper
            let odds = [atLeast1, atLeast2, atLeast3]
            for (i, v) in subs.prefix(3).enumerated() { autosub += odds[i] * v }

            return XI(total: total, benchSum: all - total, capProj: capProj,
                      capBase: max(top, 0), autosub: max(autosub, 0), d: bd, m: bm, f: bf)
        }
    }

    @inline(__always)
    static func objective(_ squad: [Pick]) -> Double {
        guard let r = evaluate(squad) else { return -1e9 }
        return r.total + r.capProj + r.autosub
    }

    /// A last sliver of weight on the bench beyond what the autosub model
    /// already pays it, standing in for the things it doesn't price: a Bench
    /// Boost later in the season, and the freedom a sellable substitute gives
    /// you when an injury forces a move.
    static let benchValue = 0.04

    /// The points a fifteen actually contributes in one gameweek: the best legal
    /// XI, the captain counted twice, and a small allowance for the bench.
    ///
    /// This is the number a transfer has to move. Ranking transfers by the
    /// change in a *player's* projection instead — which is what this app used
    /// to do — rates an upgrade to the player sitting fourth on your bench
    /// exactly as highly as the same upgrade to a starter, even though the first
    /// one cannot score you a single point.
    @inline(__always)
    static func scoringValue(_ squad: [Pick]) -> Double {
        guard let r = evaluate(squad) else { return -1e9 }
        return r.total + r.capProj + r.autosub + benchValue * r.benchSum
    }

    /// Budget and the max-three-per-club rule. Allocation-free.
    static func feasible(_ squad: [Pick], budget: Int) -> Bool {
        var cost = 0
        for p in squad { cost += Int(p.cost) }
        guard cost <= budget else { return false }
        return withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 32) { c -> Bool in
            for i in 0..<32 { c[i] = 0 }
            for p in squad {
                let t = Int(p.team)
                guard t >= 0, t < 32 else { continue }
                c[t] &+= 1
                if c[t] > 3 { return false }
            }
            return true
        }
    }

    // MARK: - display-side best XI (works on Players, runs once per render)

    static func bestXI(_ squad: [Player]) -> (xi: [Player], bench: [Player], total: Double, formation: String)? {
        var by: [[Player]] = [[], [], [], [], []]
        for p in squad where p.pos >= 1 && p.pos <= 4 { by[p.pos].append(p) }
        for i in 1...4 { by[i].sort { $0.proj != $1.proj ? $0.proj > $1.proj : $0.id < $1.id } }
        guard by[1].count >= 1 else { return nil }

        var pre: [[Double]] = [[], [], [], [], []]
        for i in 1...4 {
            var run = 0.0; pre[i] = [0]
            for p in by[i] { run += p.proj; pre[i].append(run) }
        }
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
        var bench = squad.filter { !xiSet.contains($0.id) && $0.pos != 1 }
            .sorted { $0.proj != $1.proj ? $0.proj > $1.proj : $0.id < $1.id }
        if by[1].count > 1 { bench.insert(by[1][1], at: 0) }
        return (xi, bench, b.total, "\(b.d)-\(b.m)-\(b.f)")
    }

    // MARK: - candidate pool

    /// Everyone who could plausibly be picked. The old pool was the 48
    /// best-projected plus the 10 cheapest per position — a hard cap the
    /// annealer needed to keep its search space small, and one that quietly
    /// excluded most mid-price players. The exact solver prunes by dominance
    /// instead (see `SquadSolver.reduce`), which removes strictly-worse players
    /// only, so nothing selectable is thrown away.
    static func candidatePool(_ players: [Player], fitOnly: Bool) -> [Player] {
        players.filter { $0.pos >= 1 && $0.pos <= 4 && (fitOnly ? !$0.flagged : $0.avail > 0.4) }
    }

    // MARK: - entry points

    /// Player-facing entry point: pool → exact-DP squad → display-ready result.
    /// `seeds` are squads the search should also start from; passing the squad
    /// already on screen is what stops the app rewriting the team on refresh.
    static func optimize(players: [Player], budgetM: Double, fitOnly: Bool,
                         seeds: [[Int]] = [], incumbent: [Int]? = nil,
                         incumbentMargin: Double = 0, benchWeight: Double = SquadSolver.Weights().bench,
                         exactCaptain: Bool = true,
                         weightOverride: SquadSolver.Weights? = nil) -> SquadResult? {
        let budget = Int((budgetM * 10).rounded())
        let pool = candidatePool(players, fitOnly: fitOnly)
        // The incumbent must survive pool reduction even if it has gone stale,
        // or "keep the team you already have" degrades into "rebuild".
        var picks = SquadSolver.reduce(pool.map { $0.pick($0.proj) })
        if let inc = incumbent {
            let have = Set(picks.map(\.id))
            let wanted = Set(inc.map(Int32.init))
            for p in pool where wanted.contains(Int32(p.id)) && !have.contains(Int32(p.id)) {
                picks.append(p.pick(p.proj))
            }
        }
        var weights = weightOverride ?? SquadSolver.Weights()
        if weightOverride == nil { weights.bench = benchWeight }
        guard let chosen = SquadSolver.solve(
            pool: picks, budget: budget, weights: weights,
            seeds: seeds.map { $0.map(Int32.init) },
            incumbent: incumbent.map { $0.map(Int32.init) },
            incumbentMargin: incumbentMargin, exactCaptain: exactCaptain)
        else { return nil }

        var byId = [Int32: Player](minimumCapacity: pool.count)
        for p in pool { byId[Int32(p.id)] = p }
        let squad = chosen.compactMap { byId[$0.id] }
        guard squad.count == 15, let r = bestXI(squad) else { return nil }
        let sorted = r.xi.sorted { $0.proj != $1.proj ? $0.proj > $1.proj : $0.id < $1.id }
        return SquadResult(
            squad: squad, xi: r.xi, bench: r.bench, formation: r.formation,
            total: r.total, captain: sorted[0], vice: sorted[1],
            cost: squad.reduce(0) { $0 + $1.cost }
        )
    }
}

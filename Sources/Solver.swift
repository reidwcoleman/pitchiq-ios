import Foundation

// MARK: - Deterministic squad solver
//
// Picks the 15 that maximise
//
//     best starting XI  +  captain (the XI's top scorer, counted twice)
//     +  benchWeight × the four who don't start
//
// subject to the £100m budget, the 2/5/5/3 quota and the max-three-per-club
// rule. Three stages:
//
//   1. An exact dynamic program over cost, per position and per formation,
//      relaxing only the club limit. Because the captain is always the
//      highest-projected player in his own position, enumerating which of the
//      four positions holds the captain turns the captain bonus into a fixed
//      weight on that position's top starter — so the DP optimum, maximised
//      over the four enumerations and eight formations, is a true optimum of
//      the full objective for the relaxed problem. No sampling, no randomness.
//   2. Club-limit repair by minimum-loss substitution.
//   3. Steepest-descent local search under the exact objective with the club
//      limit enforced, over single swaps and budget-funded double swaps,
//      seeded from stage 2 and from any squads the caller passes in (the team
//      already on screen, last week's team, …).
//
// This replaces a simulated annealer. Annealing searched a rugged objective
// from a random start, so it landed in a different local optimum whenever a
// single price ticked: measured against live data, a day's worth of ordinary
// price moves rewrote four or five of the fifteen. That is why the app used to
// show a different team on every visit. This solver is a pure function of its
// input, seeded from the squad already on screen, so a squad only changes when
// the change is worth points.

enum SquadSolver {
    static let quota = [0, 2, 5, 5, 3]

    /// The eight legal outfield shapes (defenders, midfielders, forwards).
    static let formations: [(d: Int, m: Int, f: Int)] = [
        (3, 4, 3), (3, 5, 2), (4, 3, 3), (4, 4, 2),
        (4, 5, 1), (5, 2, 3), (5, 3, 2), (5, 4, 1),
    ]

    struct Weights {
        /// How much a bench place is worth relative to a starting place. Bench
        /// players score only through auto-substitutions and Bench Boost, but a
        /// squad whose bench is worthless is one injury from a hole in the XI.
        var bench = 0.12
        /// 1.0 = the captain's score is added a second time, as in the game.
        var captain = 1.0
    }

    // MARK: - objective

    @inline(__always)
    static func score(_ squad: [Pick], _ w: Weights) -> Double {
        guard let r = Optimizer.evaluate(squad) else { return -.infinity }
        return r.total + w.captain * r.capProj + w.bench * r.benchSum
    }

    @inline(__always)
    static func cost(_ squad: [Pick]) -> Int {
        var c = 0
        for p in squad { c += Int(p.cost) }
        return c
    }

    @inline(__always)
    static func clubsLegal(_ squad: [Pick]) -> Bool {
        var c = [UInt8](repeating: 0, count: 32)
        for p in squad {
            let t = Int(p.team)
            guard t >= 0, t < 32 else { continue }
            c[t] &+= 1
            if c[t] > 3 { return false }
        }
        return true
    }

    // MARK: - entry point

    /// - Parameters:
    ///   - pool: candidates, `proj` already set to whatever value is being
    ///     maximised (one gameweek, a horizon total, a decay-weighted season).
    ///   - seeds: squads to start the local search from as well as the DP
    ///     solution. Passing the squad currently on screen is what keeps the
    ///     app's answer stable between refreshes.
    ///   - incumbent: the squad currently on screen. It is refined like any
    ///     other seed, but it only loses its place to a squad that beats it by
    ///     more than `incumbentMargin`. Without that margin the app rewrites the
    ///     team for a tenth of a point every time a price ticks, which is what
    ///     made the old build feel like it had no opinion.
    ///   - exactCaptain: run the four-way captain enumeration. Worth it for the
    ///     headline squad; skipped inside the season planner, where the value
    ///     being maximised is already an average over many gameweeks and the
    ///     enumeration costs more than it returns.
    static func solve(pool: [Pick], budget: Int, weights: Weights = Weights(),
                      seeds: [[Int32]] = [], incumbent: [Int32]? = nil,
                      incumbentMargin: Double = 0, exactCaptain: Bool = true) -> [Pick]? {
        guard !pool.isEmpty else { return nil }
        var byPos: [[Pick]] = [[], [], [], [], []]
        for p in pool where p.pos >= 1 && p.pos <= 4 { byPos[Int(p.pos)].append(p) }
        for i in 1...4 {
            byPos[i].sort { $0.proj != $1.proj ? $0.proj > $1.proj : $0.id < $1.id }
            guard byPos[i].count >= quota[i] else { return nil }
        }

        var candidates: [[Pick]] = []
        if let dp = relaxedOptimum(byPos: byPos, budget: budget, weights: weights,
                                  exactCaptain: exactCaptain) {
            candidates.append(dp)
        }
        var byId = [Int32: Pick](minimumCapacity: pool.count)
        for p in pool { byId[p.id] = p }
        func materialise(_ ids: [Int32]) -> [Pick]? {
            let sq = ids.compactMap { byId[$0] }
            guard sq.count == 15, Optimizer.evaluate(sq) != nil,
                  cost(sq) <= budget, clubsLegal(sq) else { return nil }
            return sq
        }
        for s in seeds { if let sq = materialise(s) { candidates.append(sq) } }

        // The incumbent gets refined too — a squad that has gone stale should
        // still be repaired — but it is scored separately so the margin applies.
        var incumbentResult: [Pick]?
        if let inc = incumbent, let sq = materialise(inc) {
            incumbentResult = localSearch(sq, byPos: byPos, budget: budget, weights: weights)
        }
        guard !candidates.isEmpty || incumbentResult != nil else { return nil }

        var best: [Pick]?
        var bestScore = -Double.infinity
        for seed in candidates {
            guard let repaired = repairClubs(seed, byPos: byPos, budget: budget, weights: weights)
            else { continue }
            let refined = localSearch(repaired, byPos: byPos, budget: budget, weights: weights)
            let s = score(refined, weights)
            if s > bestScore + 1e-9 {
                bestScore = s
                best = refined
            }
        }
        if let inc = incumbentResult {
            if best == nil || score(inc, weights) + incumbentMargin >= bestScore { return inc }
        }
        return best
    }

    // MARK: - stage 1: exact DP over cost

    /// A position's cost-indexed value curve for one (count, starters) pair,
    /// with the bitset needed to recover which players were chosen.
    private struct PosCurve {
        var lo: Int                 // cost of the cheapest legal selection
        var value: [Double]         // value[c - lo], -inf where unreachable
        var bits: [UInt64]          // take[j][k][c] — see `knapsack`
        var players: [Pick]
        var K: Int
        var W: Int
        var capLo: Int              // cost index origin of the bitset (always 0)
    }

    /// 0/1 knapsack over cost. Players arrive sorted by projection descending,
    /// so the k-th player taken is the k-th best in that position: whether a
    /// selection's k-th man starts or sits is therefore known from k alone, and
    /// the starter/bench weighting folds into the transition.
    private static func knapsack(_ players: [Pick], K: Int, starters: Int,
                                 capWeight: Double, weights: Weights,
                                 costCap: Int) -> PosCurve? {
        let n = players.count
        guard n >= K, costCap >= 0 else { return nil }
        let W = costCap + 1
        var dp = [Double](repeating: -.infinity, count: (K + 1) * W)
        dp[0] = 0
        var bits = [UInt64](repeating: 0, count: (n * (K + 1) * W + 63) / 64 + 1)

        dp.withUnsafeMutableBufferPointer { dpb in
            bits.withUnsafeMutableBufferPointer { bb in
                for j in 0..<n {
                    let p = players[j]
                    let c0 = Int(p.cost)
                    guard c0 <= costCap else { continue }
                    let jBase = j * (K + 1)
                    var k = min(K, j + 1)
                    while k >= 1 {
                        // rank k-1 (0-based) starts iff it is inside the
                        // formation's allowance for this position
                        var w = (k - 1) < starters ? 1.0 : weights.bench
                        if k == 1 { w += capWeight }        // this position holds the captain
                        let gain = p.proj * w
                        let rowNew = k * W, rowOld = (k - 1) * W
                        let bitRow = (jBase + k) * W
                        var c = costCap
                        while c >= c0 {
                            let prev = dpb[rowOld + c - c0]
                            if prev > -.infinity {
                                let cand = prev + gain
                                if cand > dpb[rowNew + c] + 1e-12 {
                                    dpb[rowNew + c] = cand
                                    let bit = bitRow + c
                                    bb[bit >> 6] |= (1 << UInt64(bit & 63))
                                }
                            }
                            c -= 1
                        }
                        k -= 1
                    }
                }
            }
        }

        let row = K * W
        var lo = -1
        for c in 0...costCap where dp[row + c] > -.infinity { lo = c; break }
        guard lo >= 0 else { return nil }
        let value = Array(dp[(row + lo)...(row + costCap)])
        return PosCurve(lo: lo, value: value, bits: bits, players: players,
                        K: K, W: W, capLo: 0)
    }

    /// Which players a curve's optimum at total cost `c` is made of.
    private static func recover(_ curve: PosCurve, cost c0: Int) -> [Pick] {
        var out: [Pick] = []
        out.reserveCapacity(curve.K)
        var k = curve.K
        var c = c0
        var j = curve.players.count - 1
        curve.bits.withUnsafeBufferPointer { bb in
            while j >= 0 && k >= 1 {
                let bit = ((j * (curve.K + 1) + k) * curve.W) + c
                if (bb[bit >> 6] >> UInt64(bit & 63)) & 1 == 1 {
                    let p = curve.players[j]
                    out.append(p)
                    c -= Int(p.cost)
                    k -= 1
                }
                j -= 1
            }
        }
        return out.count == curve.K ? out : []
    }

    /// Max-plus convolution of two cost curves, tracking the split so the
    /// per-position costs can be recovered.
    private struct Merged {
        var lo: Int
        var value: [Double]
        var argA: [Int32]        // cost spent on the left-hand curve
    }

    private static func merge(_ a: Merged, _ b: PosCurve, cap: Int) -> Merged? {
        let lo = a.lo + b.lo
        guard lo <= cap else { return nil }
        let W = cap - lo + 1
        var value = [Double](repeating: -.infinity, count: W)
        var argA = [Int32](repeating: -1, count: W)
        value.withUnsafeMutableBufferPointer { vb in
            argA.withUnsafeMutableBufferPointer { ab in
                for (i, av) in a.value.enumerated() where av > -.infinity {
                    let ac = a.lo + i
                    if ac > cap { break }
                    for (jj, bv) in b.value.enumerated() where bv > -.infinity {
                        let total = ac + b.lo + jj
                        if total > cap { break }
                        let idx = total - lo
                        let s = av + bv
                        if s > vb[idx] + 1e-12 { vb[idx] = s; ab[idx] = Int32(ac) }
                    }
                }
            }
        }
        return Merged(lo: lo, value: value, argA: argA)
    }

    private static func relaxedOptimum(byPos: [[Pick]], budget: Int, weights: Weights,
                                       exactCaptain: Bool) -> [Pick]? {
        // Cost bounds: a position can never spend more than the budget less the
        // cheapest legal fill of the other three. Tightening this is what keeps
        // the DP in the low milliseconds.
        var minSpend = [Int](repeating: 0, count: 5)
        for pos in 1...4 {
            let cheapest = byPos[pos].map { Int($0.cost) }.sorted().prefix(quota[pos])
            minSpend[pos] = cheapest.reduce(0, +)
        }
        let totalMin = minSpend[1] + minSpend[2] + minSpend[3] + minSpend[4]
        guard totalMin <= budget else { return nil }
        var costCap = [Int](repeating: 0, count: 5)
        for pos in 1...4 { costCap[pos] = budget - (totalMin - minSpend[pos]) }

        // Curves are cached per (position, starters, captain-here) — the same
        // curve is reused by every formation that starts that many.
        var cache: [Int: PosCurve] = [:]
        func curve(_ pos: Int, starters: Int, captain: Bool) -> PosCurve? {
            let key = pos * 100 + starters * 2 + (captain ? 1 : 0)
            if let c = cache[key] { return c }
            guard let c = knapsack(byPos[pos], K: quota[pos], starters: starters,
                                   capWeight: captain ? weights.captain : 0,
                                   weights: weights, costCap: costCap[pos]) else { return nil }
            cache[key] = c
            return c
        }

        var best: (value: Double, picks: [Pick])?
        let capPositions = exactCaptain ? [1, 2, 3, 4] : [0]

        for (d, m, f) in formations {
            let starters = [0, 1, d, m, f]
            for capPos in capPositions {
                guard let cGK = curve(1, starters: 1, captain: capPos == 1),
                      let cDEF = curve(2, starters: d, captain: capPos == 2),
                      let cMID = curve(3, starters: m, captain: capPos == 3),
                      let cFWD = curve(4, starters: f, captain: capPos == 4)
                else { continue }

                var chain = Merged(lo: cGK.lo, value: cGK.value,
                                   argA: [Int32](repeating: 0, count: cGK.value.count))
                guard let m1 = merge(chain, cDEF, cap: budget) else { continue }
                let gkSplit = chain
                guard let m2 = merge(m1, cMID, cap: budget) else { continue }
                guard let m3 = merge(m2, cFWD, cap: budget) else { continue }
                _ = gkSplit
                chain = m3

                var topV = -Double.infinity
                var topC = -1
                for (i, v) in chain.value.enumerated() where v > topV + 1e-12 {
                    topV = v; topC = chain.lo + i
                }
                guard topC >= 0, best == nil || topV > best!.value + 1e-12 else { continue }

                // unwind: total → (gk+def+mid, fwd) → (gk+def, mid) → (gk, def)
                func split(_ m: Merged, _ total: Int) -> Int? {
                    let i = total - m.lo
                    guard i >= 0, i < m.argA.count, m.argA[i] >= 0 else { return nil }
                    return Int(m.argA[i])
                }
                guard let cGDM = split(m3, topC),
                      let cGD = split(m2, cGDM),
                      let cGKspend = split(m1, cGD) else { continue }
                let cFWDspend = topC - cGDM
                let cMIDspend = cGDM - cGD
                let cDEFspend = cGD - cGKspend

                let picks = recover(cGK, cost: cGKspend) + recover(cDEF, cost: cDEFspend)
                    + recover(cMID, cost: cMIDspend) + recover(cFWD, cost: cFWDspend)
                guard picks.count == 15 else { continue }
                _ = starters
                best = (topV, picks)
            }
        }
        return best?.picks
    }

    // MARK: - stage 2: club-limit repair

    private static func repairClubs(_ squad: [Pick], byPos: [[Pick]], budget: Int,
                                    weights: Weights) -> [Pick]? {
        var sq = squad
        var guardrail = 0
        while guardrail < 30 {
            guardrail += 1
            var counts = [Int](repeating: 0, count: 32)
            for p in sq { counts[Int(p.team)] += 1 }
            guard let overClub = (0..<32).first(where: { counts[$0] > 3 }) else { break }

            // drop whichever member of the offending club costs the least points
            // to replace with a legal alternative
            var bestMove: (idx: Int, repl: Pick, loss: Double)?
            let ids = Set(sq.map(\.id))
            let spent = cost(sq)
            for (i, p) in sq.enumerated() where Int(p.team) == overClub {
                for cand in byPos[Int(p.pos)] {
                    guard !ids.contains(cand.id),
                          Int(cand.team) != overClub, counts[Int(cand.team)] < 3,
                          spent - Int(p.cost) + Int(cand.cost) <= budget else { continue }
                    var trial = sq
                    trial[i] = cand
                    let loss = score(sq, weights) - score(trial, weights)
                    if bestMove == nil || loss < bestMove!.loss { bestMove = (i, cand, loss) }
                    break   // pool is projection-sorted: the first legal one is the best
                }
            }
            guard let mv = bestMove else { return nil }
            sq[mv.idx] = mv.repl
        }
        return clubsLegal(sq) && cost(sq) <= budget ? sq : nil
    }

    // MARK: - stage 3: steepest-descent local search

    /// Cheapest way to free money from a slot: for each squad slot, the
    /// alternatives that cost less, ordered so the least damaging comes first.
    private static func fundingOptions(_ sq: [Pick], byPos: [[Pick]], ids: Set<Int32>)
        -> [[Pick]] {
        sq.map { p in
            byPos[Int(p.pos)]
                .filter { $0.cost < p.cost && !ids.contains($0.id) }
                .sorted { a, b in
                    // value lost per £0.1m freed — the efficient frontier of downgrades
                    let la = (p.proj - a.proj) / Double(max(Int(p.cost) - Int(a.cost), 1))
                    let lb = (p.proj - b.proj) / Double(max(Int(p.cost) - Int(b.cost), 1))
                    return la != lb ? la < lb : a.id < b.id
                }
                .prefix(8)
                .map { $0 }
        }
    }

    private static func localSearch(_ start: [Pick], byPos: [[Pick]], budget: Int,
                                    weights: Weights) -> [Pick] {
        var sq = start
        var cur = score(sq, weights)
        var spent = cost(sq)
        var rounds = 0

        while rounds < 60 {
            rounds += 1
            var ids = Set(sq.map(\.id))
            var counts = [Int](repeating: 0, count: 32)
            for p in sq { counts[Int(p.team)] += 1 }

            // --- single swaps: full neighbourhood, best improvement
            var bestGain = 1e-9
            var bestApply: (i: Int, p: Pick)?
            for i in 0..<15 {
                let old = sq[i]
                let room = budget - spent + Int(old.cost)
                for cand in byPos[Int(old.pos)] {
                    guard !ids.contains(cand.id), Int(cand.cost) <= room else { continue }
                    if cand.team != old.team && counts[Int(cand.team)] >= 3 { continue }
                    sq[i] = cand
                    let s = score(sq, weights)
                    sq[i] = old
                    if s - cur > bestGain { bestGain = s - cur; bestApply = (i, cand) }
                }
            }
            if let mv = bestApply {
                spent += Int(mv.p.cost) - Int(sq[mv.i].cost)
                sq[mv.i] = mv.p
                cur = score(sq, weights)
                continue
            }

            // --- funded double swaps: bring in someone we can't currently
            // afford, paying for them by downgrading a different slot. A pure
            // single-swap search stalls in front of every premium.
            let funds = fundingOptions(sq, byPos: byPos, ids: ids)
            var bestPair: (i: Int, pi: Pick, j: Int, pj: Pick)?
            var pairGain = 1e-9
            for i in 0..<15 {
                let old = sq[i]
                for cand in byPos[Int(old.pos)] {
                    guard !ids.contains(cand.id) else { continue }
                    if cand.team != old.team && counts[Int(cand.team)] >= 3 { continue }
                    let over = spent - Int(old.cost) + Int(cand.cost) - budget
                    guard over > 0 else { continue }      // affordable: already tried above
                    guard cand.proj > old.proj else { continue }
                    for j in 0..<15 where j != i {
                        let old2 = sq[j]
                        for down in funds[j] {
                            guard Int(old2.cost) - Int(down.cost) >= over, down.id != cand.id
                            else { continue }
                            if down.team != old2.team {
                                var c = counts[Int(down.team)]
                                if Int(cand.team) == Int(down.team) { c += 1 }
                                if Int(old.team) == Int(down.team) { c -= 1 }
                                if c >= 3 { continue }
                            }
                            sq[i] = cand; sq[j] = down
                            let s = score(sq, weights)
                            sq[i] = old; sq[j] = old2
                            if s - cur > pairGain { pairGain = s - cur; bestPair = (i, cand, j, down) }
                            break   // funding list is already the efficient frontier
                        }
                    }
                }
            }
            guard let mv = bestPair else { break }
            spent += Int(mv.pi.cost) - Int(sq[mv.i].cost) + Int(mv.pj.cost) - Int(sq[mv.j].cost)
            sq[mv.i] = mv.pi
            sq[mv.j] = mv.pj
            cur = score(sq, weights)
            ids = Set(sq.map(\.id))
        }
        return sq
    }

    // MARK: - pool reduction

    /// Drop players no selection could ever want. A player is dropped only when
    /// at least `quota` others in the same position cost no more *and* project
    /// at least as high — at that point one of those dominators is always spare,
    /// so swapping is free. Exact, and it takes ~550 players down to ~200, which
    /// is what makes the exact DP cheap enough to run on every rebuild.
    static func reduce(_ picks: [Pick]) -> [Pick] {
        var byPos: [[Pick]] = [[], [], [], [], []]
        for p in picks where p.pos >= 1 && p.pos <= 4 { byPos[Int(p.pos)].append(p) }
        var out: [Pick] = []
        out.reserveCapacity(picks.count)
        for pos in 1...4 {
            let need = quota[pos]
            let sorted = byPos[pos].sorted {
                $0.cost != $1.cost ? $0.cost < $1.cost
                    : ($0.proj != $1.proj ? $0.proj > $1.proj : $0.id < $1.id)
            }
            var topProj: [Double] = []      // the `need` best projections seen so far,
            topProj.reserveCapacity(need + 1)   // held sorted descending
            for p in sorted {
                if topProj.count < need || topProj[need - 1] < p.proj { out.append(p) }
                let at = topProj.firstIndex { $0 < p.proj } ?? topProj.count
                if at < need {
                    topProj.insert(p.proj, at: at)
                    if topProj.count > need { topProj.removeLast() }
                }
            }
        }
        return out
    }
}

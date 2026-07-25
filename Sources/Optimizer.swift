import Foundation

// MARK: - Squad optimizer
// Greedy seed + simulated annealing with single- and double-swap moves so the
// search can fund a premium upgrade by downgrading elsewhere in one move.
//
// The annealer evaluates ~50k candidate squads per rebuild. Every evaluation
// used to sort four arrays, build four prefix-sum arrays, allocate a bench
// array and a club-count dictionary — roughly ten heap allocations per
// iteration. `evaluate` and `feasible` below do the same work entirely in
// stack scratch space, and operate on `Pick` (16 bytes, no references) rather
// than `Player` (four strings + two buffers, six retain/release pairs a copy).

enum Optimizer {
    static let quota = [0, 2, 5, 5, 3]

    /// Slot layout inside the scratch buffer: GK 0..<2, DEF 2..<7, MID 7..<12,
    /// FWD 12..<15 — each block held sorted descending by projection.
    private static let slotBase = [0, 0, 2, 7, 12]

    struct XI {
        let total: Double        // best starting XI
        let benchSum: Double     // the other four
        let capProj: Double      // best single projection in the XI
        let d: Int, m: Int, f: Int
        var formation: String { "\(d)-\(m)-\(f)" }
    }

    /// Best legal XI from a 15-man squad. Allocation-free.
    static func evaluate(_ squad: [Pick]) -> XI? {
        guard squad.count == 15 else { return nil }
        return withUnsafeTemporaryAllocation(of: Double.self, capacity: 15) { buf -> XI? in
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
                    i -= 1
                }
                buf[i] = p.proj
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
            let cap = max(max(buf[0], buf[2]), max(buf[7], buf[12]))
            return XI(total: total, benchSum: all - total, capProj: cap,
                      d: bd, m: bm, f: bf)
        }
    }

    @inline(__always)
    static func objective(_ squad: [Pick]) -> Double {
        guard let r = evaluate(squad) else { return -1e9 }
        return r.total + r.capProj + 0.12 * r.benchSum
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

    static func candidatePool(_ players: [Player], fitOnly: Bool) -> [Player] {
        var pool: [Player] = []
        pool.reserveCapacity(240)
        for pos in 1...4 {
            let byPos = players.filter { $0.pos == pos && (fitOnly ? !$0.flagged : $0.avail > 0.5) }
            let top = byPos.prefix(48)
            let cheap = byPos
                .sorted { $0.cost != $1.cost ? $0.cost < $1.cost : $0.proj > $1.proj }
                .prefix(10)
            var seen = Set<Int>()
            for p in Array(top) + Array(cheap) where seen.insert(p.id).inserted { pool.append(p) }
        }
        return pool
    }

    // MARK: - greedy seed

    /// Cheapest-completion bound used to prune the greedy seed. Precomputed
    /// cost-sorted lists replace the filter+sort that previously ran inside
    /// the seed's innermost loop.
    private struct SeedContext {
        let byPos: [[Pick]]          // sorted by projection, descending
        let cheap: [[Pick]]          // sorted by cost, ascending

        init(_ pool: [Pick]) {
            var p: [[Pick]] = [[], [], [], [], []]
            for x in pool where x.pos >= 1 && x.pos <= 4 { p[Int(x.pos)].append(x) }
            for i in 1...4 {
                p[i].sort { $0.proj != $1.proj ? $0.proj > $1.proj : $0.id < $1.id }
            }
            byPos = p
            cheap = p.map { $0.sorted { $0.cost != $1.cost ? $0.cost < $1.cost : $0.proj > $1.proj } }
        }

        func cheapestRest(needs: [Int], taken: Set<Int32>, excluding: Int32) -> Int {
            var sum = 0
            for pos in 1...4 where needs[pos] > 0 {
                var need = needs[pos]
                for p in cheap[pos] {
                    if p.id == excluding || taken.contains(p.id) { continue }
                    sum += Int(p.cost)
                    need -= 1
                    if need == 0 { break }
                }
                sum += need * 999
            }
            return sum
        }
    }

    private static func greedySeed(_ ctx: SeedContext, budget: Int, jitter: Bool,
                                   rng: inout SeededRandom) -> [Pick] {
        var byPos = ctx.byPos
        if jitter {
            for i in 1...4 {
                byPos[i] = byPos[i].filter { _ in Double.random(in: 0...1, using: &rng) > 0.25 }
                if byPos[i].isEmpty { byPos[i] = ctx.byPos[i] }
            }
        }
        var squad: [Pick] = []
        squad.reserveCapacity(15)
        var taken = Set<Int32>()
        var clubs = [Int](repeating: 0, count: 32)
        var needs = quota
        var spent = 0

        for pos in 1...4 {
            for _ in 0..<quota[pos] {
                for p in byPos[pos] {
                    guard !taken.contains(p.id), clubs[Int(p.team)] < 3 else { continue }
                    needs[pos] -= 1
                    let restMin = ctx.cheapestRest(needs: needs, taken: taken, excluding: p.id)
                    if spent + Int(p.cost) + restMin <= budget {
                        squad.append(p)
                        taken.insert(p.id)
                        clubs[Int(p.team)] += 1
                        spent += Int(p.cost)
                        break
                    }
                    needs[pos] += 1
                }
            }
        }
        // pad if incomplete
        for pos in 1...4 {
            while squad.reduce(0, { $1.pos == pos ? $0 + 1 : $0 }) < quota[pos] {
                guard let cand = ctx.cheap[pos].first(where: {
                    !taken.contains($0.id) && clubs[Int($0.team)] < 3
                }) else { break }
                squad.append(cand)
                taken.insert(cand.id)
                clubs[Int(cand.team)] += 1
            }
        }
        return squad
    }

    // MARK: - annealer

    /// Optimize over `Pick`s. Returns the chosen 15 ids.
    static func optimizeIds(pool: [Pick], budget: Int,
                            iters: Int = 12000, restarts: Int = 4,
                            seed: UInt64 = 0xC0FFEE) -> [Int32]? {
        let ctx = SeedContext(pool)
        guard (1...4).allSatisfy({ ctx.byPos[$0].count >= quota[$0] }) else { return nil }

        // seeded RNG: same data in → same squad out, so the plan the user sees
        // doesn't reshuffle on every rebuild
        var rng = SeededRandom(seed: seed)
        var bestSquad: [Pick]?
        var bestScore = -Double.infinity

        for restart in 0..<restarts {
            var squad = greedySeed(ctx, budget: budget, jitter: restart > 0, rng: &rng)
            guard squad.count == 15, feasible(squad, budget: budget) else { continue }
            var score = objective(squad)
            var localBest = squad
            var localBestScore = score

            var ids = Set(squad.map(\.id))
            for it in 0..<iters {
                let T = 1.4 * (1 - Double(it) / Double(iters)) + 0.02
                let swaps = Double.random(in: 0...1, using: &rng) < 0.35 ? 2 : 1

                // mutate in place and revert on reject — copying the array per
                // iteration was one heap allocation per candidate evaluated
                var i0 = Int.random(in: 0..<15, using: &rng)
                var i1 = -1
                let old0 = squad[i0]
                var old1 = old0
                var ok = true

                guard let n0 = ctx.byPos[Int(old0.pos)].randomElement(using: &rng),
                      !ids.contains(n0.id) else { continue }
                squad[i0] = n0

                if swaps == 2 {
                    var j = Int.random(in: 0..<15, using: &rng)
                    if j == i0 { j = (j + 1) % 15 }
                    i1 = j
                    old1 = squad[i1]
                    if let n1 = ctx.byPos[Int(old1.pos)].randomElement(using: &rng),
                       !ids.contains(n1.id), n1.id != n0.id {
                        squad[i1] = n1
                    } else {
                        ok = false
                    }
                }

                var accepted = false
                if ok, feasible(squad, budget: budget) {
                    let ns = objective(squad)
                    let d = ns - score
                    if d > 0 || Double.random(in: 0...1, using: &rng) < exp(d / T) {
                        ids.remove(old0.id); ids.insert(squad[i0].id)
                        if i1 >= 0 { ids.remove(old1.id); ids.insert(squad[i1].id) }
                        score = ns
                        accepted = true
                        if ns > localBestScore { localBest = squad; localBestScore = ns }
                    }
                }
                if !accepted {
                    squad[i0] = old0
                    if i1 >= 0 { squad[i1] = old1 }
                }
            }
            if localBestScore > bestScore { bestScore = localBestScore; bestSquad = localBest }
        }
        return bestSquad.map { $0.map(\.id) }
    }

    /// Player-facing entry point: pool → annealed 15 → display-ready result.
    static func optimize(players: [Player], budgetM: Double, fitOnly: Bool,
                         iters: Int = 12000, restarts: Int = 4,
                         seed: UInt64 = 0xC0FFEE) -> SquadResult? {
        let budget = Int((budgetM * 10).rounded())
        let pool = candidatePool(players, fitOnly: fitOnly)
        let picks = pool.map { $0.pick($0.proj) }
        guard let ids = optimizeIds(pool: picks, budget: budget,
                                    iters: iters, restarts: restarts, seed: seed) else { return nil }
        var byId = [Int32: Player](minimumCapacity: pool.count)
        for p in pool { byId[Int32(p.id)] = p }
        let squad = ids.compactMap { byId[$0] }
        guard squad.count == 15, let r = bestXI(squad) else { return nil }
        let sorted = r.xi.sorted { $0.proj != $1.proj ? $0.proj > $1.proj : $0.id < $1.id }
        return SquadResult(
            squad: squad, xi: r.xi, bench: r.bench, formation: r.formation,
            total: r.total, captain: sorted[0], vice: sorted[1],
            cost: squad.reduce(0) { $0 + $1.cost }
        )
    }
}

import Foundation

// MARK: - Comparing transfer policies
//
// Runs the same drawn seasons through different decision rules and reports what
// each one scored. Every policy sees the same injuries, the same appearances
// and the same returns; only the rule for spending transfers changes.

enum PolicyBench {
    /// What a manager believes about a squad at a deadline: an injured player
    /// is worth nothing this week and is discounted for a fortnight after,
    /// because nobody knows on Friday how long a hamstring takes.
    static func believedPlayers(_ all: [Player], unavailable: (Int) -> Bool,
                                gw: Int, end: Int) -> [Player] {
        all.map { p in
            guard unavailable(p.id) else { return p }
            var copy = p
            var values: [Double] = []
            for g in gw...end {
                let raw = p.projByGw.at(g)
                let discount: Double = g == gw ? 0 : (g <= gw + 2 ? 0.45 : 0.9)
                values.append(raw * discount)
            }
            copy.projByGw = GWProjection(first: gw, values: values)
            copy.flagged = true
            copy.avail = 0
            return copy
        }
    }

    /// A transfer rule, expressed the way the planner expresses it.
    struct Rule {
        let name: String
        let usePairs: Bool
        let maxMoves: Int
        var enabled = true          // false = never transfer, the floor
        /// Extra gain a pair must show over the best single before it is taken.
        var pairBar = 2 * Planner.minimumWorthwhileGain
        /// Decision constants under test.
        var lookahead = Planner.transferLookahead
        var hitBar = Planner.hitGainThreshold
        var bankBar = 1.0           // multiplier on the value of holding a transfer
        var poolSize = 240
        var decay = Planner.decay
    }

    /// How often each rule actually fired, so a null result can be told apart
    /// from a rule that never ran.
    final class Counter { var pairs = 0; var singles = 0; var seasons = 0 }

    static func policy(_ rule: Rule, universe: [Player], poolSize: Int, end: Int,
                       counter: Counter) -> SeasonSim.Policy {
        return { board in
            guard rule.enabled else { return [] }
            let squadIds = Set(board.squad)
            let believed = believedPlayers(universe, unavailable: { !board.available($0) },
                                           gw: board.gw, end: end)
            // A trimmed universe: everything worth buying, plus what is owned.
            let ranked = believed
                .filter { !$0.flagged }
                .sorted { $0.projByGw.at(board.gw) > $1.projByGw.at(board.gw) }
            var universeIds = Set(ranked.prefix(poolSize).map(\.id))
            universeIds.formUnion(squadIds)
            let subset = believed.filter { universeIds.contains($0.id) }
            let pool = subset.filter { !squadIds.contains($0.id) && !$0.flagged }
            let ctx = PlanContext(players: subset, pool: pool, from: board.gw, end: end,
                                  decay: rule.decay)
            guard let compact = try? board.squad.map({ id -> Int in
                guard let i = ctx.index[id] else { throw Err.missing }
                return i
            }) else { return [] }

            var moves: [SeasonSim.Move] = []
            var squad = compact
            var bank = board.bank
            var fts = board.freeTransfers

            if rule.usePairs, fts >= 1,
               let pair = Planner.bestPair(ctx: ctx, squad: squad, bank: bank, from: board.gw),
               let single = Planner.bestTransfer(ctx: ctx, squad: squad, bank: bank, from: board.gw) {
                let pairHit = Double(max(2 - fts, 0)) * 4
                let singleHit = fts > 0 ? 0.0 : 4.0
                if pair.gain - pairHit > single.gain - singleHit,
                   pair.gain - pairHit >= rule.pairBar {
                    counter.pairs += 1
                    for (out, inn) in [(pair.outA, pair.innA), (pair.outB, pair.innB)] {
                        guard let slot = squad.firstIndex(of: out) else { continue }
                        squad[slot] = inn
                        bank += Int(ctx.picks[out].cost) - Int(ctx.picks[inn].cost)
                        fts -= 1
                        moves.append(SeasonSim.Move(out: ctx.players[out].id,
                                                    inn: ctx.players[inn].id))
                    }
                    return moves
                }
            }

            while moves.count < rule.maxMoves {
                guard let best = Planner.bestTransfer(ctx: ctx, squad: squad, bank: bank,
                                                      from: board.gw,
                                                      lookahead: rule.lookahead) else { break }
                let outPlayer = ctx.players[best.out]
                let isFree = fts > 0
                let injured = outPlayer.flagged || outPlayer.avail < 0.75
                let bar = max(isFree ? rule.bankBar * Planner.optionValue(ftsBanked: fts, outInjured: injured)
                                     : (injured ? 4.5 : rule.hitBar),
                              Planner.minimumWorthwhileGain)
                guard best.gain >= bar, let slot = squad.firstIndex(of: best.out) else { break }
                squad[slot] = best.inn
                bank += Int(ctx.picks[best.out].cost) - Int(ctx.picks[best.inn].cost)
                if isFree { fts -= 1 }
                counter.singles += 1
                moves.append(SeasonSim.Move(out: ctx.players[best.out].id,
                                            inn: ctx.players[best.inn].id))
            }
            return moves
        }
    }

    enum Err: Error { case missing }

    /// Several starting squads under one rule, on shared draws, so the
    /// difference between two ways of *picking* a squad can be read with a
    /// confidence interval rather than eyeballed.
    static func compareSquads(players: [Player], squads: [(String, [Int])], budget: Int,
                              from: Int, end: Int, seasons: Int, rule: Rule) {
        let sim = SeasonSim(players: players, from: from, end: end)
        print("\n=== \(seasons) simulated seasons, GW\(from)–\(end), shared draws ===")
        var results: [(String, [Double])] = []
        for (name, start) in squads {
            let p = policy(rule, universe: players, poolSize: 240, end: end, counter: Counter())
            var scores: [Double] = []
            for s in 0..<seasons {
                scores.append(sim.run(seed: UInt64(bitPattern: Int64(s &* 6364136223846793005 &+ 1)),
                                      start: start, budget: budget, policy: p))
            }
            results.append((name, scores))
        }
        guard let baseline = results.first else { return }
        let baseMean = baseline.1.reduce(0,+) / Double(baseline.1.count)
        print(String(format: "  %-34@ %7.1f pts", baseline.0 as NSString, baseMean))
        for (name, scores) in results.dropFirst() {
            let mean = scores.reduce(0,+) / Double(scores.count)
            let diffs = zip(scores, baseline.1).map(-)
            let dm = diffs.reduce(0,+) / Double(diffs.count)
            let sd = (diffs.reduce(0) { $0 + ($1 - dm) * ($1 - dm) } / Double(max(diffs.count - 1, 1))).squareRoot()
            let se = sd / Double(diffs.count).squareRoot()
            print(String(format: "  %-34@ %7.1f pts   %+6.1f  ± %.1f  (%@)",
                         name as NSString, mean, dm, 1.96 * se,
                         (abs(dm) > 1.96 * se ? "clear" : "inside noise") as NSString))
        }
    }

    static func compare(players: [Player], start: [Int], budget: Int,
                        from: Int, end: Int, seasons: Int, rules: [Rule]) {
        let sim = SeasonSim(players: players, from: from, end: end)
        print("\n=== \(seasons) simulated seasons, GW\(from)–\(end), identical draws per policy ===")
        var results: [String: [Double]] = [:]
        var counters: [String: Counter] = [:]
        for rule in rules {
            let counter = Counter()
            counters[rule.name] = counter
            let p = policy(rule, universe: players, poolSize: rule.poolSize, end: end, counter: counter)
            var scores: [Double] = []
            for s in 0..<seasons {
                scores.append(sim.run(seed: UInt64(bitPattern: Int64(s &* 6364136223846793005 &+ 1)), start: start,
                                      budget: budget, policy: p))
            }
            results[rule.name] = scores
        }
        let names = rules.map(\.name)
        guard let baseline = results[names[0]] else { return }
        let baseMean = baseline.reduce(0,+) / Double(baseline.count)
        func fired(_ name: String) -> String {
            guard let c = counters[name] else { return "" }
            return String(format: "  [%.1f singles, %.1f pairs per season]",
                          Double(c.singles) / Double(seasons), Double(c.pairs) / Double(seasons))
        }
        print(String(format: "  %-28@ %7.1f pts%@", names[0] as NSString, baseMean,
                     fired(names[0]) as NSString))
        for name in names.dropFirst() {
            guard let scores = results[name] else { continue }
            let mean = scores.reduce(0,+) / Double(scores.count)
            // paired differences: the draws are shared, so the standard error
            // of the difference is what matters, not of either total
            let diffs = zip(scores, baseline).map(-)
            let dm = diffs.reduce(0,+) / Double(diffs.count)
            let sd = (diffs.reduce(0) { $0 + ($1 - dm) * ($1 - dm) } / Double(max(diffs.count - 1, 1))).squareRoot()
            let se = sd / Double(diffs.count).squareRoot()
            print(String(format: "  %-28@ %7.1f pts   %+6.1f  ± %.1f  (%@)%@",
                         name as NSString, mean, dm, 1.96 * se,
                         (abs(dm) > 1.96 * se ? "clear" : "inside noise") as NSString,
                         fired(name) as NSString))
        }
    }
}

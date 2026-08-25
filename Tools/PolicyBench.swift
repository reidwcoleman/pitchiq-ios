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
        /// Chip policy. `chips: false` plays none of them — the floor a chip
        /// strategy has to beat. The bars are the extra points a chip has to
        /// promise this week, over what the same week would score without it,
        /// before it is spent. Zero means "play it at the first opportunity".
        var chips = true
        var bbBar = Planner.chipThreshold("bboost")
        var tcBar = Planner.chipThreshold("3xc")
        var wcBar = Planner.chipThreshold("wildcard")
        var fhBar = Planner.chipThreshold("freehit")
        /// Gameweeks left in the half at which the bar falls away, because a
        /// chip that expires unplayed is worth nothing at all.
        var chipPanic = 3
    }

    /// How often each rule actually fired, so a null result can be told apart
    /// from a rule that never ran.
    final class Counter {
        var pairs = 0, singles = 0, seasons = 0
        var chips: [String: Int] = [:]
        var chipGain = 0.0
    }

    static func policy(_ rule: Rule, universe: [Player], poolSize: Int, end: Int,
                       counter: Counter) -> SeasonSim.Policy {
        return { board in
            guard rule.enabled else { return SeasonSim.Decision() }
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
            }) else { return SeasonSim.Decision() }

            var moves: [SeasonSim.Move] = []
            var squad = compact
            var bank = board.bank
            var fts = board.freeTransfers

            // ---- chips
            //
            // Each is judged the same way: what does playing it here add over
            // playing this week normally? The bar it has to clear falls to
            // nothing as the half runs out, because an unplayed chip scores
            // zero and a mediocre one scores something.
            if rule.chips, !board.chipsLeft.isEmpty {
                let closing = board.weeksLeftInHalf <= rule.chipPanic
                let gwPicks = squad.map { ctx.pick($0, board.gw) }
                if let shape = Optimizer.evaluate(gwPicks) {
                    // Bench Boost: the four substitutes score, and the
                    // auto-substitution allowance is already inside the normal
                    // week, so the gain is what the bench adds beyond it.
                    let bbGain = shape.benchSum - shape.autosub
                    // Triple Captain: one more copy of the captain.
                    let tcGain = shape.capProj

                    var choice: (String, Double)?
                    func offer(_ name: String, _ gain: Double, _ bar: Double) {
                        guard board.chipsLeft.contains(name),
                              gain >= (closing ? 0 : bar) else { return }
                        if choice == nil || gain > choice!.1 { choice = (name, gain) }
                    }
                    offer("bboost", bbGain, rule.bbBar)
                    offer("3xc", tcGain, rule.tcBar)

                    // Wildcard and Free Hit rebuild the squad. Worth asking
                    // only if the rebuild is a big one; the optimiser is the
                    // expensive call here, so it is guarded.
                    if board.chipsLeft.contains("wildcard") || board.chipsLeft.contains("freehit") {
                        let poolPlayers = subset.filter { !$0.flagged }
                        var squadValue = 0
                        for id in board.squad {
                            squadValue += believed.first { $0.id == id }?.cost ?? 0
                        }
                        let budgetM = Double(board.bank + squadValue) / 10
                        let freshSquad = Optimizer.optimize(players: poolPlayers,
                                                            budgetM: budgetM, fitOnly: true)
                        if let fresh = freshSquad, fresh.squad.count == 15,
                           let freshShape = Optimizer.evaluate(
                               fresh.squad.map { $0.pick($0.projByGw.at(board.gw)) }) {
                            let now = shape.total + shape.capProj + shape.autosub
                            let after = freshShape.total + freshShape.capProj + freshShape.autosub
                            // A free hit is one week; a wildcard is the rest of
                            // the season, so its gain is counted over the window
                            // a transfer is judged over.
                            let fhGain = after - now
                            let wcGain = fhGain * Double(min(rule.lookahead, board.weeksLeftInHalf))
                                / 2      // half of it, since transfers would close some of the gap anyway
                            offer("freehit", fhGain, rule.fhBar)
                            offer("wildcard", wcGain, rule.wcBar)
                            if let picked = choice, picked.0 == "wildcard" || picked.0 == "freehit" {
                                counter.chips[picked.0, default: 0] += 1
                                counter.chipGain += picked.1
                                return SeasonSim.Decision(moves: [], chip: picked.0,
                                                          squad: fresh.squad.map(\.id))
                            }
                        }
                    }
                    if let picked = choice {
                        counter.chips[picked.0, default: 0] += 1
                        counter.chipGain += picked.1
                        return SeasonSim.Decision(moves: [], chip: picked.0)
                    }
                }
            }

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
                    return SeasonSim.Decision(moves: moves)
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
            return SeasonSim.Decision(moves: moves)
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
            let chips = SeasonSim.chipNames
                .compactMap { n -> String? in
                    let used = c.chips[n] ?? 0
                    guard used > 0 else { return nil }
                    return String(format: "%@ %.1f", n, Double(used) / Double(seasons))
                }
                .joined(separator: ", ")
            return String(format: "  [%.0f transfers%@]", Double(c.singles) / Double(seasons),
                          chips.isEmpty ? "" : ", chips: " + chips)
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

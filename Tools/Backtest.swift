import Foundation

// MARK: - Playing a finished season
//
// How many points would this model actually have scored?
//
// The honest answer is bounded by what FPL publishes. Per-gameweek player data
// exists only for the season in progress; for finished seasons the API gives
// season totals and nothing else. So a week-by-week replay — transfers,
// captain changes, chips, automatic substitutions — is not possible, and any
// number claiming to be one would be invented.
//
// What *is* possible is a real, no-hindsight backtest of the one decision the
// data supports: pick a squad before the season with the model, pick the
// eleven and the captain on its projections, and count what those players
// really scored. No transfers, no chips, one captain all year. That is a
// deliberately hobbled version of the game, and the comparison to real
// managers has to say so.

struct Backtest {
    let eval: Eval

    struct Result {
        let season: String
        let squad: [Eval.Case]
        let xi: [Eval.Case]
        let captain: Eval.Case
        let points: Double           // XI + captain, actual
        let hindsightXI: Double      // same fifteen, eleven chosen with hindsight
        let autosubEstimate: Double
        let bestPossible: Double     // the best fifteen anyone could have bought
        let spend: Int
    }

    /// Build the squad with the shipped solver, so the backtest tests the code
    /// the app runs rather than a stand-in for it.
    func play(season: String, tuning: Tuning, budgetM: Double = 100,
              rank: ((Eval.Case) -> Double)? = nil) -> Result? {
        let cases = eval.cases(target: season, tuning: tuning)
        guard cases.count > 100 else { return nil }
        var byId: [Int: Eval.Case] = [:]
        for c in cases { byId[c.id] = c }

        let teamOf = Dictionary(uniqueKeysWithValues: eval.boot.elements.map { ($0.id, $0.team) })
        let players: [Player] = cases.map { c in
            var p = Player()
            p.id = c.id
            p.name = c.name
            p.pos = c.pos
            // Clubs are not published for past seasons, so the max-three rule
            // is applied with each player's *current* club. It is the wrong
            // constraint, but it is a real one — dropping it would hand the
            // backtest a squad no manager could have owned.
            p.team = teamOf[c.id] ?? 0
            p.cost = c.cost
            let value = rank?(c) ?? c.predicted
            p.proj = value
            p.perGw = value / 38
            p.projByGw = GWProjection(first: 1, values: [Double](repeating: value / 38, count: 38))
            p.playProb = max(min(c.predictedMinutes / 3420, 1), 0.05)
            p.expMins = c.predictedMinutes / 38
            return p
        }
        guard let squad = Optimizer.optimize(players: players, budgetM: budgetM, fitOnly: false)
        else { return nil }

        let picked = squad.squad.compactMap { byId[$0.id] }
        let xi = squad.xi.compactMap { byId[$0.id] }
        guard picked.count == 15, xi.count == 11, let captain = byId[squad.captain.id]
        else { return nil }

        let points = xi.reduce(0) { $0 + $1.actual } + captain.actual
        let hindsight = Eval.bestEleven(picked).reduce(0) { $0 + $1.actual }
            + (picked.max { $0.actual < $1.actual }?.actual ?? 0)

        // A rough allowance for the substitutions the game would have made.
        // Season totals cannot say which weeks a player missed, only how many:
        // an ever-present starts 38 and a player on 1,700 minutes missed
        // something like half of them. The bench covers those weeks at its own
        // rate, which is the only part of a fifteen the headline number ignores.
        let bench = picked.filter { c in !xi.contains { $0.id == c.id } }
            .filter { $0.pos != 1 }
            .sorted { $0.predicted > $1.predicted }
        let missed = xi.reduce(0.0) { total, c in
            total + max(38 - c.actualMinutes / 78, 0)          // ~78 min per appearance
        }
        var autosub = 0.0
        var covered = missed
        for (i, sub) in bench.prefix(3).enumerated() {
            // each seat covers a shrinking share of the missing weeks
            let share = [0.55, 0.28, 0.12][i]
            let weeks = min(covered * share, sub.actualMinutes / 78)
            autosub += weeks * (sub.actualMinutes > 0
                                ? sub.actual / (sub.actualMinutes / 78) : 0)
            covered -= weeks
        }

        let best = Eval.squadPoints(cases, by: { $0.actual }).points
        return Result(season: season, squad: picked, xi: xi, captain: captain,
                      points: points, hindsightXI: hindsight,
                      autosubEstimate: autosub, bestPossible: best,
                      spend: picked.reduce(0) { $0 + $1.cost })
    }

    /// Three seasons is not many, and a squad is a discrete choice: one player
    /// swapped at the margin moves the total by fifty points and says nothing
    /// about the model. Replaying each season across a spread of budgets gives
    /// several independent squads per season from the same projections, which
    /// is a far steadier read on whether a change helped.
    static let budgets: [Double] = [96, 98, 100, 102, 104]

    func meanPoints(tuning: Tuning) -> (points: Double, spread: Double) {
        var all: [Double] = []
        for season in Eval.seasons {
            for b in Self.budgets {
                if let r = play(season: season, tuning: tuning, budgetM: b) { all.append(r.points) }
            }
        }
        guard !all.isEmpty else { return (0, 0) }
        let mean = all.reduce(0, +) / Double(all.count)
        let sd = (all.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(max(all.count - 1, 1))).squareRoot()
        return (mean, sd / Double(all.count).squareRoot())
    }

    // MARK: - what that score would have been worth

    /// Real managers' (points, rank) pairs for each season, sampled from the
    /// public entry-history endpoint. Every pair is exact — the rank a manager
    /// finished with is published alongside their total — so a few hundred of
    /// them map the whole curve without needing an unbiased sample of managers.
    struct RankCurve {
        var bySeason: [String: [(points: Int, rank: Int)]] = [:]

        init(json: [String: [[Int]]]) {
            for (season, rows) in json {
                bySeason[season] = rows.compactMap { r in
                    r.count >= 2 && r[1] > 0 ? (points: r[0], rank: r[1]) : nil
                }.sorted { $0.points < $1.points }
            }
        }

        /// Interpolate a rank for a score, in log-rank space — ranks span seven
        /// orders of magnitude and straight interpolation would be meaningless
        /// at the top.
        func rank(of score: Double, season: String) -> (rank: Int, percentile: Double)? {
            guard let rows = bySeason[season], rows.count > 20 else { return nil }
            let n = Double(rows.count)
            let below = Double(rows.filter { Double($0.points) < score }.count)
            let percentile = below / n * 100
            var lo = rows.first!, hi = rows.last!
            for r in rows {
                if Double(r.points) <= score { lo = r }
                if Double(r.points) >= score { hi = r; break }
            }
            let rank: Int
            if lo.points == hi.points {
                rank = lo.rank
            } else {
                let t = (score - Double(lo.points)) / Double(hi.points - lo.points)
                let l = log(Double(max(lo.rank, 1))), h = log(Double(max(hi.rank, 1)))
                rank = Int(exp(l + (h - l) * t).rounded())
            }
            return (max(rank, 1), percentile)
        }

        func median(_ season: String) -> Int? {
            guard let rows = bySeason[season], !rows.isEmpty else { return nil }
            return rows[rows.count / 2].points
        }
        func sample(_ season: String) -> Int { bySeason[season]?.count ?? 0 }
    }

    func report(tuning: Tuning, curve: RankCurve) {
        print("""

        === playing each season with the model, start to finish ===
          One squad picked before the season from earlier seasons only. The
          eleven and the captain are chosen on projections, never on hindsight.
          No transfers, no chips, no captain changes — the API publishes no
          per-gameweek data for finished seasons, so those cannot be replayed.
        """)
        var totals: [Double] = []
        var baselineTotals: [String: [Double]] = [:]
        for season in Eval.seasons {
            guard let r = play(season: season, tuning: tuning) else { continue }
            totals.append(r.points)
            print("\n  \(season)   £\(String(format: "%.1f", Double(r.spend) / 10))m spent")
            print("    XI: " + r.xi.sorted { $0.actual > $1.actual }
                    .map { "\($0.name) \(Int($0.actual))" }.joined(separator: ", "))
            print("    captain all season: \(r.captain.name) (\(Int(r.captain.actual)) × 2)")
            let withSubs = r.points + r.autosubEstimate
            print(String(format: "    scored %.0f   (%.0f with an estimate of automatic substitutions)",
                         r.points, withSubs))
            if let placed = curve.rank(of: r.points, season: season) {
                print(String(format: "    that is rank ~%@ — better than %.0f%% of the %d real managers sampled",
                             format(placed.rank) as NSString, placed.percentile, curve.sample(season)))
            }
            if let placed = curve.rank(of: withSubs, season: season) {
                print(String(format: "    with substitutions, rank ~%@", format(placed.rank) as NSString))
            }
            // The same format, played by other rankings — the only fair
            // comparison, since a frozen squad is a different game to the one
            // real managers play.
            let others: [(String, (Eval.Case) -> Double)] = [
                ("last season's points", { $0.naive }),
                ("most expensive squad", { Double($0.cost) }),
                ("perfect hindsight", { $0.actual }),
            ]
            for (name, by) in others {
                guard let alt = play(season: season, tuning: tuning, rank: by) else { continue }
                baselineTotals[name, default: []].append(alt.points)
                var line = String(format: "    same rules, %@: %.0f", name as NSString, alt.points)
                if name == "perfect hindsight",
                   let placed = curve.rank(of: alt.points, season: season) {
                    line += " (rank ~\(format(placed.rank)) — the ceiling for a frozen squad)"
                }
                print(line)
            }
            // How much of a season a frozen squad simply loses. This is the
            // whole argument for transfers, in one number.
            let expected = r.squad.reduce(0) { $0 + $1.predictedMinutes }
            let got = r.squad.reduce(0) { $0 + $1.actualMinutes }
            print(String(format: "    the fifteen were expected to play %.0f%% of the available minutes and played %.0f%%",
                         expected / (15 * 3420) * 100, got / (15 * 3420) * 100))
            if let med = curve.median(season) {
                print("    median real manager that season: \(med) — but with 35 transfers, four chips and a new captain every week")
            }
        }
        if !totals.isEmpty {
            print("\n  --- mean across the three seasons, all playing by the same frozen-squad rules ---")
            print(String(format: "    the model            %.0f", totals.reduce(0,+) / Double(totals.count)))
            for (name, list) in baselineTotals.sorted(by: { $0.key < $1.key }) where !list.isEmpty {
                print(String(format: "    %-20@ %.0f", name as NSString,
                             list.reduce(0,+) / Double(list.count)))
            }
        }
    }

    private func format(_ n: Int) -> String {
        n >= 1_000_000 ? String(format: "%.1fm", Double(n) / 1_000_000)
            : (n >= 1000 ? String(format: "%dk", n / 1000) : "\(n)")
    }
}

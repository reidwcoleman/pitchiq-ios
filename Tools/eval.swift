import Foundation

// MARK: - Out-of-sample evaluation
//
// The only honest way to say a projection model is good is to hide a season
// from it and see what it says. FPL publishes per-season totals for every
// player back to 2022/23, so the model can be given everything through season
// Y and asked about season Y+1 — a full season of outcomes per player rather
// than a handful of gameweeks.
//
// Two questions get answered:
//   1. how well does it rank players?      (correlation, MAE, top-N overlap)
//   2. how many points would its squad have scored?   (the one that matters)

struct Eval {
    let bootJSON: [String: Any]
    let boot: Bootstrap
    let fixtures: [APIFixture]
    let rawPast: [String: [PastSeason]]

    // MARK: statistics

    static func pearson(_ a: [Double], _ b: [Double]) -> Double {
        let n = Double(a.count); guard n > 1 else { return 0 }
        let ma = a.reduce(0,+)/n, mb = b.reduce(0,+)/n
        var sab = 0.0, sa = 0.0, sb = 0.0
        for i in a.indices { let x = a[i]-ma, y = b[i]-mb; sab += x*y; sa += x*x; sb += y*y }
        return sa > 0 && sb > 0 ? sab / (sa*sb).squareRoot() : 0
    }

    /// Least-squares slope of y on x, through the data rather than the origin.
    static func slope(_ x: [Double], _ y: [Double]) -> Double {
        let n = Double(x.count); guard n > 1 else { return 0 }
        let mx = x.reduce(0,+)/n, my = y.reduce(0,+)/n
        var num = 0.0, den = 0.0
        for i in x.indices { num += (x[i]-mx)*(y[i]-my); den += (x[i]-mx)*(x[i]-mx) }
        return den > 0 ? num/den : 0
    }

    static func spearman(_ a: [Double], _ b: [Double]) -> Double {
        func ranks(_ v: [Double]) -> [Double] {
            let order = v.indices.sorted { v[$0] < v[$1] }
            var r = [Double](repeating: 0, count: v.count)
            var i = 0
            while i < order.count {
                var j = i
                while j + 1 < order.count, v[order[j+1]] == v[order[i]] { j += 1 }
                let avg = Double(i + j) / 2 + 1
                for k in i...j { r[order[k]] = avg }
                i = j + 1
            }
            return r
        }
        return pearson(ranks(a), ranks(b))
    }

    // MARK: building a hypothetical "pre-season" feed
    //
    // Every current-season number is blanked, including FPL's own `ep_next`,
    // so nothing about the target season can leak into the projection.

    func blankBootstrap() -> Bootstrap {
        var copy = bootJSON
        var elements = copy["elements"] as! [[String: Any]]
        let zeroInt = ["minutes","starts","bonus","bps","saves","goals_scored","assists",
                       "total_points","event_points","clean_sheets","goals_conceded",
                       "yellow_cards","red_cards","defensive_contribution","dreamteam_count",
                       "transfers_in_event","transfers_out_event","cost_change_event",
                       "cost_change_start"]
        let zeroStr = ["expected_goals","expected_assists","expected_goal_involvements",
                       "expected_goals_conceded","points_per_game","form","ep_next","ep_this",
                       "ict_index","threat","creativity","influence","value_form","value_season",
                       "price_change_percent"]
        let zeroDouble = ["expected_goals_per_90","expected_assists_per_90",
                          "expected_goals_conceded_per_90","saves_per_90","starts_per_90",
                          "clean_sheets_per_90","defensive_contribution_per_90",
                          "expected_goal_involvements_per_90"]
        for i in elements.indices {
            for k in zeroInt { elements[i][k] = 0 }
            for k in zeroStr { elements[i][k] = "0.0" }
            for k in zeroDouble { elements[i][k] = 0.0 }
            elements[i]["status"] = "a"
            elements[i]["chance_of_playing_next_round"] = NSNull()
            elements[i]["chance_of_playing_this_round"] = NSNull()
            elements[i]["news"] = ""
            elements[i]["price_change_projections"] = []
        }
        copy["elements"] = elements
        let data = try! JSONSerialization.data(withJSONObject: copy)
        return try! JSONDecoder().decode(Bootstrap.self, from: data)
    }

    /// A league-average fixture: no opponent, no home advantage, nothing to
    /// separate one player from another except the player.
    static let neutral = FixtureContext(
        opp: 0, home: true, diff: 3, atkScale: 1,
        csProb: exp(-TeamRatings.leagueGoals),
        concedePen: GoalsAgainst.halfConceded(TeamRatings.leagueGoals),
        savesScale: 1, histMult: 1)

    // MARK: the season-ahead test

    struct Case {
        let id: Int
        let name: String
        let pos: Int
        let cost: Int          // start-of-target-season price, tenths of £m
        let predicted: Double  // model's season points
        let actual: Double     // what they really scored
        let actualMinutes: Double
        let predictedMinutes: Double
        let naive: Double      // prior season's points — the baseline to beat
        let priorMinutes: Double
        let priorLastMinutes: Double
    }

    /// Everything the model knew before `target` kicked off, against what
    /// happened in it.
    func cases(target: String, tuning input: Tuning) -> [Case] {
        var tuning = input
        // Age the players correctly for the season being replayed.
        tuning.seasonYearOverride = Int(target.prefix(4))
        let blank = blankBootstrap()
        var out: [Case] = []
        let engine = ProjectionEngine(boot: blank, fixtures: fixtures, gwFrom: 1, horizon: 1,
                                      pastForm: PastFormBook(), tuning: tuning)
        for element in blank.elements {
            guard let all = rawPast[String(element.id)] else { continue }
            // Every player who was still in the league, not only the ones who
            // went on to play a lot: filtering on target minutes would hide the
            // model's worst failures, which are almost all minutes failures.
            guard let actual = all.first(where: { $0.season_name == target }) else { continue }
            let before = all.filter { $0.season_name < target }
            let prior = PastForm(seasons: before)
            guard prior.totalMinutes >= 450 else { continue }

            var book = PastFormBook()
            book.byId[element.id] = prior
            let scoped = ProjectionEngine(boot: blank, fixtures: fixtures, gwFrom: 1,
                                          horizon: 1, pastForm: book, tuning: tuning)
            let r = scoped.rates(for: element)
            let perMatch = r.components(Self.neutral).final
            let naive = before.max { $0.season_name < $1.season_name }
                .map { Double($0.total_points) } ?? 0
            out.append(Case(id: element.id, name: element.web_name,
                            pos: min(max(element.element_type, 1), 4),
                            cost: (actual.start_cost ?? 0) > 0 ? actual.start_cost! : element.now_cost,
                            predicted: perMatch * 38,
                            actual: Double(actual.total_points),
                            actualMinutes: Double(actual.minutes),
                            predictedMinutes: r.minShare * 90 * 38,
                            naive: naive,
                            priorMinutes: prior.totalMinutes,
                            priorLastMinutes: prior.last?.minutes ?? 0))
        }
        _ = engine
        return out
    }

    // MARK: the squad backtest
    //
    // Rank by a score, buy the best fifteen you can afford under FPL's position
    // quotas, and count what they actually scored. The club limit is dropped:
    // the API does not publish who played for whom in past seasons, and the
    // constraint costs every ranking about the same.

    static func squadPoints(_ cases: [Case], by score: (Case) -> Double,
                            budget: Int = 1000) -> (points: Double, names: [String]) {
        let quota = [0, 2, 5, 5, 3]
        var chosen: [Case] = []
        var spend = 0
        // Greedy on score per pound is the wrong answer; this is a small
        // multi-choice knapsack, so solve it as one: take the best fifteen
        // outright, then repair the budget by swapping in the cheapest loss.
        for pos in 1...4 {
            let pool = cases.filter { $0.pos == pos }.sorted { score($0) > score($1) }
            chosen += pool.prefix(quota[pos])
        }
        spend = chosen.reduce(0) { $0 + $1.cost }
        var pools: [Int: [Case]] = [:]
        for pos in 1...4 { pools[pos] = cases.filter { $0.pos == pos }.sorted { score($0) > score($1) } }
        var guard_ = 0
        while spend > budget, guard_ < 400 {
            guard_ += 1
            var best: (loss: Double, out: Int, into: Case)?
            for (i, held) in chosen.enumerated() {
                let ids = Set(chosen.map(\.id))
                for candidate in pools[held.pos]! where !ids.contains(candidate.id) && candidate.cost < held.cost {
                    let loss = (score(held) - score(candidate)) / Double(held.cost - candidate.cost)
                    if best == nil || loss < best!.loss { best = (loss, i, candidate) }
                }
            }
            guard let swap = best else { break }
            spend += swap.into.cost - chosen[swap.out].cost
            chosen[swap.out] = swap.into
        }
        // The eleven is chosen on the ranking under test, not on what happened
        // — picking it with hindsight flatters every ranking equally and tells
        // you nothing about which is better.
        let xi = bestEleven(chosen, by: score)
        let named = xi.sorted { score($0) > score($1) }.prefix(4).map { $0.name }
        return (xi.reduce(0) { $0 + $1.actual }, Array(named))
    }

    static func bestEleven(_ squad: [Case]) -> [Case] {
        bestEleven(squad, by: { $0.actual })
    }

    static func bestEleven(_ squad: [Case], by rank: (Case) -> Double) -> [Case] {
        var best: [Case] = []
        var bestTotal = -1.0
        for defs in 3...5 {
            for mids in 2...5 {
                let fwds = 10 - defs - mids
                guard fwds >= 1, fwds <= 3 else { continue }
                var xi: [Case] = []
                xi += squad.filter { $0.pos == 1 }.sorted { rank($0) > rank($1) }.prefix(1)
                xi += squad.filter { $0.pos == 2 }.sorted { rank($0) > rank($1) }.prefix(defs)
                xi += squad.filter { $0.pos == 3 }.sorted { rank($0) > rank($1) }.prefix(mids)
                xi += squad.filter { $0.pos == 4 }.sorted { rank($0) > rank($1) }.prefix(fwds)
                guard xi.count == 11 else { continue }
                let total = xi.reduce(0) { rank($1) + $0 }
                if total > bestTotal { bestTotal = total; best = xi }
            }
        }
        return best
    }

    // MARK: report

    @discardableResult
    func report(target: String, tuning: Tuning, verbose: Bool = true)
        -> (r: Double, rho: Double, mae: Double, squad: Double, capture: Double) {
        let list = cases(target: target, tuning: tuning)
        let predicted = list.map(\.predicted), actual = list.map(\.actual)
        let r = Self.pearson(predicted, actual)
        let rho = Self.spearman(predicted, actual)
        let mae = zip(predicted, actual).reduce(0) { $0 + abs($1.0 - $1.1) } / Double(list.count)

        let model = Self.squadPoints(list) { $0.predicted }
        let ceiling = Self.squadPoints(list) { $0.actual }.points
        // A smoother decision metric than the knapsack: the actual points held
        // by the fifty players the model liked most, over the fifty that turned
        // out best. It moves continuously as the ranking shifts, so it can be
        // optimised without latching onto one lucky swap.
        let n50 = min(50, list.count)
        let tookTop = list.sorted { $0.predicted > $1.predicted }.prefix(n50)
            .reduce(0) { $0 + $1.actual }
        let bestTop = list.sorted { $0.actual > $1.actual }.prefix(n50)
            .reduce(0) { $0 + $1.actual }
        let top50 = tookTop / max(bestTop, 1)
        if verbose {
            let naive = Self.squadPoints(list) { $0.naive }
            let cheap = Self.squadPoints(list) { -Double($0.cost) }
            let oracle = Self.squadPoints(list) { $0.actual }
            let market = Self.squadPoints(list) { Double($0.cost) }

            let top = Set(list.sorted { $0.predicted > $1.predicted }.prefix(50).map(\.id))
            let realTop = Set(list.sorted { $0.actual > $1.actual }.prefix(50).map(\.id))
            print("\n=== predicting \(target) from earlier seasons only  (n = \(list.count)) ===")
            let minsR = Self.pearson(list.map(\.predictedMinutes), list.map(\.actualMinutes))
            print(String(format: "  rank quality      r %.3f   rho %.3f   MAE %.1f pts over a season", r, rho, mae))
            print(String(format: "  minutes           r %.3f   (predicting who plays is most of the job)", minsR))
            print(String(format: "  top-50 overlap    %d of 50", top.intersection(realTop).count))
            for pos in 1...4 {
                let sub = list.filter { $0.pos == pos }
                guard sub.count > 15 else { continue }
                print(String(format: "    %@  n %3d   r %.3f", ["","GK ","DEF","MID","FWD"][pos] as NSString,
                             sub.count, Self.pearson(sub.map(\.predicted), sub.map(\.actual))))
            }
            print("\n  a £100m fifteen picked on each ranking, scored on what it really did:")
            print(String(format: "    model            %.0f   %@", model.points, model.names.joined(separator: ", ")))
            print(String(format: "    last season's pts%.0f   %@", naive.points, naive.names.joined(separator: ", ")))
            print(String(format: "    most expensive   %.0f", market.points))
            print(String(format: "    cheapest         %.0f", cheap.points))
            print(String(format: "    perfect hindsight%.0f", oracle.points))
            print(String(format: "    → model captures %.1f%% of the achievable, naive %.1f%%",
                         model.points / oracle.points * 100, naive.points / oracle.points * 100))
            print(String(format: "    top-50 the model liked held %.0f%% of the points the best fifty did", top50 * 100))
        }
        return (r, rho, mae, model.points, top50)
    }

    /// Everything the report knows, for the fitter.
    func measure(_ t: Tuning, on season: String) -> (rho: Double, top50: Double, squad: Double) {
        let out = report(target: season, tuning: t, verbose: false)
        return (out.rho, out.capture, out.squad)
    }

    // MARK: - fitting
    //
    // Coordinate descent over the constants, scored on both replayable seasons
    // at once. The objective mixes how well the model ranks players with how
    // many points its squad actually took, because either on its own is
    // gameable: a model can rank well and still buy the wrong fifteen, and a
    // squad score alone is a step function that latches onto noise.

    // Expected goals only exist from 2022/23, so those are the seasons that
    // can be replayed with the model the app actually ships.
    static let seasons = ["2023/24", "2024/25", "2025/26"]

    func score(_ t: Tuning, on seasons: [String]) -> Double {
        var total = 0.0
        for season in seasons {
            let m = measure(t, on: season)
            total += 0.5 * m.top50 + 0.5 * m.rho
        }
        return total / Double(max(seasons.count, 1))
    }

    /// Minutes on their own, against the only baseline that matters: what the
    /// player played last season. The whole model is downstream of this.
    func minutesReport(_ variants: [(String, Tuning)]) {
        print("\n=== predicting minutes ===")
        print("  " + "variant".padding(toLength: 26, withPad: " ", startingAt: 0)
              + Self.seasons.map { String($0.prefix(5)) }.joined(separator: "   ") + "   mean")
        var baselineRow: [Double] = []
        for season in Self.seasons {
            let list = cases(target: season, tuning: .default)
            // last season's minutes, straight through
            let last = list.map { $0.priorLastMinutes }
            baselineRow.append(Self.pearson(last, list.map(\.actualMinutes)))
        }
        print(String(format: "  %@%@   %.3f", "last season's minutes".padding(toLength: 26, withPad: " ", startingAt: 0) as NSString,
                     baselineRow.map { String(format: "%.3f", $0) }.joined(separator: "   ") as NSString,
                     baselineRow.reduce(0,+) / Double(baselineRow.count)))
        for (name, t) in variants {
            var row: [Double] = []
            for season in Self.seasons {
                let list = cases(target: season, tuning: t)
                row.append(Self.pearson(list.map(\.predictedMinutes), list.map(\.actualMinutes)))
            }
            print(String(format: "  %@%@   %.3f", name.padding(toLength: 26, withPad: " ", startingAt: 0) as NSString,
                         row.map { String(format: "%.3f", $0) }.joined(separator: "   ") as NSString,
                         row.reduce(0,+) / Double(row.count)))
        }
    }

    /// Where the error actually lives. A season's points are minutes times a
    /// rate, and the two are worth very different amounts of work: this hands
    /// the model perfect knowledge of one and measures what is left.
    func diagnose(tuning: Tuning) {
        print("\n=== where the error is ===")
        print("  season    as shipped   perfect minutes   perfect rate")
        for season in Self.seasons {
            let list = cases(target: season, tuning: tuning)
                .filter { $0.actualMinutes > 90 && $0.predictedMinutes > 0 }
            let actual = list.map(\.actual)
            let shipped = Self.pearson(list.map(\.predicted), actual)
            // predicted rate, real minutes
            let rateOnly = Self.pearson(list.map { $0.predicted / max($0.predictedMinutes, 1) * $0.actualMinutes }, actual)
            // real rate, predicted minutes
            let minsOnly = Self.pearson(list.map { $0.actual / max($0.actualMinutes, 1) * $0.predictedMinutes }, actual)
            print(String(format: "  %@     r %.3f       r %.3f            r %.3f",
                         season as NSString, shipped, rateOnly, minsOnly))
        }
        print("  (whichever column is furthest above 'as shipped' is where the headroom is)")
    }

    /// One knob at a time, every season shown separately. A constant is only
    /// worth changing if it moves all three the same way — with three seasons
    /// and a dozen knobs, anything else is noise being fitted.
    func sweep() {
        let base = Tuning.default
        for knob in Self.knobs {
            print("\n\(knob.name)   (shipped \(knob.read(base)))")
            print("    value        " + Self.seasons.map { String($0.prefix(5)) }
                    .joined(separator: "     ") + "     mean")
            for value in knob.values {
                var trial = base
                knob.apply(&trial, value)
                let per = Self.seasons.map { measure(trial, on: $0) }
                let cells = per.map { String(format: "%.3f", 0.5 * $0.top50 + 0.5 * $0.rho) }
                let mean = per.reduce(0) { $0 + 0.5 * $1.top50 + 0.5 * $1.rho } / Double(per.count)
                let mark = value == knob.read(base) ? " ←shipped" : ""
                print(String(format: "  %8.3f     %@     %.4f%@", value,
                             cells.joined(separator: "   ") as NSString, mean, mark as NSString))
            }
        }
    }

    func objective(_ t: Tuning) -> Double { score(t, on: Self.seasons) }

    static func setPos(_ t: inout Tuning, _ pos: Int, _ v: Double) {
        var list = t.modelShareByPos ?? [Double](repeating: t.modelShare, count: 5)
        list[pos] = v
        t.modelShareByPos = list
    }
    static func readPos(_ t: Tuning, _ pos: Int) -> Double {
        t.modelShareByPos?[pos] ?? t.modelShare
    }

    struct Knob {
        let name: String
        let values: [Double]
        let apply: (inout Tuning, Double) -> Void
        let read: (Tuning) -> Double
    }

    static let knobs: [Knob] = [
        Knob(name: "recency[1]", values: [0.20, 0.30, 0.40, 0.45, 0.55, 0.70],
             apply: { $0.recency[1] = $1 }, read: { $0.recency[1] }),
        Knob(name: "recency[2]", values: [0.0, 0.08, 0.18, 0.30, 0.45],
             apply: { $0.recency[2] = $1 }, read: { $0.recency[2] }),
        Knob(name: "minsRecency[1]", values: [0.05, 0.12, 0.22, 0.35, 0.5],
             apply: { $0.minutesRecency[1] = $1 }, read: { $0.minutesRecency[1] }),
        Knob(name: "minsRecency[2]", values: [0.0, 0.06, 0.15, 0.28],
             apply: { $0.minutesRecency[2] = $1 }, read: { $0.minutesRecency[2] }),
        Knob(name: "priorCap", values: [1600, 2100, 2600, 3200, 4000],
             apply: { $0.priorCap = $1 }, read: { $0.priorCap }),
        Knob(name: "credHalf", values: [240, 380, 540, 750, 1100],
             apply: { $0.credHalf = $1 }, read: { $0.credHalf }),
        Knob(name: "modelShare", values: [0.0, 0.10, 0.20, 0.28, 0.35, 0.45, 0.62],
             apply: { $0.modelShare = $1 }, read: { $0.modelShare }),
        Knob(name: "ageFloor", values: [0.55, 0.65, 0.72, 0.82, 0.9],
             apply: { $0.ageFloor = $1 }, read: { $0.ageFloor }),
        Knob(name: "durabilityPenalty", values: [0.0, 0.1, 0.2, 0.35, 0.5, 0.7],
             apply: { $0.durabilityPenalty = $1 }, read: { $0.durabilityPenalty }),
        Knob(name: "minutesShrinkGames", values: [0, 4, 8, 14, 22, 34, 50],
             apply: { $0.minutesShrinkGames = $1 }, read: { $0.minutesShrinkGames }),
        Knob(name: "modelShare GK", values: [0.0, 0.15, 0.32, 0.5, 0.7, 0.9],
             apply: { setPos(&$0, 1, $1) }, read: { readPos($0, 1) }),
        Knob(name: "modelShare DEF", values: [0.0, 0.15, 0.32, 0.5, 0.7, 0.9],
             apply: { setPos(&$0, 2, $1) }, read: { readPos($0, 2) }),
        Knob(name: "modelShare MID", values: [0.0, 0.15, 0.32, 0.5, 0.7, 0.9],
             apply: { setPos(&$0, 3, $1) }, read: { readPos($0, 3) }),
        Knob(name: "modelShare FWD", values: [0.0, 0.15, 0.32, 0.5, 0.7, 0.9],
             apply: { setPos(&$0, 4, $1) }, read: { readPos($0, 4) }),
        Knob(name: "minutesPriorScale", values: [0.4, 0.5, 0.6, 0.75, 0.9, 1.0],
             apply: { $0.minutesPriorScale = $1 }, read: { $0.minutesPriorScale }),
        Knob(name: "agePenalty", values: [0.0, 0.04, 0.08, 0.11, 0.15, 0.22, 0.30],
             apply: { $0.agePenalty = $1 }, read: { $0.agePenalty }),
        Knob(name: "peakAge", values: [22, 24, 26, 27, 29, 31],
             apply: { $0.peakAge = $1 }, read: { $0.peakAge }),
        Knob(name: "minutesAgePenalty", values: [0.0, 0.015, 0.03, 0.05, 0.08],
             apply: { $0.minutesAgePenalty = $1 }, read: { $0.minutesAgePenalty }),
        Knob(name: "minutesPeakAge", values: [26, 28, 29, 31],
             apply: { $0.minutesPeakAge = $1 }, read: { $0.minutesPeakAge }),
    ]

    func fit(passes: Int = 3, on seasons: [String]? = nil, quiet: Bool = false) -> Tuning {
        let train = seasons ?? Self.seasons
        var best = Tuning.default
        var bestScore = score(best, on: train)
        if !quiet { print(String(format: "start  %.4f", bestScore)) }
        for pass in 1...passes {
            var improved = false
            for knob in Self.knobs {
                var localBest = knob.read(best)
                var localScore = bestScore
                for value in knob.values where value != knob.read(best) {
                    var trial = best
                    knob.apply(&trial, value)
                    let s = self.score(trial, on: train)
                    if s > localScore + 1e-6 { localScore = s; localBest = value }
                }
                if localScore > bestScore + 1e-6 {
                    knob.apply(&best, localBest)
                    bestScore = localScore
                    improved = true
                    if !quiet {
                        print(String(format: "  pass %d  %-18@ → %-7.3f  %.4f", pass,
                                     knob.name as NSString, localBest, bestScore))
                    }
                }
            }
            if !improved { if !quiet { print("  pass \(pass): converged") }; break }
        }
        return best
    }

    /// Leave-one-season-out. Fitting twelve constants on three seasons will
    /// find something; this says whether what it found is real.
    func crossValidate() {
        print("\n=== leave-one-season-out ===")
        var heldDefault = 0.0, heldFitted = 0.0
        for held in Self.seasons {
            let train = Self.seasons.filter { $0 != held }
            let fitted = fit(passes: 3, on: train, quiet: true)
            let base = score(.default, on: [held])
            let test = score(fitted, on: [held])
            heldDefault += base; heldFitted += test
            print(String(format: "  train %@  →  test %@   shipped %.4f   fitted %.4f   %+.4f",
                         train.joined(separator: "+") as NSString, held as NSString,
                         base, test, test - base))
        }
        let n = Double(Self.seasons.count)
        print(String(format: "  mean held-out: shipped %.4f → fitted %.4f  (%+.1f%%)",
                     heldDefault / n, heldFitted / n,
                     (heldFitted / heldDefault - 1) * 100))
    }
}

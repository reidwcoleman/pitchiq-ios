import Foundation

// MARK: - Is it just chasing last week?
//
// The failure mode of every fantasy model is recency: a player scores 17 on the
// opening day, the model decides he is elite, and the manager buys him at the
// top of his price. The way to find out whether this one does it is to run the
// projection twice — once knowing what happened last gameweek, once not — and
// look at what the difference correlates with.
//
// Some responsiveness is correct. A player who has just won a starting place is
// genuinely worth more than he was a week ago, and a model that ignores the
// season entirely would still be projecting the pre-season squad in May. The
// question is whether the response is proportional to how much a single
// gameweek actually tells you, which with a season of prior evidence behind it
// is not very much.

struct RecencyAudit {
    let eval: Eval
    let book: PastFormBook
    let recent: RecentMinutes

    struct Row {
        let name: String
        let pos: Int
        let cost: Int
        let withWeek: Double        // projection knowing last gameweek
        let withoutWeek: Double     // projection with the season blanked
        let lastGwPoints: Int
        let lastGwMinutes: Int
        let priorMinutes: Double
        let flagged: Bool
        var shift: Double { withWeek - withoutWeek }
        /// Someone the model had a real opinion about before the season began.
        var established: Bool { priorMinutes >= 900 }
    }

    func rows(gw: Int, live: [Int: LiveStats]) -> [Row] {
        let real = eval.boot
        let blank = eval.blankBootstrap()
        let engFull = ProjectionEngine(boot: real, fixtures: eval.fixtures, gwFrom: gw + 1,
                                       horizon: 6, pastForm: book, recent: recent)
        let engPrior = ProjectionEngine(boot: blank, fixtures: eval.fixtures, gwFrom: gw + 1,
                                        horizon: 6, pastForm: book, recent: RecentMinutes())
        let full = engFull.buildPlayers(totalManagers: real.total_players ?? 11_000_000)
        let prior = engPrior.buildPlayers(totalManagers: real.total_players ?? 11_000_000)
        var priorById: [Int: Double] = [:]
        for p in prior { priorById[p.id] = p.perGw }
        return full.compactMap { p in
            guard let before = priorById[p.id] else { return nil }
            let stats = live[p.id]
            return Row(name: p.name, pos: p.pos, cost: p.cost,
                       withWeek: p.perGw, withoutWeek: before,
                       lastGwPoints: stats?.total_points ?? 0,
                       lastGwMinutes: stats?.minutes ?? 0,
                       priorMinutes: book[p.id]?.last?.minutes ?? 0,
                       flagged: p.flagged)
        }
    }

    func report(gw: Int, live: [Int: LiveStats]) {
        let all = rows(gw: gw, live: live)
        // Only players who could plausibly be picked; the tail of academy
        // players who project at zero either way would flatter every number.
        let list = all.filter { $0.withoutWeek > 1.0 || $0.withWeek > 1.0 }
        guard list.count > 50 else { print("not enough data"); return }

        print("\n=== how much does gameweek \(gw) move the projection? ===")
        print("  Two different things get mixed together here and only one is a fault.")
        print("  A player with no Premier League record who has just started a match is")
        print("  genuinely new information. A player with a season behind him who scored")
        print("  well once is not. Availability is a third thing again — an injury is a")
        print("  fact, not a form reading — so flagged players are excluded below.\n")
        // The measure that matters: established, available players. Anyone the
        // model had no prior opinion about, and anyone carrying a flag, is
        // moving for reasons that are not recency.
        let core = list.filter { $0.established && !$0.flagged }
        for (label, set) in [("established and available", core),
                             ("no prior record", list.filter { !$0.established }),
                             ("everyone", list)] {
            guard set.count > 20 else { continue }
            let s = set.map(\.shift), pts = set.map { Double($0.lastGwPoints) }
            let base = set.map(\.withoutWeek).reduce(0,+) / Double(set.count)
            print(String(format: "  %-26@ n %3d   r %+.3f   %.3f pts/GW per point scored   base %.2f",
                         label as NSString, set.count, Eval.pearson(s, pts),
                         Eval.slope(pts, s), base))
        }

        let shifts = core.map(\.shift)
        let points = core.map { Double($0.lastGwPoints) }
        let r = Eval.pearson(shifts, points)
        let meanAbs = shifts.reduce(0) { $0 + abs($1) } / Double(max(shifts.count, 1))
        let meanBase = core.map(\.withoutWeek).reduce(0, +) / Double(max(core.count, 1))
        print(String(format: "\n  established, available players (n = %d):", core.count))
        print(String(format: "    correlation between the shift and last week's score: r = %.3f", r))
        print(String(format: "    average shift %.2f pts/GW on a base of %.2f  (%.0f%%)",
                     meanAbs, meanBase, meanAbs / meanBase * 100))

        // What one point last Saturday is worth in projection terms.
        let slope = Eval.slope(points, shifts)
        print(String(format: "    a 15-point haul moves an established player by %+.2f pts/GW", slope * 15))
        print("    (one match against a season of evidence is worth roughly a fortieth of it)")

        // The test that matters: is the top of the list last week's scorers?
        func topTwenty(_ by: (Row) -> Double) -> [Row] {
            Array(list.filter { !$0.flagged }.sorted { by($0) > by($1) }.prefix(20))
        }
        let now = topTwenty { $0.withWeek }
        let before = topTwenty { $0.withoutWeek }
        let leagueAvg = list.map { Double($0.lastGwPoints) }.reduce(0, +) / Double(list.count)
        let nowAvg = now.map { Double($0.lastGwPoints) }.reduce(0, +) / 20
        let beforeAvg = before.map { Double($0.lastGwPoints) }.reduce(0, +) / 20
        print(String(format: "\n  last gameweek's average score, all %d: %.1f", list.count, leagueAvg))
        print(String(format: "  ... among the model's top 20 now:        %.1f", nowAvg))
        print(String(format: "  ... among its top 20 ignoring the week:  %.1f", beforeAvg))
        let churn = 20 - Set(now.map(\.name)).intersection(Set(before.map(\.name))).count
        print("  players in the top 20 only because of last week: \(churn) of 20")

        print("\n  biggest risers among players with a season already behind them")
        for row in core.sorted(by: { $0.shift > $1.shift }).prefix(8) {
            print(String(format: "    %-16@ %4.2f → %4.2f  (%+.2f)  scored %2d in GW%d over %d'",
                         row.name as NSString, row.withoutWeek, row.withWeek, row.shift,
                         row.lastGwPoints, gw, row.lastGwMinutes))
        }
        print("  biggest fallers among the same group")
        for row in core.sorted(by: { $0.shift < $1.shift }).prefix(6) {
            print(String(format: "    %-16@ %4.2f → %4.2f  (%+.2f)  scored %2d in GW%d over %d'",
                         row.name as NSString, row.withoutWeek, row.withWeek, row.shift,
                         row.lastGwPoints, gw, row.lastGwMinutes))
        }
    }
}

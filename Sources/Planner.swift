import Foundation

// MARK: - Multi-gameweek transfer + chip planner
// Picks an opening squad weighted across the season, then simulates week by
// week with real FPL rules: 1 free transfer per GW (bankable to 5, max 2
// moves/week), -4 hits only when clearly worth it, injured players replaced
// with priority. On top of the base plan it schedules every chip the game
// gives you (Wildcard / Free Hit / Bench Boost / Triple Captain — one of
// each per half-season) where each earns the most points:
//   Wildcard      unlimited free transfers; the new squad persists
//   Free Hit      one-week dream team (great for double gameweeks); reverts
//   Bench Boost   bench points count that week
//   Triple Cap    captain ×3 instead of ×2

struct TransferMove: Identifiable {
    let id = UUID()
    let out: Player
    let inn: Player
    let paid: Bool
    let gain: Double
}

struct ChipMeta {
    let name: String
    let start: Int
    let stop: Int
}

struct ChipPlay: Identifiable {
    var id: String { "\(chip)-\(gw)" }
    let chip: String
    let gw: Int
    let gain: Double
}

struct GWPlan: Identifiable {
    var id: Int { gw }
    let gw: Int
    let transfers: [TransferMove]
    let xi: [Player]           // reprojected to this GW's values
    let bench: [Player]
    let captain: Player
    let formation: String
    let projPts: Double        // XI + captain bonus (+chip effects) - hits
    let ftsLeft: Int
    let hitPts: Int
    let chip: String?          // chip played this GW, if any
}

struct SeasonPlan {
    let gws: [GWPlan]
    let totalPts: Double
    let totalTransfers: Int
    let totalHits: Int
    let fromUserSquad: Bool
    let chips: [ChipPlay]
    let heldChips: [String]    // chips kept in reserve — no week currently gains
}

enum Planner {
    static let hitGainThreshold = 6.0
    static let decay = 0.88

    static func freeThreshold(ftsBanked: Int, outInjured: Bool) -> Double {
        if outInjured { return 0.0 }
        if ftsBanked >= 5 { return 0.1 }
        if ftsBanked >= 3 { return 0.25 }
        return 0.5
    }

    static func weightedValue(_ p: Player, from gw: Int, to end: Int) -> Double {
        var v = 0.0, w = 1.0
        var g = gw
        while g <= end {
            v += (p.projByGw[g] ?? 0) * w
            w *= decay
            g += 1
        }
        return v
    }

    enum ChipAction {
        case wildcard([Player])
        case freeHit(xi: [Player], bench: [Player], captain: Player, formation: String, pts: Double)
        case tripleCaptain
        case benchBoost
    }

    struct SimResult {
        var gws: [GWPlan] = []
        var totalPts = 0.0
        var totalTransfers = 0
        var totalHits = 0
        var squadAtStart: [Int: [Player]] = [:]
        var ftsAtStart: [Int: Int] = [:]
    }

    // MARK: entry point

    static func plan(players: [Player], budgetM: Double, fitOnly: Bool,
                     from: Int, window: Int, userSquad: [Player]? = nil,
                     chipsMeta: [ChipMeta] = []) -> SeasonPlan? {
        let end = min(from + window - 1, 38)
        guard end >= from else { return nil }
        let budget = Int((budgetM * 10).rounded())
        let pool = Optimizer.candidatePool(players, fitOnly: fitOnly)
        let byId = Dictionary(uniqueKeysWithValues: players.map { ($0.id, $0) })

        var squad0: [Player]
        var fts0: Int
        let fromUser: Bool
        if let user = userSquad, user.count == 15 {
            squad0 = user
            fts0 = 1
            fromUser = true
        } else {
            let scored = players
                .map { $0.reprojected(weightedValue($0, from: from, to: end)) }
                .sorted { $0.proj > $1.proj }
            guard let opening = Optimizer.optimize(players: scored, budgetM: budgetM, fitOnly: fitOnly)
            else { return nil }
            squad0 = opening.squad.compactMap { byId[$0.id] }
            fts0 = 0
            fromUser = false
        }
        guard squad0.count == 15 else { return nil }

        // pass 1: base plan without chips
        let base = simulate(players: players, pool: pool, budget: budget,
                            from: from, end: end, initial: squad0, initialFts: fts0,
                            allowFirstMoves: fromUser, chips: [:])

        // pass 2: schedule chips where they earn the most
        var actions: [Int: ChipAction] = [:]
        var plays: [ChipPlay] = []
        var heldChips: [String] = []
        let order = ["wildcard", "freehit", "3xc", "bboost"]
        let sortedMeta = chipsMeta
            .filter { $0.stop >= from && $0.start <= end }
            .sorted {
                $0.start != $1.start ? $0.start < $1.start
                    : (order.firstIndex(of: $0.name) ?? 9) < (order.firstIndex(of: $1.name) ?? 9)
            }

        for meta in sortedMeta {
            // transfer chips can't be played the week the plan already builds a
            // fresh squad; team chips can be played any week in window
            let minGw = meta.name == "wildcard" || meta.name == "freehit"
                ? max(meta.start, fromUser ? from : from + 1)
                : max(meta.start, from)
            let lo = minGw, hi = min(meta.stop, end)
            guard lo <= hi else { continue }
            let free = (lo...hi).filter { actions[$0] == nil }
            guard !free.isEmpty else { continue }

            switch meta.name {
            case "3xc":
                var bestGw: Int?; var bestGain = -1.0
                for gp in base.gws where free.contains(gp.gw) {
                    if gp.captain.proj > bestGain { bestGain = gp.captain.proj; bestGw = gp.gw }
                }
                if let g = bestGw {
                    actions[g] = .tripleCaptain
                    plays.append(ChipPlay(chip: "3xc", gw: g, gain: max(bestGain, 0)))
                }

            case "bboost":
                var bestGw: Int?; var bestGain = -1.0
                for gp in base.gws where free.contains(gp.gw) {
                    let benchPts = gp.bench.reduce(0) { $0 + $1.proj }
                    if benchPts > bestGain { bestGain = benchPts; bestGw = gp.gw }
                }
                if let g = bestGw {
                    actions[g] = .benchBoost
                    plays.append(ChipPlay(chip: "bboost", gw: g, gain: max(bestGain, 0)))
                }

            case "freehit":
                // candidates: biggest gap between the league's ceiling that week
                // (top-11 projections anywhere — doubles push this way up) and
                // what the base squad scores
                let basePts = Dictionary(uniqueKeysWithValues: base.gws.map { ($0.gw, $0.projPts) })
                let cands = free
                    .map { g -> (Int, Double) in
                        let ceiling = players.map { $0.projByGw[g] ?? 0 }.sorted(by: >).prefix(11).reduce(0, +)
                        return (g, ceiling - (basePts[g] ?? 0))
                    }
                    .sorted { $0.1 > $1.1 }
                    .prefix(3)
                var best: (gw: Int, pts: Double, sq: SquadResult)?
                for (g, _) in cands {
                    let scored = players
                        .map { $0.reprojected($0.projByGw[g] ?? 0) }
                        .sorted { $0.proj > $1.proj }
                    guard let sq = Optimizer.optimize(players: scored, budgetM: budgetM, fitOnly: fitOnly,
                                                      iters: 3000, restarts: 2) else { continue }
                    let pts = sq.total + sq.captain.proj
                    if best == nil || pts - (basePts[g] ?? 0) > best!.pts - (basePts[best!.gw] ?? 0) {
                        best = (g, pts, sq)
                    }
                }
                if let b = best {
                    // always play it — the chip expires at the half; the pick
                    // gravitates to double-gameweeks automatically because
                    // two-fixture players carry doubled projections that week
                    let gain = max(b.pts - (basePts[b.gw] ?? 0), 0)
                    actions[b.gw] = .freeHit(xi: b.sq.xi, bench: b.sq.bench, captain: b.sq.captain,
                                             formation: b.sq.formation, pts: b.pts)
                    plays.append(ChipPlay(chip: "freehit", gw: b.gw, gain: gain))
                }

            case "wildcard":
                // try spread candidates across the window: rebuild the squad
                // there and re-simulate the rest of the season
                let candSet = Set(stride(from: lo, through: hi, by: max((hi - lo) / 4, 1)))
                    .filter { free.contains($0) }
                var best: (gw: Int, gain: Double, squad: [Player])?
                for g in candSet.sorted() {
                    let scored = players
                        .map { $0.reprojected(weightedValue($0, from: g, to: end)) }
                        .sorted { $0.proj > $1.proj }
                    guard let nsq = Optimizer.optimize(players: scored, budgetM: budgetM, fitOnly: fitOnly,
                                                       iters: 8000, restarts: 3) else { continue }
                    let newSquad = nsq.squad.compactMap { byId[$0.id] }
                    guard newSquad.count == 15 else { continue }
                    let rest = simulate(players: players, pool: pool, budget: budget,
                                        from: g, end: end, initial: newSquad,
                                        initialFts: base.ftsAtStart[g] ?? 1,
                                        allowFirstMoves: false, chips: [:])
                    let baseRest = base.gws.filter { $0.gw >= g }.reduce(0) { $0 + $1.projPts }
                    let gain = rest.totalPts - baseRest
                    if best == nil || gain > best!.gain { best = (g, gain, newSquad) }
                }
                // always play it — each wildcard expires at its half's deadline,
                // so it goes on the best rebuild week available
                if let b = best {
                    // only actually swap squads if the rebuild doesn't lose points
                    if b.gain >= -0.5 {
                        actions[b.gw] = .wildcard(b.squad)
                    } else if let keep = base.squadAtStart[b.gw] {
                        actions[b.gw] = .wildcard(keep) // "paper" wildcard: keep the squad
                    }
                    plays.append(ChipPlay(chip: "wildcard", gw: b.gw, gain: max(b.gain, 0)))
                } else {
                    heldChips.append("wildcard")
                }

            default: break
            }
        }

        // pass 3: final simulation with chips applied
        let fin = simulate(players: players, pool: pool, budget: budget,
                           from: from, end: end, initial: squad0, initialFts: fts0,
                           allowFirstMoves: fromUser, chips: actions)
        return SeasonPlan(gws: fin.gws, totalPts: fin.totalPts,
                          totalTransfers: fin.totalTransfers, totalHits: fin.totalHits,
                          fromUserSquad: fromUser,
                          chips: plays.sorted { $0.gw < $1.gw },
                          heldChips: heldChips)
    }

    // MARK: week-by-week simulation

    static func simulate(players: [Player], pool: [Player], budget: Int,
                         from: Int, end: Int, initial: [Player], initialFts: Int,
                         allowFirstMoves: Bool, chips: [Int: ChipAction]) -> SimResult {
        var squad = initial
        var fts = initialFts
        var bank = max(budget - squad.reduce(0) { $0 + $1.cost }, 0)
        var res = SimResult()

        for g in from...end {
            res.squadAtStart[g] = squad
            res.ftsAtStart[g] = fts
            if g > from { fts = min(fts + 1, 5) }

            var chipName: String?
            var suppressMoves = false
            if let action = chips[g] {
                switch action {
                case .wildcard(let newSquad):
                    squad = newSquad
                    bank = max(budget - squad.reduce(0) { $0 + $1.cost }, 0)
                    chipName = "wildcard"
                    suppressMoves = true
                case .freeHit:
                    chipName = "freehit"
                    suppressMoves = true
                case .tripleCaptain:
                    chipName = "3xc"
                case .benchBoost:
                    chipName = "bboost"
                }
            }

            var moves: [TransferMove] = []
            var hitPts = 0
            if !suppressMoves && (g > from || allowFirstMoves) {
                while moves.count < 2 {
                    guard let best = bestTransfer(squad: squad, pool: pool, bank: bank,
                                                  from: g, to: end) else { break }
                    let isFree = fts > 0
                    let outInjured = best.out.flagged || best.out.avail < 0.75
                    let threshold = isFree
                        ? freeThreshold(ftsBanked: fts, outInjured: outInjured)
                        : (outInjured ? 4.5 : hitGainThreshold)
                    guard best.gain >= threshold else { break }
                    let idx = squad.firstIndex(of: best.out)!
                    squad[idx] = best.inn
                    bank += best.out.cost - best.inn.cost
                    if isFree { fts -= 1 } else { hitPts += 4 }
                    moves.append(TransferMove(out: best.out, inn: best.inn,
                                              paid: !isFree, gain: best.gain))
                }
            }

            // Free Hit: play the one-week dream team; squad itself unchanged
            if case .freeHit(let xi, let bench, let captain, let formation, let pts)? = chips[g] {
                res.gws.append(GWPlan(gw: g, transfers: [], xi: xi, bench: bench,
                                      captain: captain, formation: formation,
                                      projPts: pts, ftsLeft: fts, hitPts: 0, chip: chipName))
                res.totalPts += pts
                continue
            }

            let gwSquad = squad.map { $0.reprojected($0.projByGw[g] ?? 0) }
            guard let r = Optimizer.bestXI(gwSquad) else { continue }
            let sorted = r.xi.sorted { $0.proj > $1.proj }
            let cap = sorted[0]
            var pts = r.total + cap.proj - Double(hitPts)
            if case .tripleCaptain? = chips[g] { pts += cap.proj }   // ×3 total
            if case .benchBoost? = chips[g] { pts += r.bench.reduce(0) { $0 + $1.proj } }

            res.totalPts += pts
            res.totalTransfers += moves.count
            res.totalHits += hitPts
            res.gws.append(GWPlan(gw: g, transfers: moves, xi: r.xi, bench: r.bench,
                                  captain: cap, formation: r.formation,
                                  projPts: pts, ftsLeft: fts, hitPts: hitPts, chip: chipName))
        }
        return res
    }

    private static func bestTransfer(squad: [Player], pool: [Player], bank: Int,
                                     from g: Int, to end: Int)
        -> (out: Player, inn: Player, gain: Double)? {
        var clubs: [Int: Int] = [:]
        for p in squad { clubs[p.team, default: 0] += 1 }
        let squadIds = Set(squad.map(\.id))

        var best: (out: Player, inn: Player, gain: Double)?
        var bestInjured: (out: Player, inn: Player, gain: Double)?
        for out in squad {
            let outValue = weightedValue(out, from: g, to: end)
            let outInjured = out.flagged || out.avail < 0.75
            for inn in pool where inn.pos == out.pos && !squadIds.contains(inn.id) {
                guard inn.cost <= out.cost + bank else { continue }
                let clubCount = clubs[inn.team, default: 0] - (inn.team == out.team ? 1 : 0)
                guard clubCount < 3 else { continue }
                let gain = weightedValue(inn, from: g, to: end) - outValue
                if best == nil || gain > best!.gain { best = (out, inn, gain) }
                if outInjured, bestInjured == nil || gain > bestInjured!.gain {
                    bestInjured = (out, inn, gain)
                }
            }
        }
        if let inj = bestInjured, inj.gain > 0 { return inj }
        return best
    }
}

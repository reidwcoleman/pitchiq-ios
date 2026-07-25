import Foundation

// MARK: - Multi-gameweek transfer + chip planner
// Picks an opening squad weighted across the season, then simulates week by
// week with real FPL rules: 1 free transfer per GW (bankable to 5), every
// banked FT spent whenever a move genuinely benefits the team (never when it
// doesn't), -4 hits only when clearly worth it, injured players replaced
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

// MARK: - Precomputed planning tables
//
// `weightedValue` — a player's decay-weighted points from gameweek g to the end
// of the window — was recomputed by looping over up to 38 gameweeks, inside a
// loop over every squad/pool pair, inside a loop over every gameweek. That is
// the single hottest path in the app. Because the weights are geometric it
// satisfies W(g) = proj(g) + decay·W(g+1), so the whole table is built once by
// a backward pass and every later read is a single array index.

final class PlanContext {
    let players: [Player]
    let from: Int
    let end: Int
    let span: Int
    let index: [Int: Int]          // player id → compact index
    let gwProj: [Double]           // [i * span + (gw - from)]
    let wv: [Double]               // decay-weighted value from gw to end
    let pool: [Int]                // compact indices of transfer candidates
    let picks: [Pick]              // identity/cost/team, proj filled per use

    init(players: [Player], pool poolPlayers: [Player], from: Int, end: Int) {
        self.players = players
        self.from = from
        self.end = end
        let span = max(end - from + 1, 1)
        self.span = span

        var idx = [Int: Int](minimumCapacity: players.count)
        for (i, p) in players.enumerated() { idx[p.id] = i }
        self.index = idx

        var proj = [Double](repeating: 0, count: players.count * span)
        var weighted = [Double](repeating: 0, count: players.count * span)
        for (i, p) in players.enumerated() {
            let base = i * span
            for k in 0..<span { proj[base + k] = p.projByGw.at(from + k) }
            var acc = 0.0
            var k = span - 1
            while k >= 0 {
                acc = proj[base + k] + Planner.decay * acc
                weighted[base + k] = acc
                k -= 1
            }
        }
        self.gwProj = proj
        self.wv = weighted
        self.pool = poolPlayers.compactMap { idx[$0.id] }
        self.picks = players.map { $0.pick(0) }
    }

    @inline(__always) func proj(_ i: Int, _ gw: Int) -> Double {
        let k = gw - from
        guard k >= 0, k < span else { return 0 }
        return gwProj[i * span + k]
    }

    @inline(__always) func weighted(_ i: Int, _ gw: Int) -> Double {
        let k = gw - from
        guard k >= 0, k < span else { return 0 }
        return wv[i * span + k]
    }

    @inline(__always) func pick(_ i: Int, _ gw: Int) -> Pick {
        var p = picks[i]
        p.proj = proj(i, gw)
        return p
    }
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

    /// Kept for callers outside the simulation hot path.
    static func weightedValue(_ p: Player, from gw: Int, to end: Int) -> Double {
        var v = 0.0, w = 1.0
        var g = gw
        while g <= end {
            v += p.projByGw.at(g) * w
            w *= decay
            g += 1
        }
        return v
    }

    enum ChipAction {
        case wildcard([Int])                     // compact indices
        case freeHit(squad: SquadResult, pts: Double)
        case tripleCaptain
        case benchBoost
    }

    struct SimResult {
        var gws: [GWPlan] = []
        var totalPts = 0.0
        var totalTransfers = 0
        var totalHits = 0
        var squadAtStart: [Int: [Int]] = [:]
        var ftsAtStart: [Int: Int] = [:]
    }

    // MARK: entry point

    static func plan(players: [Player], budgetM: Double, fitOnly: Bool,
                     from: Int, window: Int, userSquad: [Player]? = nil,
                     chipsMeta: [ChipMeta] = [], doubleGws: Set<Int> = []) -> SeasonPlan? {
        let end = min(from + window - 1, 38)
        guard end >= from else { return nil }
        let budget = Int((budgetM * 10).rounded())
        let poolPlayers = Optimizer.candidatePool(players, fitOnly: fitOnly)
        let ctx = PlanContext(players: players, pool: poolPlayers, from: from, end: end)

        var squad0: [Int]
        var fts0: Int
        let fromUser: Bool
        if let user = userSquad, user.count == 15 {
            squad0 = user.compactMap { ctx.index[$0.id] }
            fts0 = 1
            fromUser = true
        } else {
            let scored = players
                .map { $0.reprojected(weightedValue($0, from: from, to: end)) }
            guard let opening = Optimizer.optimize(players: scored, budgetM: budgetM, fitOnly: fitOnly)
            else { return nil }
            squad0 = opening.squad.compactMap { ctx.index[$0.id] }
            fts0 = 0
            fromUser = false
        }
        guard squad0.count == 15 else { return nil }

        // pass 1: base plan without chips
        let base = simulate(ctx: ctx, budget: budget, from: from, end: end,
                            initial: squad0, initialFts: fts0,
                            allowFirstMoves: fromUser, chips: [:], scoreOnly: false)

        // pass 2: schedule chips where they earn the most
        var actions: [Int: ChipAction] = [:]
        var plays: [ChipPlay] = []
        var heldChips: [String] = []
        // Free Hit gets first claim within each half so a double gameweek is
        // never taken by another chip before it can land there
        let order = ["freehit", "wildcard", "3xc", "bboost"]
        let sortedMeta = chipsMeta
            .filter { $0.stop >= from && $0.start <= end }
            .sorted {
                let h0 = $0.stop <= 19 ? 0 : 1
                let h1 = $1.stop <= 19 ? 0 : 1
                return h0 != h1 ? h0 < h1
                    : (order.firstIndex(of: $0.name) ?? 9) < (order.firstIndex(of: $1.name) ?? 9)
            }
        let basePts = Dictionary(uniqueKeysWithValues: base.gws.map { ($0.gw, $0.projPts) })

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
            let freeSet = Set(free)

            switch meta.name {
            case "3xc":
                var bestGw: Int?; var bestGain = -1.0
                for gp in base.gws where freeSet.contains(gp.gw) {
                    if gp.captain.proj > bestGain { bestGain = gp.captain.proj; bestGw = gp.gw }
                }
                if let g = bestGw {
                    actions[g] = .tripleCaptain
                    plays.append(ChipPlay(chip: "3xc", gw: g, gain: max(bestGain, 0)))
                }

            case "bboost":
                var bestGw: Int?; var bestGain = -1.0
                for gp in base.gws where freeSet.contains(gp.gw) {
                    let benchPts = gp.bench.reduce(0) { $0 + $1.proj }
                    if benchPts > bestGain { bestGain = benchPts; bestGw = gp.gw }
                }
                if let g = bestGw {
                    actions[g] = .benchBoost
                    plays.append(ChipPlay(chip: "bboost", gw: g, gain: max(bestGain, 0)))
                }

            case "freehit":
                // the Free Hit exists for double gameweeks: if any DGW is in
                // this window, it MUST go on one. With no DGW announced yet,
                // hold the chip — doubles appear mid-season, and the plan
                // re-runs on every refresh. Only if the window is about to
                // expire with no DGW does it fall back to the best normal week.
                let dgwCands = free.filter { doubleGws.contains($0) }
                let windowClosing = hi - max(lo, from) <= 3
                if dgwCands.isEmpty && !windowClosing {
                    heldChips.append("freehit")
                    continue
                }
                let searchGws = dgwCands.isEmpty ? free : dgwCands
                let cands = searchGws
                    .map { g -> (Int, Double) in
                        var top = players.map { $0.projByGw.at(g) }
                        top.sort(by: >)
                        let ceiling = top.prefix(11).reduce(0, +)
                        return (g, ceiling - (basePts[g] ?? 0))
                    }
                    .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
                    .prefix(3)
                var best: (gw: Int, pts: Double, sq: SquadResult)?
                for (g, _) in cands {
                    let scored = players.map { $0.reprojected($0.projByGw.at(g)) }
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
                    actions[b.gw] = .freeHit(squad: b.sq, pts: b.pts)
                    plays.append(ChipPlay(chip: "freehit", gw: b.gw, gain: gain))
                }

            case "wildcard":
                // try spread candidates across the window: rebuild the squad
                // there and re-simulate the rest of the season
                let candSet = Set(stride(from: lo, through: hi, by: max((hi - lo) / 4, 1)))
                    .filter { freeSet.contains($0) }
                var evals: [(gw: Int, gain: Double, squad: [Int], changes: Int)] = []
                let baseRestFrom = { (g: Int) in
                    base.gws.filter { $0.gw >= g }.reduce(0) { $0 + $1.projPts }
                }
                for g in candSet.sorted() {
                    let scored = players
                        .map { $0.reprojected(ctx.index[$0.id].map { ctx.weighted($0, g) } ?? 0) }
                    guard let nsq = Optimizer.optimize(players: scored, budgetM: budgetM, fitOnly: fitOnly,
                                                       iters: 8000, restarts: 3) else { continue }
                    let newSquad = nsq.squad.compactMap { ctx.index[$0.id] }
                    guard newSquad.count == 15 else { continue }
                    // score-only: this simulation is a comparison, not output
                    let rest = simulate(ctx: ctx, budget: budget, from: g, end: end,
                                        initial: newSquad, initialFts: base.ftsAtStart[g] ?? 1,
                                        allowFirstMoves: false, chips: [:], scoreOnly: true)
                    let heldIds = Set(base.squadAtStart[g] ?? [])
                    let changes = newSquad.filter { !heldIds.contains($0) }.count
                    evals.append((g, rest.totalPts - baseRestFrom(g), newSquad, changes))
                }
                // prefer a week where the rebuild actually changes the team,
                // as long as it's within a point of the best candidate
                let topGain = evals.map(\.gain).max() ?? 0
                let best = evals
                    .filter { $0.changes > 0 && $0.gain >= topGain - 1.0 }
                    .max { $0.gain != $1.gain ? $0.gain < $1.gain : $0.gw > $1.gw }
                    ?? evals.max { $0.gain != $1.gain ? $0.gain < $1.gain : $0.gw > $1.gw }
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
        let fin = simulate(ctx: ctx, budget: budget, from: from, end: end,
                           initial: squad0, initialFts: fts0,
                           allowFirstMoves: fromUser, chips: actions, scoreOnly: false)
        return SeasonPlan(gws: fin.gws, totalPts: fin.totalPts,
                          totalTransfers: fin.totalTransfers, totalHits: fin.totalHits,
                          fromUserSquad: fromUser,
                          chips: plays.sorted { $0.gw < $1.gw },
                          heldChips: heldChips)
    }

    // MARK: week-by-week simulation

    static func simulate(ctx: PlanContext, budget: Int, from: Int, end: Int,
                         initial: [Int], initialFts: Int, allowFirstMoves: Bool,
                         chips: [Int: ChipAction], scoreOnly: Bool) -> SimResult {
        var squad = initial
        var fts = initialFts
        var bank = max(budget - squad.reduce(0) { $0 + Int(ctx.picks[$1].cost) }, 0)
        var res = SimResult()
        var gwPicks = [Pick](repeating: ctx.picks[0], count: 15)

        for g in from...end {
            res.squadAtStart[g] = squad
            res.ftsAtStart[g] = fts
            if g > from { fts = min(fts + 1, 5) }

            var chipName: String?
            var suppressMoves = false
            var moves: [TransferMove] = []
            if let action = chips[g] {
                switch action {
                case .wildcard(let newSquad):
                    // unlimited free transfers: show exactly who comes in and
                    // out; the rebuilt squad carries forward until changed
                    if !scoreOnly {
                        let newIds = Set(newSquad), oldIds = Set(squad)
                        for pos in 1...4 {
                            let outs = squad.filter { ctx.picks[$0].pos == Int8(pos) && !newIds.contains($0) }
                            let ins = newSquad.filter { ctx.picks[$0].pos == Int8(pos) && !oldIds.contains($0) }
                            for k in 0..<min(outs.count, ins.count) {
                                moves.append(TransferMove(
                                    out: ctx.players[outs[k]], inn: ctx.players[ins[k]], paid: false,
                                    gain: ctx.proj(ins[k], g) - ctx.proj(outs[k], g)))
                            }
                        }
                    }
                    squad = newSquad
                    bank = max(budget - squad.reduce(0) { $0 + Int(ctx.picks[$1].cost) }, 0)
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

            var hitPts = 0
            if !suppressMoves && (g > from || allowFirstMoves) {
                // no artificial cap: spend every banked free transfer that
                // genuinely benefits the team; stop when no move clears the bar
                var made = 0
                while made < 12 {
                    guard let best = bestTransfer(ctx: ctx, squad: squad, bank: bank, from: g)
                    else { break }
                    let outP = ctx.players[best.out]
                    let isFree = fts > 0
                    let outInjured = outP.flagged || outP.avail < 0.75
                    let threshold = isFree
                        ? freeThreshold(ftsBanked: fts, outInjured: outInjured)
                        : (outInjured ? 4.5 : hitGainThreshold)
                    guard best.gain >= threshold else { break }
                    guard let idx = squad.firstIndex(of: best.out) else { break }
                    squad[idx] = best.inn
                    bank += Int(ctx.picks[best.out].cost) - Int(ctx.picks[best.inn].cost)
                    if isFree { fts -= 1 } else { hitPts += 4 }
                    made += 1
                    if !scoreOnly {
                        moves.append(TransferMove(out: outP, inn: ctx.players[best.inn],
                                                  paid: !isFree, gain: best.gain))
                    }
                }
            }

            // Free Hit: play the one-week dream team; squad itself unchanged
            if case .freeHit(let sq, let pts)? = chips[g] {
                if !scoreOnly {
                    res.gws.append(GWPlan(gw: g, transfers: [], xi: sq.xi, bench: sq.bench,
                                          captain: sq.captain, formation: sq.formation,
                                          projPts: pts, ftsLeft: fts, hitPts: 0, chip: chipName))
                }
                res.totalPts += pts
                continue
            }

            for (k, i) in squad.enumerated() { gwPicks[k] = ctx.pick(i, g) }
            guard let r = Optimizer.evaluate(gwPicks) else { continue }
            var pts = r.total + r.capProj - Double(hitPts)
            if case .tripleCaptain? = chips[g] { pts += r.capProj }   // ×3 total
            if case .benchBoost? = chips[g] { pts += r.benchSum }

            res.totalPts += pts
            if chipName != "wildcard" { res.totalTransfers += moves.count } // WC moves are unlimited/free
            res.totalHits += hitPts

            guard !scoreOnly else { continue }
            // materialise the display squad only for plans the user will see
            let gwSquad = squad.map { ctx.players[$0].reprojected(ctx.proj($0, g)) }
            guard let disp = Optimizer.bestXI(gwSquad) else { continue }
            let cap = disp.xi.max { $0.proj < $1.proj } ?? gwSquad[0]
            res.gws.append(GWPlan(gw: g, transfers: moves, xi: disp.xi, bench: disp.bench,
                                  captain: cap, formation: disp.formation,
                                  projPts: pts, ftsLeft: fts, hitPts: hitPts, chip: chipName))
        }
        return res
    }

    private static func bestTransfer(ctx: PlanContext, squad: [Int], bank: Int, from g: Int)
        -> (out: Int, inn: Int, gain: Double)? {
        var clubs = [Int](repeating: 0, count: 32)
        for i in squad { clubs[Int(ctx.picks[i].team)] += 1 }
        let squadSet = Set(squad)

        var best: (out: Int, inn: Int, gain: Double)?
        var bestInjured: (out: Int, inn: Int, gain: Double)?
        for out in squad {
            let outPick = ctx.picks[out]
            let outValue = ctx.weighted(out, g)
            let outPlayer = ctx.players[out]
            let outInjured = outPlayer.flagged || outPlayer.avail < 0.75
            let maxCost = Int(outPick.cost) + bank
            for inn in ctx.pool {
                let innPick = ctx.picks[inn]
                guard innPick.pos == outPick.pos, !squadSet.contains(inn),
                      Int(innPick.cost) <= maxCost else { continue }
                let clubCount = clubs[Int(innPick.team)] - (innPick.team == outPick.team ? 1 : 0)
                guard clubCount < 3 else { continue }
                let gain = ctx.weighted(inn, g) - outValue
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

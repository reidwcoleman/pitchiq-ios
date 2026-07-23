import Foundation

// MARK: - Multi-gameweek transfer planner
// Picks an opening squad optimized on decay-weighted value across the whole
// planning window (so it stays strong for coming GWs, not just the next one),
// then simulates week by week: free transfers roll (bank up to 5, FPL rules),
// a free transfer is only used when it gains meaningful points over the rest
// of the window, and a -4 hit is only taken when the gain clearly beats it.

struct TransferMove: Identifiable {
    let id = UUID()
    let out: Player
    let inn: Player
    let paid: Bool
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
    let projPts: Double        // XI + captain double, this GW only
    let ftsLeft: Int           // free transfers banked after this GW's moves
    let hitPts: Int            // points paid on hits this GW
}

struct SeasonPlan {
    let gws: [GWPlan]
    let totalPts: Double
    let totalTransfers: Int
    let totalHits: Int
}

enum Planner {
    static let freeGainThreshold = 2.0   // pts over rest-of-window to spend a FT
    static let hitGainThreshold = 6.0    // pts to justify a -4 hit (4 + margin)
    static let decay = 0.88

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

    static func plan(players: [Player], budgetM: Double, fitOnly: Bool,
                     from: Int, window: Int) -> SeasonPlan? {
        let end = min(from + window - 1, 38)
        guard end >= from else { return nil }

        // opening squad: optimize on weighted whole-window value
        let scored = players
            .map { $0.reprojected(weightedValue($0, from: from, to: end)) }
            .sorted { $0.proj > $1.proj }
        guard let opening = Optimizer.optimize(players: scored, budgetM: budgetM, fitOnly: fitOnly)
        else { return nil }

        let byId = Dictionary(uniqueKeysWithValues: players.map { ($0.id, $0) })
        var squad = opening.squad.compactMap { byId[$0.id] }
        guard squad.count == 15 else { return nil }

        let pool = Optimizer.candidatePool(players, fitOnly: fitOnly)
        var bank = Int((budgetM * 10).rounded()) - squad.reduce(0) { $0 + $1.cost }
        var fts = 1
        var plans: [GWPlan] = []
        var totalPts = 0.0, totalTransfers = 0, totalHits = 0

        for g in from...end {
            var moves: [TransferMove] = []
            var hitPts = 0

            if g > from {
                fts = min(fts + 1, 5)
                while moves.count < 2 {
                    guard let best = bestTransfer(squad: squad, pool: pool, bank: bank,
                                                  from: g, to: end) else { break }
                    let isFree = fts > 0
                    let threshold = isFree ? freeGainThreshold : hitGainThreshold
                    guard best.gain >= threshold else { break }
                    let idx = squad.firstIndex(of: best.out)!
                    squad[idx] = best.inn
                    bank += best.out.cost - best.inn.cost
                    if isFree { fts -= 1 } else { hitPts += 4 }
                    moves.append(TransferMove(out: best.out, inn: best.inn,
                                              paid: !isFree, gain: best.gain))
                }
            }

            let gwSquad = squad.map { $0.reprojected($0.projByGw[g] ?? 0) }
            guard let r = Optimizer.bestXI(gwSquad) else { return nil }
            let sorted = r.xi.sorted { $0.proj > $1.proj }
            let pts = r.total + (sorted.first?.proj ?? 0) - Double(hitPts)
            totalPts += pts
            totalTransfers += moves.count
            totalHits += hitPts

            plans.append(GWPlan(gw: g, transfers: moves, xi: r.xi, bench: r.bench,
                                captain: sorted[0], formation: r.formation,
                                projPts: pts, ftsLeft: fts, hitPts: hitPts))
        }

        return SeasonPlan(gws: plans, totalPts: totalPts,
                          totalTransfers: totalTransfers, totalHits: totalHits)
    }

    private static func bestTransfer(squad: [Player], pool: [Player], bank: Int,
                                     from g: Int, to end: Int)
        -> (out: Player, inn: Player, gain: Double)? {
        var clubs: [Int: Int] = [:]
        for p in squad { clubs[p.team, default: 0] += 1 }
        let squadIds = Set(squad.map(\.id))

        var best: (out: Player, inn: Player, gain: Double)?
        for out in squad {
            let outValue = weightedValue(out, from: g, to: end)
            for inn in pool where inn.pos == out.pos && !squadIds.contains(inn.id) {
                guard inn.cost <= out.cost + bank else { continue }
                let clubCount = clubs[inn.team, default: 0] - (inn.team == out.team ? 1 : 0)
                guard clubCount < 3 else { continue }
                let gain = weightedValue(inn, from: g, to: end) - outValue
                if best == nil || gain > best!.gain { best = (out, inn, gain) }
            }
        }
        return best
    }
}

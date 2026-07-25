import Foundation

// MARK: - Season planner
//
// Simulates the rest of the season gameweek by gameweek under the real rules —
// one free transfer a week banking to five, −4 for each extra, 2/5/5/3, max
// three per club, a fixed budget — and schedules the eight chips where each
// earns the most.
//
// What changed from the previous version, and why:
//
//   • It plans from the squad you actually own. Given an imported team it
//     starts from those fifteen, that bank and that number of free transfers,
//     and it knows which chips you have already spent. The old planner always
//     began from a squad it had invented, so its first instruction was
//     effectively "own a different team", which no amount of later advice can
//     act on.
//   • A chip is only scheduled when it gains something. The old build always
//     played every chip, and reported wildcards worth +0.0 points — an
//     instruction to burn a wildcard for nothing. Chips now have to clear a
//     threshold, except when their window is about to close, in which case
//     using one beats losing it and the plan says so.
//   • Holding a free transfer is priced instead of guessed at. A banked
//     transfer has real option value — it buys the right to react to next
//     week's news — but that value collapses at the cap of five, where an
//     unused transfer is simply lost, so the bar to spend one falls with it.
//     Injuries override the bar entirely.
//   • Every gameweek carries a one-line instruction and the reasoning behind
//     it, so the plan reads as advice rather than as output.

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
    let forced: Bool        // played only because the window was about to close
}

struct GWPlan: Identifiable {
    var id: Int { gw }
    let gw: Int
    let transfers: [TransferMove]
    let xi: [Player]           // reprojected to this gameweek's values
    let bench: [Player]
    let captain: Player
    let formation: String
    let projPts: Double        // XI + captain (+ chip effects) − hits
    let ftsLeft: Int
    let hitPts: Int
    let bank: Int              // tenths of £m
    let chip: String?
    let action: String         // the one-line instruction for this week
    let reasons: [String]
}

struct SeasonPlan {
    let gws: [GWPlan]
    let totalPts: Double
    let totalTransfers: Int
    let totalHits: Int
    let fromUserSquad: Bool
    let chips: [ChipPlay]
    let heldChips: [String]    // no week in the window is worth playing them yet

    var perGw: Double { gws.isEmpty ? 0 : totalPts / Double(gws.count) }

    /// The next gameweek the plan actually changes something. A run of "hold"
    /// weeks reads like the app has nothing to say unless you can see where the
    /// next move lands.
    var firstMoveGw: Int? {
        gws.first { !$0.transfers.isEmpty || $0.chip != nil }?.gw
    }
}

/// Everything the planner needs to know about the starting position.
struct PlanStart {
    var squadIds: [Int]?        // nil → build the opening squad from scratch
    var bank = 0                // tenths of £m
    var budget = 1000           // squad value + bank, tenths of £m
    var freeTransfers = 1
    var chipsUsed: Set<String> = []
    /// True when these fifteen are a team the user actually owns. A squad the
    /// app invented can't be "transferred out of" in the same gameweek it was
    /// invented, so first-week moves are only offered on a real team.
    var isUserTeam = true
}

// MARK: - Precomputed planning tables
//
// `weightedValue` — a player's decay-weighted points from gameweek g to the end
// of the window — was recomputed by looping over up to 38 gameweeks, inside a
// loop over every squad/pool pair, inside a loop over every gameweek: the
// hottest path in the app. Because the weights are geometric it satisfies
// W(g) = proj(g) + decay·W(g+1), so the whole table is built once by a backward
// pass and every later read is a single array index.

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
    /// Discount on each further gameweek when valuing a transfer.
    static let decay = 0.80

    /// Extra gain a move must show before it is worth taking a −4. Four points
    /// is the cost; the margin on top covers the fact that a projection made
    /// weeks out is an estimate, not a promise.
    static let hitGainThreshold = 6.0

    /// The floor under every transfer decision. A move has to add at least this
    /// much to the eleven that actually score before it is worth making at all,
    /// no matter how many free transfers are going spare.
    ///
    /// This exists because "free" is not the same as "costless". At the cap of
    /// five the transfer itself is genuinely free, and an earlier version
    /// therefore let the bar fall to zero — which meant the planner would
    /// happily swap one fourth-choice bench forward for another because the
    /// projected gain was a hundredth of a point. It also burns the transfer you
    /// would have wanted next week, and it churns a team for nothing.
    /// Swept against a full simulated season. The trade-off is sharp:
    ///
    ///     floor  transfers  ->XI  ->bench   season pts   pts per transfer
    ///     0.00          28    18      10        2164.5           +0.21
    ///     0.05          20    16       4        2163.9           +0.27
    ///     0.10           9     8       1        2161.7           +0.36
    ///     0.20           4     4       0        2159.4           +0.23
    ///     0.30           1     1       0        2158.6           +0.05
    ///
    /// (Measured at the old twelve-gameweek lookahead; the ranking of floors is
    /// unchanged at four, where the same floor now permits 29 moves.)
    ///
    /// With no floor the planner makes 28 transfers a season, ten of them on
    /// players who never leave the bench, and earns 0.21 points each for the
    /// trouble. At 0.10 it makes nine, eight of which walk straight into the
    /// eleven, and earns nearly twice as much per move for 2.8 fewer points
    /// overall — points that were being chased through model noise, since no
    /// projection is accurate to a twentieth of a point.
    static let minimumWorthwhileGain = 0.10

    /// Guard against flip-flopping: selling a player bought a week ago and
    /// buying him back the next, because a small swing flipped the ordering.
    ///
    /// Deliberately short. Selling a player whose next four fixtures are ugly
    /// and buying him back when they turn is a real strategy, not churn, so the
    /// penalty only covers immediate reversals — beyond two gameweeks a buy-back
    /// costs nothing. A six-gameweek holding period blocked exactly the rotation
    /// that makes the plan worth following, and cost points doing it.
    static let holdingPeriod = 2
    static let churnCost = 0.4

    /// What a banked free transfer is worth, and therefore the bar a move has
    /// to clear to be worth spending one.
    static func optionValue(ftsBanked: Int, outInjured: Bool) -> Double {
        if outInjured { return minimumWorthwhileGain }
        switch ftsBanked {
        case ...1: return 0.6
        case 2: return 0.4
        case 3: return 0.3
        case 4: return 0.25
        default: return minimumWorthwhileGain
        }
    }

    /// Minimum gain before a chip is worth burning. Below this, keeping it for a
    /// better week is worth more than the points on the table now.
    static func chipThreshold(_ chip: String) -> Double {
        switch chip {
        case "bboost": return 8      // a bench boost that scores 6 is a wasted chip
        case "3xc": return 5         // only the third captaincy is the gain
        case "wildcard": return 8    // a rebuild should change the season, not tidy it
        case "freehit": return 12    // the highest bar: the rarest opportunity
        default: return 5
        }
    }

    /// Median of a set of candidate weeks — the yardstick a chip week has to
    /// beat before it is worth spending the chip rather than waiting.
    static func typical(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let s = values.sorted()
        return s[s.count / 2]
    }

    // MARK: - what a player is worth for the rest of the season

    /// How the remaining gameweeks are weighted when valuing a player to hold.
    struct ValueProfile {
        let name: String
        let blurb: String
        /// Weight the furthest gameweek still carries. Never zero: a squad that
        /// is strong in August and thin in March wastes the season.
        let tail: Double
        /// How fast the near-term premium falls away.
        let decay: Double
    }

    /// Three honest ways to answer "what is this player worth to me now", from
    /// short-sighted to long-sighted. The planner builds a squad under each and
    /// keeps whichever actually scores most over a simulated season.
    static let profiles: [ValueProfile] = [
        ValueProfile(name: "Next six",
                     blurb: "weighted almost entirely on the coming fixture run",
                     tail: 0.06, decay: 0.80),
        ValueProfile(name: "Balanced",
                     blurb: "the next few gameweeks count most, but every week to GW38 counts",
                     tail: 0.38, decay: 0.82),
        ValueProfile(name: "Whole season",
                     blurb: "close to flat across all 38 — built for the long haul",
                     tail: 0.75, decay: 0.85),
    ]

    /// Value of holding a player from `gw` to the end of the season.
    ///
    /// Three things are traded off:
    ///
    ///  • **Points now.** The nearest gameweeks are the ones you are certain to
    ///    play him for, so they carry a premium.
    ///  • **Points later.** The weight decays toward `tail`, not toward zero.
    ///    The previous version used a flat 0.88 geometric decay, which put GW25
    ///    at 4% of GW1 — so "best squad" quietly meant "best squad for about
    ///    eight gameweeks", and the plan drifted every time the horizon moved.
    ///  • **Whether he will still be playing.** A projection for April is worth
    ///    what it says only if the player still starts in April. Far gameweeks
    ///    are discounted by how secure the starting place looks, which is what
    ///    separates a nailed-on starter from an equally-projected rotation risk
    ///    over a full season.
    static func seasonValue(_ p: Player, from gw: Int, to end: Int,
                            profile: ValueProfile) -> Double {
        var v = 0.0
        var near = 1.0
        let security = max(min(p.startSecurity, 1), 0)
        var g = gw
        var k = 0
        while g <= end {
            let horizonWeight = profile.tail + (1 - profile.tail) * near
            let persistence = 1 - (1 - security) * min(Double(k) / 12, 1) * 0.45
            v += p.projByGw.at(g) * horizonWeight * persistence
            near *= profile.decay
            g += 1
            k += 1
        }
        return v
    }

    /// Kept for callers that want the plain geometric weighting (transfer
    /// comparisons inside a single week, where persistence is not in question).
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

    // MARK: - choosing the opening squad by simulation

    struct OpeningSquad {
        let ids: [Int]
        let profile: String
        /// Simulated points to GW38 for every profile tried, best first.
        let trials: [(profile: String, blurb: String, points: Double, ids: [Int])]
    }

    /// Build a candidate squad under each value profile, then **simulate the
    /// rest of the season** from each and keep the one that actually scores
    /// most. The profiles are proxies; the simulation is the real objective, so
    /// rather than trusting a hand-picked discount rate the planner tries
    /// several and measures the result — transfers, chips, injuries, blanks and
    /// all — the same way the plan the user reads is scored.
    static func bestOpeningSquad(players: [Player], budgetM: Double, fitOnly: Bool,
                                 from: Int, end: Int, incumbent: [Int]?,
                                 incumbentMargin: Double) -> OpeningSquad? {
        let poolPlayers = Optimizer.candidatePool(players, fitOnly: fitOnly)
        let ctx = PlanContext(players: players, pool: poolPlayers, from: from, end: end)
        let budget = Int((budgetM * 10).rounded())

        func simulateSeason(_ ids: [Int]) -> Double? {
            let compact = ids.compactMap { ctx.index[$0] }
            guard compact.count == 15 else { return nil }
            return simulate(ctx: ctx, budget: budget, from: from, end: end,
                            initial: compact, initialFts: 0, allowFirstMoves: false,
                            chips: [:], scoreOnly: true).totalPts
        }

        var trials: [(profile: String, blurb: String, points: Double, ids: [Int])] = []
        for profile in profiles {
            let scored = players.map {
                $0.reprojected(seasonValue($0, from: from, to: end, profile: profile))
            }
            guard let sq = Optimizer.optimize(players: scored, budgetM: budgetM,
                                              fitOnly: fitOnly) else { continue }
            let ids = sq.squad.map(\.id)
            guard let pts = simulateSeason(ids) else { continue }
            trials.append((profile.name, profile.blurb, pts, ids))
        }
        guard !trials.isEmpty else { return nil }
        trials.sort { $0.points != $1.points ? $0.points > $1.points : $0.profile < $1.profile }

        // The squad already on screen is judged on exactly the same scale, and
        // keeps its place unless it is beaten by a real margin. It is added to
        // the list either way, so the comparison the decision rests on is the
        // one the user actually sees.
        var chosen = trials[0]
        if let inc = incumbent, let incPts = simulateSeason(inc) {
            let held = (profile: "Your current XV",
                        blurb: "the fifteen already on screen, scored on the same scale",
                        points: incPts, ids: inc)
            if incPts + incumbentMargin >= chosen.points { chosen = held }
            trials.insert(held, at: 0)
        }
        return OpeningSquad(ids: chosen.ids, profile: chosen.profile, trials: trials)
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

    // MARK: - entry point

    static func plan(players: [Player], fitOnly: Bool, from: Int, window: Int,
                     start: PlanStart, chipsMeta: [ChipMeta] = [],
                     doubleGws: Set<Int> = []) -> SeasonPlan? {
        let end = min(from + window - 1, 38)
        guard end >= from else { return nil }
        let budget = start.budget
        let budgetM = Double(budget) / 10
        let poolPlayers = Optimizer.candidatePool(players, fitOnly: fitOnly)
        let ctx = PlanContext(players: players, pool: poolPlayers, from: from, end: end)

        var squad0: [Int]
        var fts0: Int
        let fromUser: Bool
        if let ids = start.squadIds, ids.count == 15 {
            squad0 = ids.compactMap { ctx.index[$0] }
            fts0 = max(start.freeTransfers, 0)
            fromUser = start.isUserTeam
        } else {
            // No imported team: pick the opening squad by simulating the rest of
            // the season under several value profiles and keeping the winner.
            guard let opening = bestOpeningSquad(players: players, budgetM: budgetM,
                                                 fitOnly: fitOnly, from: from, end: end,
                                                 incumbent: nil, incumbentMargin: 0)
            else { return nil }
            squad0 = opening.ids.compactMap { ctx.index[$0] }
            fts0 = 0
            fromUser = false
        }
        guard squad0.count == 15 else { return nil }

        // pass 1: base plan with no chips — the yardstick every chip is
        // measured against
        let base = simulate(ctx: ctx, budget: budget, from: from, end: end,
                            initial: squad0, initialFts: fts0,
                            allowFirstMoves: fromUser, chips: [:], scoreOnly: false)

        // pass 2: schedule the chips
        var actions: [Int: ChipAction] = [:]
        var plays: [ChipPlay] = []
        var heldChips: [String] = []
        // Free Hit picks first inside each half so a double gameweek isn't
        // claimed by a lesser chip before it can land there.
        let order = ["freehit", "wildcard", "3xc", "bboost"]
        let available = chipsMeta.filter {
            $0.stop >= from && $0.start <= end && !start.chipsUsed.contains($0.name + "-\($0.stop)")
        }
        let sortedMeta = available.sorted {
            let h0 = $0.stop <= 19 ? 0 : 1
            let h1 = $1.stop <= 19 ? 0 : 1
            return h0 != h1 ? h0 < h1
                : (order.firstIndex(of: $0.name) ?? 9) < (order.firstIndex(of: $1.name) ?? 9)
        }
        let basePts = Dictionary(uniqueKeysWithValues: base.gws.map { ($0.gw, $0.projPts) })

        for meta in sortedMeta {
            // a transfer chip can't be played the week the plan is already
            // inventing a fresh squad
            let minGw = (meta.name == "wildcard" || meta.name == "freehit")
                ? max(meta.start, fromUser ? from : from + 1)
                : max(meta.start, from)
            let lo = minGw, hi = min(meta.stop, end)
            guard lo <= hi else { continue }
            let free = (lo...hi).filter { actions[$0] == nil }
            guard !free.isEmpty else { heldChips.append(meta.name); continue }
            let freeSet = Set(free)
            // Once the window is nearly gone, playing the chip anywhere beats
            // losing it, so the threshold falls away. Measured from *now*, not
            // from the window's own start: the plan re-runs every week, so a
            // chip that isn't worth playing in September becomes worth playing
            // as its deadline approaches, and only then.
            let closing = hi - max(lo, from) <= 3
            let bar = closing ? 0.0 : chipThreshold(meta.name)

            switch meta.name {
            case "3xc":
                // Absolute size isn't the test — every week has a captain worth
                // five or six points, so an absolute bar would burn the chip in
                // the first available gameweek. What matters is whether this
                // week stands out from a typical one, which in practice means a
                // double gameweek or a premium against a collapsing defence.
                var bestGw: Int?
                var bestGain = -1.0
                var capPts: [Double] = []
                for gp in base.gws where freeSet.contains(gp.gw) {
                    capPts.append(gp.captain.proj)
                    if gp.captain.proj > bestGain { bestGain = gp.captain.proj; bestGw = gp.gw }
                }
                let capBar = max(bar, closing ? 0 : typical(capPts) * 1.30)
                if let g = bestGw, bestGain >= capBar {
                    actions[g] = .tripleCaptain
                    plays.append(ChipPlay(chip: "3xc", gw: g, gain: max(bestGain, 0), forced: closing))
                } else {
                    heldChips.append("3xc")
                }

            case "bboost":
                var bestGw: Int?
                var bestGain = -1.0
                var benchWeeks: [Double] = []
                for gp in base.gws where freeSet.contains(gp.gw) {
                    let benchPts = gp.bench.reduce(0) { $0 + $1.proj }
                    benchWeeks.append(benchPts)
                    if benchPts > bestGain { bestGain = benchPts; bestGw = gp.gw }
                }
                let benchBar = max(bar, closing ? 0 : typical(benchWeeks) * 1.30)
                if let g = bestGw, bestGain >= benchBar {
                    actions[g] = .benchBoost
                    plays.append(ChipPlay(chip: "bboost", gw: g, gain: max(bestGain, 0), forced: closing))
                } else {
                    heldChips.append("bboost")
                }

            case "freehit":
                // The Free Hit exists for double gameweeks. With none announced
                // in the window, hold it — doubles appear mid-season when
                // postponed matches are rescheduled, and the plan re-runs on
                // every refresh.
                let dgwCands = free.filter { doubleGws.contains($0) }
                if dgwCands.isEmpty && !closing { heldChips.append("freehit"); continue }
                let searchGws = dgwCands.isEmpty ? free : dgwCands
                let cands = searchGws
                    .map { g -> (Int, Double) in
                        var top = players.map { $0.projByGw.at(g) }
                        top.sort(by: >)
                        return (g, top.prefix(11).reduce(0, +) - (basePts[g] ?? 0))
                    }
                    .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
                    .prefix(3)
                var best: (gw: Int, pts: Double, gain: Double, sq: SquadResult)?
                for (g, _) in cands {
                    let scored = players.map { $0.reprojected($0.projByGw.at(g)) }
                    guard let sq = Optimizer.optimize(players: scored, budgetM: budgetM,
                                                      fitOnly: fitOnly, exactCaptain: false)
                    else { continue }
                    let pts = sq.total + sq.captain.proj
                    let gain = pts - (basePts[g] ?? 0)
                    if best == nil || gain > best!.gain { best = (g, pts, gain, sq) }
                }
                if let b = best, b.gain >= bar {
                    actions[b.gw] = .freeHit(squad: b.sq, pts: b.pts)
                    plays.append(ChipPlay(chip: "freehit", gw: b.gw, gain: max(b.gain, 0),
                                          forced: closing))
                } else {
                    heldChips.append("freehit")
                }

            case "wildcard":
                // Try candidate weeks across the window: rebuild there, then
                // re-simulate the rest of the season from the new squad.
                let step = max((hi - lo) / 4, 1)
                let candSet = Set(stride(from: lo, through: hi, by: step))
                    .filter { freeSet.contains($0) }
                var evals: [(gw: Int, gain: Double, squad: [Int], changes: Int)] = []
                func baseRestFrom(_ g: Int) -> Double {
                    base.gws.filter { $0.gw >= g }.reduce(0) { $0 + $1.projPts }
                }
                for g in candSet.sorted() {
                    let scored = players.map {
                        $0.reprojected(ctx.index[$0.id].map { ctx.weighted($0, g) } ?? 0)
                    }
                    guard let nsq = Optimizer.optimize(players: scored, budgetM: budgetM,
                                                       fitOnly: fitOnly, exactCaptain: false)
                    else { continue }
                    let newSquad = nsq.squad.compactMap { ctx.index[$0.id] }
                    guard newSquad.count == 15 else { continue }
                    let rest = simulate(ctx: ctx, budget: budget, from: g, end: end,
                                        initial: newSquad, initialFts: base.ftsAtStart[g] ?? 1,
                                        allowFirstMoves: false, chips: [:], scoreOnly: true)
                    let heldIds = Set(base.squadAtStart[g] ?? [])
                    let changes = newSquad.filter { !heldIds.contains($0) }.count
                    evals.append((g, rest.totalPts - baseRestFrom(g), newSquad, changes))
                }
                // A wildcard that swaps two players is a wasted wildcard: those
                // moves were reachable with free transfers anyway.
                let best = evals
                    .filter { $0.changes >= 3 }
                    .max { $0.gain != $1.gain ? $0.gain < $1.gain : $0.gw > $1.gw }
                if let b = best, b.gain >= bar {
                    actions[b.gw] = .wildcard(b.squad)
                    plays.append(ChipPlay(chip: "wildcard", gw: b.gw, gain: b.gain, forced: closing))
                } else {
                    heldChips.append("wildcard")
                }

            default: break
            }
        }

        // pass 3: final simulation with the chips applied
        let fin = simulate(ctx: ctx, budget: budget, from: from, end: end,
                           initial: squad0, initialFts: fts0,
                           allowFirstMoves: fromUser, chips: actions, scoreOnly: false)
        return SeasonPlan(gws: fin.gws, totalPts: fin.totalPts,
                          totalTransfers: fin.totalTransfers, totalHits: fin.totalHits,
                          fromUserSquad: fromUser,
                          chips: plays.sorted { $0.gw < $1.gw },
                          heldChips: heldChips.sorted())
    }

    // MARK: - week-by-week simulation

    static func simulate(ctx: PlanContext, budget: Int, from: Int, end: Int,
                         initial: [Int], initialFts: Int, allowFirstMoves: Bool,
                         chips: [Int: ChipAction], scoreOnly: Bool) -> SimResult {
        var squad = initial
        var fts = initialFts
        var bank = max(budget - squad.reduce(0) { $0 + Int(ctx.picks[$1].cost) }, 0)
        var res = SimResult()
        var gwPicks = [Pick](repeating: ctx.picks[0], count: 15)
        var boughtAt: [Int: Int] = [:]
        var soldAt: [Int: Int] = [:]

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
                    if !scoreOnly {
                        let newIds = Set(newSquad), oldIds = Set(squad)
                        for pos in 1...4 {
                            // rank both sides so the list reads like-for-like;
                            // a wildcard is judged as one rebuild, so no
                            // per-move gain is quoted
                            let outs = squad.filter { ctx.picks[$0].pos == Int8(pos) && !newIds.contains($0) }
                                .sorted { ctx.proj($0, g) > ctx.proj($1, g) }
                            let ins = newSquad.filter { ctx.picks[$0].pos == Int8(pos) && !oldIds.contains($0) }
                                .sorted { ctx.proj($0, g) > ctx.proj($1, g) }
                            for k in 0..<min(outs.count, ins.count) {
                                moves.append(TransferMove(
                                    out: ctx.players[outs[k]], inn: ctx.players[ins[k]], paid: false,
                                    gain: 0))
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
            var heldFor = ""
            if !suppressMoves && (g > from || allowFirstMoves) {
                // Spend every banked free transfer whose best move clears the
                // value of holding it, then consider paying for more. Capped at
                // four moves a week — past that the plan stops being something a
                // person would actually sit down and execute.
                var made = 0
                while made < 4 {
                    guard let best = bestTransfer(ctx: ctx, squad: squad, bank: bank, from: g,
                                                  boughtAt: boughtAt, soldAt: soldAt)
                    else { break }
                    let outP = ctx.players[best.out]
                    let isFree = fts > 0
                    let outInjured = outP.flagged || outP.avail < 0.75
                    let threshold = max(
                        isFree ? optionValue(ftsBanked: fts, outInjured: outInjured)
                               : (outInjured ? 4.5 : hitGainThreshold),
                        minimumWorthwhileGain)
                    guard best.gain >= threshold else {
                        if made == 0 {
                            heldFor = isFree
                                ? String(format: "the best move available adds %.1f pts to the starting eleven, under the %.1f it needs to be worth doing",
                                         max(best.gain, 0), threshold)
                                : "no move is worth a −4"
                        }
                        break
                    }
                    guard let idx = squad.firstIndex(of: best.out) else { break }
                    squad[idx] = best.inn
                    soldAt[best.out] = g
                    boughtAt[best.inn] = g
                    bank += Int(ctx.picks[best.out].cost) - Int(ctx.picks[best.inn].cost)
                    if isFree { fts -= 1 } else { hitPts += 4 }
                    made += 1
                    if !scoreOnly {
                        moves.append(TransferMove(out: outP, inn: ctx.players[best.inn],
                                                  paid: !isFree, gain: best.gain))
                    }
                }
            }

            // Free Hit: a one-week dream team; the real squad is untouched
            if case .freeHit(let sq, let pts)? = chips[g] {
                if !scoreOnly {
                    res.gws.append(GWPlan(
                        gw: g, transfers: [], xi: sq.xi, bench: sq.bench, captain: sq.captain,
                        formation: sq.formation, projPts: pts, ftsLeft: fts, hitPts: 0,
                        bank: bank, chip: chipName,
                        action: "Play your Free Hit",
                        reasons: freeHitReasons(sq: sq, pts: pts)))
                }
                res.totalPts += pts
                continue
            }

            for (k, i) in squad.enumerated() { gwPicks[k] = ctx.pick(i, g) }
            guard let r = Optimizer.evaluate(gwPicks) else { continue }
            var pts = r.total + r.capProj - Double(hitPts)
            if case .tripleCaptain? = chips[g] { pts += r.capProj }   // ×3 in total
            if case .benchBoost? = chips[g] { pts += r.benchSum }

            res.totalPts += pts
            if chipName != "wildcard" { res.totalTransfers += moves.count }
            res.totalHits += hitPts

            guard !scoreOnly else { continue }
            let gwSquad = squad.map { ctx.players[$0].reprojected(ctx.proj($0, g)) }
            guard let disp = Optimizer.bestXI(gwSquad) else { continue }
            let cap = disp.xi.max { $0.proj < $1.proj } ?? gwSquad[0]
            res.gws.append(GWPlan(
                gw: g, transfers: moves, xi: disp.xi, bench: disp.bench, captain: cap,
                formation: disp.formation, projPts: pts, ftsLeft: fts, hitPts: hitPts,
                bank: bank, chip: chipName,
                action: actionLine(moves: moves, chip: chipName, fts: fts, hits: hitPts,
                                   captain: cap, isFirst: g == from,
                                   fromUserTeam: allowFirstMoves),
                reasons: weekReasons(moves: moves, chip: chipName, fts: fts,
                                     captain: cap, bench: disp.bench, heldFor: heldFor,
                                     bank: bank, isFirst: g == from, fromUser: allowFirstMoves)))
        }
        return res
    }

    // MARK: - narration

    private static func actionLine(moves: [TransferMove], chip: String?, fts: Int,
                                   hits: Int, captain: Player, isFirst: Bool,
                                   fromUserTeam: Bool) -> String {
        if let chip {
            switch chip {
            case "wildcard": return "Wildcard — rebuild the squad"
            case "bboost": return "Bench Boost — all 15 score"
            case "3xc": return "Triple Captain on \(captain.name)"
            default: break
            }
        }
        if moves.isEmpty {
            return isFirst
                ? (fromUserTeam ? "No change needed — captain \(captain.name)"
                                : "This XV is already the strongest available")
                : "Roll the transfer (\(fts) banked)"
        }
        let names = moves.map { "\($0.out.name) → \($0.inn.name)" }.joined(separator: ", ")
        return hits > 0 ? "\(names)  (−\(hits))" : names
    }

    private static func freeHitReasons(sq: SquadResult, pts: Double) -> [String] {
        ["This is a one-week team only. Your real squad comes straight back next gameweek, unchanged, with your free transfers intact.",
         String(format: "The eleven below project %.1f pts including the captain — that gap over what your own squad would score is what makes the chip worth spending here.", pts),
         "Captain \(sq.captain.name)."]
    }

    private static func weekReasons(moves: [TransferMove], chip: String?, fts: Int,
                                    captain: Player, bench: [Player], heldFor: String,
                                    bank: Int, isFirst: Bool, fromUser: Bool) -> [String] {
        var out: [String] = []
        if let chip {
            switch chip {
            case "wildcard":
                out.append("Unlimited free transfers this week, and the rebuilt squad is the one you keep — everything below carries forward.")
            case "bboost":
                let benchPts = bench.reduce(0) { $0 + $1.proj }
                out.append(String(format: "All four substitutes score this week: %.1f points that would otherwise sit on the bench.", benchPts))
            case "3xc":
                out.append(String(format: "%@ counts three times instead of twice — %.1f points on top of the normal captaincy.", captain.name, captain.proj))
            default: break
            }
        }
        for m in moves where chip != "wildcard" {
            var line = String(format: "%@ → %@: %+.1f points added to the starting eleven over the coming gameweeks",
                              m.out.name, m.inn.name, m.gain)
            line += m.paid ? ", enough to clear the −4." : ", using a free transfer."
            if m.out.flagged {
                line += " \(m.out.name) is flagged\(m.out.news.isEmpty ? "" : " — \(m.out.news)")."
            }
            out.append(line)
        }
        if moves.isEmpty && !isFirst && chip == nil {
            out.append(heldFor.isEmpty
                ? "Nothing on the board beats holding, so the transfer banks — \(fts) saved, and they stack to five."
                : "Hold: \(heldFor). The transfer banks (\(fts) saved).")
        }
        if isFirst && chip == nil {
            out.append(fromUser
                ? "This is your squad as it stands. Only moves that clearly add points are suggested."
                : "This fifteen was just picked as the best available, so there is nothing to transfer yet — every change would make it worse. It starts rotating as fixture runs turn.")
        }
        out.append(String(format: "Captain %@ — the highest projected scorer in the eleven at %.1f pts, doubled.",
                          captain.name, captain.proj))
        if bank >= 10 {
            out.append(String(format: "£%.1fm sitting in the bank.", Double(bank) / 10))
        }
        return out
    }

    // MARK: - transfer search

    /// How many gameweeks ahead a transfer is judged over.
    ///
    /// The right horizon is not "the rest of the season" — it is "until you
    /// would transfer again". Scoring a move over twelve gameweeks silently
    /// assumes you hold the player for twelve gameweeks, which is wrong for
    /// anyone who uses their free transfer most weeks: it averages a good run
    /// and a bad run together and concludes that nothing is worth doing. Over a
    /// six-gameweek window the fixture swing for a regular starter is only about
    /// 11%, because runs even out; over four it is sharp enough to act on.
    ///
    /// Swept against a full simulated season, holding everything else fixed:
    ///
    ///     lookahead  decay  transfers  ->XI  ->bench   season pts
    ///            12   0.88         10    10       0        2160.6
    ///             8   0.86         13    12       1        2161.5
    ///             6   0.85         32    25       7        2166.7
    ///             4   0.80         29    27       2        2169.1
    ///
    /// Four is both the most active and the highest scoring — the shorter window
    /// is not a trade-off against accuracy, it is a better model of how the team
    /// is actually managed.
    static let transferLookahead = 4

    /// The best transfer available, measured by what the squad actually scores.
    ///
    /// The gain is the change in `Optimizer.scoringValue` — best XI plus captain
    /// plus a tenth of the bench — summed over the coming gameweeks with the
    /// usual discount. It is emphatically *not* the change in the incoming
    /// player's own projection, which is what this used to measure: by that
    /// standard, replacing the fourth-choice forward who never leaves your bench
    /// with a slightly better fourth-choice forward looked exactly as valuable
    /// as the same upgrade to a starter, and the planner duly spent free
    /// transfers on players who could not score it a single point.
    private static func bestTransfer(ctx: PlanContext, squad: [Int], bank: Int, from g: Int,
                                     boughtAt: [Int: Int] = [:], soldAt: [Int: Int] = [:])
        -> (out: Int, inn: Int, gain: Double)? {
        var clubs = [Int](repeating: 0, count: 32)
        for i in squad { clubs[Int(ctx.picks[i].team)] += 1 }
        let squadSet = Set(squad)
        let last = min(g + transferLookahead - 1, ctx.end)
        guard g <= last else { return nil }
        let weeks = Array(g...last)

        // the squad as it stands, one Pick array per gameweek in the window
        var base: [[Pick]] = weeks.map { h in squad.map { ctx.pick($0, h) } }
        let baseValue = base.map { Optimizer.scoringValue($0) }

        /// Exact gain for one swap: re-score every week in the window with the
        /// replacement in place.
        func gain(slot: Int, inn: Int) -> Double {
            var total = 0.0
            var w = 1.0
            for (k, h) in weeks.enumerated() {
                let keep = base[k][slot]
                base[k][slot] = ctx.pick(inn, h)
                total += (Optimizer.scoringValue(base[k]) - baseValue[k]) * w
                base[k][slot] = keep
                w *= decay
            }
            return total
        }

        // Shortlist on the raw projection delta first — it bounds the real gain,
        // so nothing worth having is filtered out — then score the survivors
        // properly. Scoring every legal pair exactly would mean re-evaluating
        // the XI a few million times per simulated season.
        var shortlist: [(slot: Int, out: Int, inn: Int, raw: Double)] = []
        for (slot, out) in squad.enumerated() {
            let outPick = ctx.picks[out]
            let outValue = ctx.weighted(out, g)
            let maxCost = Int(outPick.cost) + bank
            var perSlot: [(Int, Double)] = []
            for inn in ctx.pool {
                let innPick = ctx.picks[inn]
                guard innPick.pos == outPick.pos, !squadSet.contains(inn),
                      Int(innPick.cost) <= maxCost else { continue }
                let clubCount = clubs[Int(innPick.team)] - (innPick.team == outPick.team ? 1 : 0)
                guard clubCount < 3 else { continue }
                perSlot.append((inn, ctx.weighted(inn, g) - outValue))
            }
            perSlot.sort { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
            for (inn, raw) in perSlot.prefix(12) {
                shortlist.append((slot, out, inn, raw))
            }
        }
        guard !shortlist.isEmpty else { return nil }

        /// Selling someone you have just bought, or buying back someone you have
        /// just sold, has to clear a much higher bar than a first-time move.
        func churn(out: Int, inn: Int) -> Double {
            var penalty = 0.0
            if let b = boughtAt[out], g - b < holdingPeriod { penalty += churnCost }
            if let sld = soldAt[inn], g - sld < holdingPeriod { penalty += churnCost }
            return penalty
        }

        var best: (out: Int, inn: Int, gain: Double)?
        var bestInjured: (out: Int, inn: Int, gain: Double)?
        for c in shortlist {
            let outPlayer = ctx.players[c.out]
            let g2 = gain(slot: c.slot, inn: c.inn) - churn(out: c.out, inn: c.inn)
            if best == nil || g2 > best!.gain { best = (c.out, c.inn, g2) }
            if outPlayer.flagged || outPlayer.avail < 0.75 {
                if bestInjured == nil || g2 > bestInjured!.gain {
                    bestInjured = (c.out, c.inn, g2)
                }
            }
        }
        // an injured player is dead weight whatever the projection says, so
        // replacing one takes priority as long as it isn't actively harmful
        if let inj = bestInjured, inj.gain > 0 { return inj }
        return best
    }
}

import Foundation

// MARK: - Decision tools
//
// The optimiser answers "what is the best possible squad". These answer the
// questions a manager actually has on a Friday night, all of them relative to
// the fifteen players they already own:
//
//   • which single transfer gains the most, and over what horizon
//   • whether a second transfer is worth −4
//   • which pair of moves works better than either move alone
//   • who to captain, and how much risk that carries
//   • who is about to change price
//   • which good players almost nobody owns
//
// Everything here is derived, deterministic and cheap: it reads the per-
// gameweek projections the engine already produced.

enum Advisor {
    /// Transfers are judged on the same window and discount the season planner
    /// uses, so the board's top move and the plan's instruction agree. See
    /// `Planner.transferLookahead` for why the window is short.
    static var decay: Double { Planner.decay }
    static var lookahead: Int { Planner.transferLookahead }

    static func weighted(_ p: Player, from gw: Int, to end: Int) -> Double {
        var v = 0.0, w = 1.0
        var g = gw
        while g <= end {
            v += p.projByGw.at(g) * w
            w *= decay
            g += 1
        }
        return v
    }

    static func window(_ p: Player, from gw: Int, count: Int) -> Double {
        var v = 0.0
        for g in gw..<(gw + count) { v += p.projByGw.at(g) }
        return v
    }

    // MARK: - transfers

    struct TransferOption: Identifiable {
        var id: String { "\(out.id)-\(inn.id)" }
        let out: Player
        let inn: Player
        let gainNext: Double        // next gameweek only
        let gainWindow: Double      // over the chosen horizon
        let gainWeighted: Double    // discounted across the lookahead window
        let spend: Int              // tenths of £m taken out of the bank
        /// Whether the outgoing player is in the current starting eleven.
        /// A move on a substitute cannot add points on a normal weekend, and
        /// saying so is more useful than hiding the row.
        let outStarts: Bool
        var reasons: [String]
    }

    struct SecondMove: Identifiable {
        var id: String { first.id + "+" + second.id }
        let first: TransferOption
        let second: TransferOption
        let totalWindowGain: Double
        let netAfterHit: Double     // window gain minus the 4-point hit
        var worthIt: Bool { netAfterHit > 0 }
    }

    struct TransferBoard {
        var options: [TransferOption] = []
        var pairs: [SecondMove] = []
        var holdReason: String = ""
        var bestSingle: TransferOption? { options.first }
    }

    /// The points a fifteen actually scores in one gameweek.
    @inline(__always)
    private static func scoring(_ picks: [Pick]) -> Double { Optimizer.scoringValue(picks) }

    /// Rank every legal single transfer out of `squad` by what it does to the
    /// points the squad actually scores.
    ///
    /// The gain of a move is the change in best XI + captain + a tenth of the
    /// bench, summed across the coming gameweeks. Measuring the change in the
    /// incoming player's own projection instead — which is what this did before
    /// — treats an upgrade to the man sitting fourth on your bench as worth the
    /// same as an upgrade to a starter. Bench points don't count unless you play
    /// Bench Boost, so those moves are worth close to nothing and now score that
    /// way.
    static func transferBoard(squad: [Player], players: [Player], from gw: Int,
                              horizon: Int, bank: Int, fitOnly: Bool,
                              limit: Int = 40) -> TransferBoard {
        guard squad.count == 15 else { return TransferBoard() }
        let end = 38
        let hi = min(gw + horizon - 1, 38)
        let last = min(gw + lookahead - 1, 38)
        let weeks = Array(gw...last)
        let ids = Set(squad.map(\.id))
        var clubs: [Int: Int] = [:]
        for p in squad { clubs[p.team, default: 0] += 1 }
        let pool = players.filter {
            !ids.contains($0.id) && (fitOnly ? !$0.flagged : $0.avail > 0.4) && $0.proj > 0
        }

        // the squad as it stands, one Pick array per gameweek in the window
        var base: [[Pick]] = weeks.map { h in squad.map { $0.pick($0.projByGw.at(h)) } }
        let baseValue = base.map { scoring($0) }
        let startingXI = Set(
            Optimizer.bestXI(squad.map { $0.reprojected($0.projByGw.at(gw)) })?.xi.map(\.id) ?? [])

        /// Gains for putting `cand` into `slot`, measured on the real objective.
        func measure(slot: Int, cand: Player) -> (next: Double, window: Double, weighted: Double) {
            var next = 0.0, win = 0.0, wtd = 0.0
            var w = 1.0
            for (k, h) in weeks.enumerated() {
                let keep = base[k][slot]
                base[k][slot] = cand.pick(cand.projByGw.at(h))
                let d = scoring(base[k]) - baseValue[k]
                base[k][slot] = keep
                if k == 0 { next = d }
                if h <= hi { win += d }
                wtd += d * w
                w *= decay
            }
            return (next, win, wtd)
        }

        var out: [TransferOption] = []
        out.reserveCapacity(limit * 2)
        for (slot, old) in squad.enumerated() {
            let maxCost = old.cost + bank
            let oldW = weighted(old, from: gw, to: end)
            // Shortlist on the raw projection delta, which bounds the true gain,
            // then score the survivors on the real objective.
            var cands: [(Player, Double)] = []
            for cand in pool where cand.pos == old.pos && cand.cost <= maxCost {
                let clubCount = clubs[cand.team, default: 0] - (cand.team == old.team ? 1 : 0)
                guard clubCount < 3 else { continue }
                cands.append((cand, weighted(cand, from: gw, to: end) - oldW))
            }
            cands.sort { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.id < $1.0.id }
            var bestForSlot: TransferOption?
            for (cand, _) in cands.prefix(14) {
                let m = measure(slot: slot, cand: cand)
                let option = TransferOption(
                    out: old, inn: cand,
                    gainNext: m.next, gainWindow: m.window, gainWeighted: m.weighted,
                    spend: cand.cost - old.cost,
                    outStarts: startingXI.contains(old.id),
                    reasons: explain(out: old, inn: cand, gw: gw, horizon: horizon))
                if bestForSlot == nil || m.weighted > bestForSlot!.gainWeighted {
                    bestForSlot = option
                }
            }
            // One row per player you could sell, showing their best replacement.
            if let o = bestForSlot { out.append(o) }
        }
        out.sort {
            $0.gainWeighted != $1.gainWeighted ? $0.gainWeighted > $1.gainWeighted
                : $0.inn.id < $1.inn.id
        }
        // A near-zero move on a substitute is not a suggestion — it swaps one
        // player who scores you nothing for another. Rows on bench players stay
        // when they genuinely gain (a good enough replacement forces its way
        // into the eleven), and are dropped when they don't.
        let ranked = Array(out.filter { $0.outStarts || $0.gainWeighted >= 0.1 }.prefix(limit))

        var board = TransferBoard(options: ranked)
        board.pairs = pairs(ranked.filter { $0.gainWeighted > 0 }, bank: bank,
                            squad: squad, weeks: Array(gw...hi), base: base, baseValue: baseValue)
        if let best = ranked.first {
            board.holdReason = best.gainWeighted < 0.8
                ? (best.gainWeighted <= 0
                   ? "No transfer improves this squad — every legal move projects to lose points off the eleven that actually score. Bank the free transfer and reassess after team news."
                   : String(format: "The best move on the board adds %.1f pts to your starting eleven. A saved free transfer is worth about that much on its own, so banking it and waiting for team news is the stronger play.", best.gainWeighted))
                : ""
        } else {
            board.holdReason = "No legal transfer improves this squad. Bank the free transfer."
        }
        return board
    }

    /// Two moves scored *together*, on the same objective. Summing two
    /// individual gains double-counts whenever both incoming players compete for
    /// the same starting place — two new midfielders can't both displace the
    /// same man.
    private static func pairs(_ options: [TransferOption], bank: Int, squad: [Player],
                              weeks: [Int], base: [[Pick]], baseValue: [Double]) -> [SecondMove] {
        guard !weeks.isEmpty else { return [] }
        var slotOf: [Int: Int] = [:]
        for (i, p) in squad.enumerated() { slotOf[p.id] = i }
        var scratch = base
        var out: [SecondMove] = []
        for (i, a) in options.prefix(12).enumerated() {
            for b in options.prefix(12).dropFirst(i + 1) {
                guard a.out.id != b.out.id, a.inn.id != b.inn.id,
                      let sa = slotOf[a.out.id], let sb = slotOf[b.out.id],
                      a.spend + b.spend <= bank else { continue }
                // the max-three rule has to hold for the pair, not just each move
                var clubs: [Int: Int] = [:]
                for p in squad where p.id != a.out.id && p.id != b.out.id {
                    clubs[p.team, default: 0] += 1
                }
                clubs[a.inn.team, default: 0] += 1
                clubs[b.inn.team, default: 0] += 1
                guard clubs.values.allSatisfy({ $0 <= 3 }) else { continue }

                var total = 0.0
                for (k, h) in weeks.enumerated() where k < scratch.count {
                    let ka = scratch[k][sa], kb = scratch[k][sb]
                    scratch[k][sa] = a.inn.pick(a.inn.projByGw.at(h))
                    scratch[k][sb] = b.inn.pick(b.inn.projByGw.at(h))
                    total += Optimizer.scoringValue(scratch[k]) - baseValue[k]
                    scratch[k][sa] = ka
                    scratch[k][sb] = kb
                }
                out.append(SecondMove(first: a, second: b, totalWindowGain: total,
                                      netAfterHit: total - 4))
            }
        }
        return out
            .sorted { $0.totalWindowGain != $1.totalWindowGain
                ? $0.totalWindowGain > $1.totalWindowGain : $0.id < $1.id }
            .prefix(6)
            .map { $0 }
    }

    /// Average fixture difficulty over the next `n` gameweeks.
    private static func runDifficulty(_ p: Player, from gw: Int, _ n: Int) -> Double? {
        let fx = p.fixtures.prefix(n)
        guard !fx.isEmpty else { return nil }
        return Double(fx.reduce(0) { $0 + $1.diff }) / Double(fx.count)
    }

    private static func explain(out old: Player, inn: Player, gw: Int, horizon: Int) -> [String] {
        var r: [String] = []

        // why the outgoing player is the one to lose
        if old.flagged && !old.news.isEmpty { r.append("\(old.name): \(old.news)") }
        else if old.flagged { r.append("\(old.name) is flagged and projected near zero.") }
        if old.formMult < 0.92 {
            r.append(String(format: "%@ is out of form — scoring %.0f%% below his own season level, which the model applies to his goals, assists and bonus.",
                            old.name, (1 - old.formMult) * 100))
        }
        if old.startRate < 0.55 && old.mins > 0 {
            r.append(String(format: "%@ started only %.0f%% of matches — the minutes aren't secure.",
                            old.name, old.startRate * 100))
        }

        // the fixture argument, which is usually the real one
        let n = Planner.transferLookahead
        if let a = runDifficulty(inn, from: gw, n), let b = runDifficulty(old, from: gw, n) {
            if a + 0.4 < b {
                r.append(String(format: "Fixtures: %@ averages %.1f difficulty over the next %d, against %.1f for %@.",
                                inn.name, a, n, b, old.name))
            } else if b + 0.4 < a {
                r.append(String(format: "%@ has the harder run on paper (%.1f against %.1f) — this move is on form and underlying numbers, not fixtures.",
                                inn.name, a, b))
            }
        }
        if inn.formMult > 1.08 {
            r.append(String(format: "%@ is in form: %.0f%% above his season level.",
                            inn.name, (inn.formMult - 1) * 100))
        }
        if inn.penTaker && !old.penTaker { r.append("\(inn.name) is on penalties.") }
        if inn.setPieces && !old.setPieces { r.append("\(inn.name) takes set pieces.") }
        if inn.own < 8 && inn.proj > old.proj {
            r.append(String(format: "Differential: %.1f%% owned.", inn.own))
        }
        if inn.cost < old.cost {
            r.append(String(format: "Frees £%.1fm for elsewhere.", Double(old.cost - inn.cost) / 10))
        }
        if r.isEmpty {
            r.append(String(format: "%@ simply projects higher over the coming run: %.1f against %.1f.",
                            inn.name, inn.proj, old.proj))
        }
        r.append("You can move back the other way when the runs swing — a buy-back costs nothing after two gameweeks.")
        return r
    }

    // MARK: - captaincy

    struct CaptainPick: Identifiable {
        var id: Int { player.id }
        let player: Player
        let expected: Double        // projected points this gameweek
        let ceiling: Double         // 90th-percentile score
        let haulProb: Double        // P(10+)
        let blankProb: Double       // P(2 or fewer)
        let effectiveOwnership: Double
        var risk: String {
            if blankProb > 0.45 { return "Boom or bust" }
            if blankProb > 0.30 { return "Balanced" }
            return "Steady"
        }
    }

    /// Captain candidates from a specific fifteen, or from the whole league when
    /// no squad has been imported.
    static func captainBoard(squad: [Player]?, players: [Player], gw: Int,
                             limit: Int = 12) -> [CaptainPick] {
        let source: [Player] = (squad?.isEmpty == false) ? squad! : players
        var ranked = source.filter { !$0.flagged && $0.projByGw.at(gw) > 0 }
        ranked.sort {
            let a = $0.projByGw.at(gw), b = $1.projByGw.at(gw)
            return a != b ? a > b : $0.id < $1.id
        }
        // Effective ownership = the share of the field a player represents once
        // captaincy is counted, since a captained player counts twice. The
        // fraction of *owners* who captain a player falls away steeply beyond
        // the obvious pick, so it is keyed off the projection ranking rather
        // than scaled off ownership itself — the previous form quietly doubled
        // every popular player and reported 96% for a 48%-owned midfielder.
        let captainShare = [0.55, 0.18, 0.09, 0.05, 0.03]
        var out: [CaptainPick] = []
        out.reserveCapacity(min(ranked.count, limit))
        for (i, p) in ranked.prefix(limit).enumerated() {
            let share = i < captainShare.count ? captainShare[i] : 0.02
            out.append(CaptainPick(player: p, expected: p.projByGw.at(gw), ceiling: p.ceiling,
                                   haulProb: p.haulProb, blankProb: p.blankProb,
                                   effectiveOwnership: p.own * (1 + share)))
        }
        return out
    }

    // MARK: - market

    enum PriceDirection { case rising, falling, steady }

    struct PriceMove: Identifiable {
        var id: Int { player.id }
        let player: Player
        let direction: PriceDirection
        let progress: Double        // 0…1 toward the change
        var label: String {
            switch direction {
            case .rising: return "Rising"
            case .falling: return "Falling"
            case .steady: return "Steady"
            }
        }
    }

    /// Players closest to a price change tonight. FPL moves a price once net
    /// transfers pass a threshold proportional to the size of the game, so the
    /// ranking is by how far through that threshold a player is.
    static func priceWatch(_ players: [Player], limit: Int = 10) -> (rising: [PriceMove], falling: [PriceMove]) {
        let moves = players.filter { abs($0.priceMomentum) > 0.08 }
        let rising = moves.filter { $0.priceMomentum > 0 }
            .sorted { $0.priceMomentum != $1.priceMomentum
                ? $0.priceMomentum > $1.priceMomentum : $0.id < $1.id }
            .prefix(limit)
            .map { PriceMove(player: $0, direction: .rising, progress: min($0.priceMomentum, 1)) }
        let falling = moves.filter { $0.priceMomentum < 0 }
            .sorted { $0.priceMomentum != $1.priceMomentum
                ? $0.priceMomentum < $1.priceMomentum : $0.id < $1.id }
            .prefix(limit)
            .map { PriceMove(player: $0, direction: .falling, progress: min(-$0.priceMomentum, 1)) }
        return (Array(rising), Array(falling))
    }

    // MARK: - differentials and template

    struct Differential: Identifiable {
        var id: Int { player.id }
        let player: Player
        let rank: Int               // projection rank within their position
        let edge: Double            // projection above the position's median owner
    }

    /// Players who project like a top pick but almost nobody owns. Ranked by
    /// projection first — a differential nobody owns for good reason is not an
    /// opportunity.
    static func differentials(_ players: [Player], maxOwnership: Double = 8,
                              limit: Int = 15) -> [Differential] {
        var out: [Differential] = []
        for pos in 1...4 {
            let byPos = players.filter { $0.pos == pos && !$0.flagged && $0.proj > 0 }
                .sorted { $0.proj != $1.proj ? $0.proj > $1.proj : $0.id < $1.id }
            guard byPos.count > 8 else { continue }
            let median = byPos[min(byPos.count / 4, byPos.count - 1)].proj
            for (i, p) in byPos.enumerated() where p.own <= maxOwnership && p.proj > median {
                out.append(Differential(player: p, rank: i + 1, edge: p.proj - median))
            }
        }
        return out
            .sorted { $0.player.proj != $1.player.proj
                ? $0.player.proj > $1.player.proj : $0.id < $1.id }
            .prefix(limit)
            .map { $0 }
    }

    /// The players so widely owned that not owning them is itself a risk.
    static func template(_ players: [Player], threshold: Double = 25, limit: Int = 12) -> [Player] {
        players.filter { $0.own >= threshold && !$0.flagged }
            .sorted { $0.own != $1.own ? $0.own > $1.own : $0.id < $1.id }
            .prefix(limit)
            .map { $0 }
    }

    /// Best points per £m — where the squad's budget is working hardest, and
    /// where it isn't.
    static func valuePicks(_ players: [Player], limit: Int = 15) -> [Player] {
        players.filter { !$0.flagged && $0.proj > 0 && $0.startRate > 0.4 }
            .sorted { $0.valueScore != $1.valueScore
                ? $0.valueScore > $1.valueScore : $0.id < $1.id }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: - squad health

    struct SquadCheck: Identifiable {
        var id: String { title }
        let title: String
        let detail: String
        let severity: Int       // 2 = act now, 1 = worth watching, 0 = fine
    }

    /// A read on the fifteen the user holds: injuries, dead weight, fixture
    /// congestion by club, bench strength, and whether the budget is stranded.
    static func audit(squad: [Player], gw: Int, bank: Int, players: [Player]) -> [SquadCheck] {
        guard squad.count == 15 else { return [] }
        var out: [SquadCheck] = []

        let injured = squad.filter { $0.flagged }
        if !injured.isEmpty {
            out.append(SquadCheck(
                title: "\(injured.count) flagged player\(injured.count > 1 ? "s" : "")",
                detail: injured.map { "\($0.name) — \($0.news.isEmpty ? "doubtful" : $0.news)" }
                    .joined(separator: "\n"),
                severity: 2))
        }

        let benchWarmers = squad.filter { !$0.flagged && $0.startRate < 0.4 && $0.cost >= 50 }
        if !benchWarmers.isEmpty {
            out.append(SquadCheck(
                title: "Paying for players who don't start",
                detail: benchWarmers.map {
                    String(format: "%@ (£%@m) starts %.0f%% of matches", $0.name, $0.price, $0.startRate * 100)
                }.joined(separator: "\n"),
                severity: 1))
        }

        var clubs: [String: Int] = [:]
        for p in squad { clubs[p.teamShort, default: 0] += 1 }
        let tripled = clubs.filter { $0.value >= 3 }.keys.sorted()
        if !tripled.isEmpty {
            out.append(SquadCheck(
                title: "Triple-ups: \(tripled.joined(separator: ", "))",
                detail: "Three players from one club means one bad week hits three of your starters at once, and you can't add a fourth.",
                severity: 0))
        }

        let blanks = squad.filter { $0.projByGw.at(gw) <= 0.05 }
        if !blanks.isEmpty {
            out.append(SquadCheck(
                title: "\(blanks.count) player\(blanks.count > 1 ? "s have" : " has") no fixture in GW \(gw)",
                detail: blanks.map(\.name).joined(separator: ", "),
                severity: blanks.count >= 4 ? 2 : 1))
        }

        if bank >= 15 {
            let best = players.filter { p in !squad.contains { $0.id == p.id } }
                .max { $0.proj < $1.proj }
            out.append(SquadCheck(
                title: String(format: "£%.1fm sitting in the bank", Double(bank) / 10),
                detail: best.map { "Idle money scores nothing. \($0.name) at £\($0.price)m is the strongest player you could reach." }
                    ?? "Idle money scores nothing.",
                severity: 1))
        }

        if let r = Optimizer.bestXI(squad.map { $0.reprojected($0.projByGw.at(gw)) }) {
            let benchPts = r.bench.dropFirst().reduce(0) { $0 + $1.proj }   // outfield bench
            if benchPts < 2.5 {
                out.append(SquadCheck(
                    title: "Thin bench",
                    detail: String(format: "Your three outfield substitutes project %.1f pts between them. That's fine week to week, but it makes Bench Boost close to worthless and leaves nothing to cover a late injury.", benchPts),
                    severity: 1))
            }
        }
        return out.sorted { $0.severity > $1.severity }
    }
}

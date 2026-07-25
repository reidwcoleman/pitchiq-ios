import Foundation

// MARK: - Poisson helpers

enum Poisson {
    /// P(X = 0)
    @inline(__always)
    static func zero(_ lambda: Double) -> Double { exp(-lambda) }

    /// E[floor(X / 2)] — the FPL "1 point lost per 2 goals conceded" rule.
    /// Summed exactly rather than approximated by λ/2, which overstates the
    /// penalty at the low λ values that matter most for premium defences.
    static func halfConceded(_ lambda: Double) -> Double {
        var p = exp(-lambda)
        var total = 0.0
        var k = 0
        while k <= 14 {
            total += Double(k / 2) * p
            k += 1
            p *= lambda / Double(k)
        }
        return total
    }

    /// E[floor(X / d)] — FPL awards save points in whole blocks of three per
    /// match, so the linear saves/3 the old model used systematically paid
    /// keepers for remainders the game throws away (~0.2 pts a game).
    static func expectedFloorDiv(_ lambda: Double, _ d: Int) -> Double {
        guard lambda > 0.01 else { return 0 }
        var p = exp(-lambda)
        var total = 0.0
        var k = 0
        let limit = Int(lambda * 4) + 12
        while k <= limit {
            total += Double(k / d) * p
            k += 1
            p *= lambda / Double(k)
        }
        return total
    }

    /// P(X >= threshold) — used for defensive-contribution counts.
    static func atLeast(_ threshold: Int, _ lambda: Double) -> Double {
        guard lambda > 0, threshold > 0 else { return 0 }
        var p = exp(-lambda)
        var cdf = p
        var k = 1
        while k < threshold {
            p *= lambda / Double(k)
            cdf += p
            k += 1
        }
        return max(0, min(1, 1 - cdf))
    }
}

/// Goals against are over-dispersed relative to Poisson: real matches produce
/// both more shut-outs *and* more three-goal hidings than a Poisson with the
/// same mean. Modelling clean sheets as Poisson under-counted them by ~15% and
/// under-counted the concession penalty by a similar margin — measured against
/// last season's actual clean-sheet and goals-conceded totals. A negative
/// binomial with variance = 1.2λ reproduces both tails.
enum GoalsAgainst {
    private static let phi = 0.2       // variance inflation over Poisson

    /// P(no goals conceded).
    static func cleanSheet(_ lambda: Double) -> Double {
        guard lambda > 0.01 else { return 1 }
        let r = lambda / phi
        return pow(r / (r + lambda), r)
    }

    /// E[floor(goals / 2)] — the "1 point lost per 2 conceded" rule.
    static func halfConceded(_ lambda: Double) -> Double {
        guard lambda > 0.01 else { return 0 }
        let r = lambda / phi
        let p = r / (r + lambda)
        var pmf = pow(p, r)
        var total = 0.0
        var k = 0
        while k <= 14 {
            total += Double(k / 2) * pmf
            pmf *= (r + Double(k)) / Double(k + 1) * (1 - p)
            k += 1
        }
        return total
    }
}

// MARK: - Team ratings
// Attack and defence expressed as expected goals per match on neutral ground,
// shrunk toward the league mean by how much data the club actually has. This
// replaces bucketed FDR multipliers as the primary fixture signal — FDR is a
// coarse 1-5 scale that can't tell a good defence from a great one, and it is
// kept only as a stabiliser (and as the sole signal for promoted clubs).

struct TeamRatings {
    static let leagueGoals = 1.42     // goals per team per match, long-run PL average
    static let homeAtk = 1.10         // home advantage on goals scored
    static let awayAtk = 0.92

    var attack: [Double]              // indexed by team id
    var defence: [Double]

    init(boot: Bootstrap, statGames: Int) {
        let n = (boot.teams.map(\.id).max() ?? 20) + 1
        attack = Array(repeating: Self.leagueGoals, count: n)
        defence = Array(repeating: Self.leagueGoals, count: n)
        let games = Double(max(statGames, 1))

        var squadXG = [Double](repeating: 0, count: n)
        var squadMins = [Double](repeating: 0, count: n)
        var gkXgcWeighted = [Double](repeating: 0, count: n)
        var gkMins = [Double](repeating: 0, count: n)

        for p in boot.elements {
            guard p.team < n else { continue }
            squadXG[p.team] += Double(p.expected_goals ?? "") ?? 0
            squadMins[p.team] += Double(p.minutes)
            if p.element_type == 1, p.minutes > 0 {
                let x90 = p.expected_goals_conceded_per_90
                    ?? ((Double(p.expected_goals_conceded ?? "") ?? 0) / Double(p.minutes) * 90)
                gkXgcWeighted[p.team] += x90 * Double(p.minutes)
                gkMins[p.team] += Double(p.minutes)
            }
        }

        for t in boot.teams {
            let id = t.id
            guard id < n else { continue }

            // Attack: squad xG per match, credibility-weighted against a prior
            // seeded from the club's overall strength rating when one exists.
            let rawAtk = squadXG[id] / games
            let wAtk = min(squadMins[id] / (games * 990), 1)          // 11 × 90 min per match
            let atkPrior = Self.prior(strength: t.strength_overall_home, attacking: true)
            attack[id] = wAtk * rawAtk + (1 - wAtk) * atkPrior

            // Defence: minutes-weighted keeper xGC/90.
            let rawDef = gkMins[id] > 0 ? gkXgcWeighted[id] / gkMins[id] : Self.leagueGoals
            let wDef = min(gkMins[id] / (games * 90), 1)
            let defPrior = Self.prior(strength: t.strength_overall_away, attacking: false)
            defence[id] = wDef * rawDef + (1 - wDef) * defPrior
        }

        // Re-centre so the league averages sit on the true mean; keeps the
        // multiplicative fixture model unbiased even when a few clubs have
        // no data at all.
        recentre(&attack, ids: boot.teams.map(\.id))
        recentre(&defence, ids: boot.teams.map(\.id))
    }

    /// Prior for a club with little or no data. Promoted sides (no strength
    /// rating yet) score less and concede more than the league average.
    private static func prior(strength: Int?, attacking: Bool) -> Double {
        guard let s = strength, s > 0 else {
            return attacking ? leagueGoals * 0.82 : leagueGoals * 1.22
        }
        // FPL publishes 1 (weakest) … 5 (strongest).
        let scale = 1.0 + (Double(s) - 3.0) * (attacking ? 0.13 : -0.13)
        return leagueGoals * scale
    }

    private func recentre(_ v: inout [Double], ids: [Int]) {
        let vals = ids.compactMap { $0 < v.count ? v[$0] : nil }
        guard !vals.isEmpty else { return }
        let mean = vals.reduce(0, +) / Double(vals.count)
        guard mean > 0.01 else { return }
        let k = Self.leagueGoals / mean
        for i in ids where i < v.count { v[i] = max(v[i] * k, 0.25) }
    }
}

// MARK: - Per-fixture context
// Everything about a fixture that does not depend on which player we are
// projecting is computed once, here. Previously each of ~560 players re-derived
// clean-sheet and concession maths for each of 38 gameweeks; now ~760
// fixture-views are evaluated once and every player reads the result.

struct FixtureContext {
    let opp: Int
    let home: Bool
    let diff: Int
    let atkScale: Double      // multiplier on attacking output vs. a neutral game
    let csProb: Double        // P(clean sheet)
    let concedePen: Double    // expected points lost to goals conceded
    let savesScale: Double    // keepers face more shots against better attacks
    let histMult: Double      // fixture multiplier applied to history-based terms

    var info: FixtureInfo { FixtureInfo(opp: opp, home: home, diff: diff) }
}

// MARK: - Projection model
//
// Per fixture we build an expected-points total from FPL's actual scoring rules:
//
//   appearance   P(play) + P(60')
//   goals        xG/90 blended with finishing, scaled by fixture, × position value
//   assists      xA/90 blended with actual assists, set-piece duty applied
//   clean sheet  Poisson P(0 goals against) from the ratings model × P(60')
//   conceded     exact E[floor(goals/2)] for GK/DEF
//   saves        saves/90 scaled by opponent attack strength
//   def. contrib P(CBIT ≥ 10 | CBIRT ≥ 12) × 2  — the 2025/26 scoring rule
//   cards        yellow/red rates
//   bonus        historical bonus/90 blended with BPS rate, fixture-scaled
//
// That model is then blended with the player's own scoring history (PPG and
// form) and with FPL's `ep_next`, weighted by a smooth credibility term rather
// than the hard minute cliffs the old model used.

/// One player's rate profile, derived once from their season stats. Split out
/// from the projection itself so the same code path serves both the numbers the
/// app ships and the per-component breakdown used to calibrate the model.
struct PlayerRates {
    var pos = 0
    var goalPts90 = 0.0
    var assistPts90 = 0.0
    var saves90 = 0.0
    var defconPts = 0.0
    var bonusRate = 0.0
    var cardPts = 0.0
    var pPlay = 0.0
    var p60 = 0.0
    var minShare = 0.0
    var ppg = 0.0
    var form = 0.0
    var epNext = 0.0
    var avail = 1.0
    var cred = 0.0        // trust in this player's own rate estimates
    var epWeight = 0.0    // reliance on FPL's cold-start estimate
    var formMult = 1.0    // recent form as a multiplier on attacking output
    var startSecurity = 0.0   // how safe the starting place looks, 0…1
    var defScale = 1.0    // this player's own concession rate vs his team's

    struct Components {
        var appearance = 0.0
        var goals = 0.0
        var assists = 0.0
        var cleanSheet = 0.0
        var conceded = 0.0
        var saves = 0.0
        var defcon = 0.0
        var bonus = 0.0
        var cards = 0.0
        var anchor = 0.0
        var ep = 0.0
        var final = 0.0
        var model: Double {
            appearance + goals + assists + cleanSheet + conceded + saves + defcon + bonus + cards
        }
    }

    func components(_ fx: FixtureContext) -> Components {
        var c = Components()
        c.appearance = pPlay + p60
        c.goals = goalPts90 * minShare * fx.atkScale
        c.assists = assistPts90 * minShare * fx.atkScale
        c.cleanSheet = ProjectionEngine.csPts[pos]
            * (defScale == 1 ? fx.csProb : pow(fx.csProb, defScale)) * p60
        c.conceded = pos <= 2 ? -fx.concedePen * defScale * minShare : 0
        c.saves = pos == 1
            ? Poisson.expectedFloorDiv(saves90 * minShare * fx.savesScale, 3) : 0
        c.defcon = defconPts
        c.bonus = bonusRate * minShare * (0.55 + 0.45 * fx.atkScale)
        c.cards = cardPts * minShare

        // History anchor: PPG carries the things the model can't see (role,
        // team quality, referee luck), form carries recency. PPG is points per
        // *appearance*, so scaling by P(play) converts it to points per
        // gameweek — the unit everything else in this model uses.
        let hist = ppg * fx.histMult * max(pPlay, 0.3)
        // form also scales the rate model above, so its share here is smaller
        // than it was when the anchor was the only place it appeared
        c.anchor = form > 0 ? 0.72 * hist + 0.28 * form * fx.histMult : hist
        c.ep = epNext * fx.histMult

        let blended = 0.62 * c.model + 0.38 * c.anchor
        // Smooth handoff to FPL's own estimate for thin-data players instead of
        // a hard cliff at 700 minutes, which made projections jump
        // discontinuously as minutes accumulated. `epWeight` is deliberately a
        // faster-saturating term than `cred`: rate estimates need a lot of
        // minutes to stabilise, but a player with ten full matches behind them
        // no longer needs FPL's cold-start estimate at all — leaving it in was
        // taxing every established player by ~10%.
        c.final = max((epWeight * (0.35 * blended + 0.65 * c.ep)
                       + (1 - epWeight) * blended) * avail, 0)
        return c
    }

    @inline(__always)
    func project(_ fx: FixtureContext) -> Double { components(fx).final }
}

struct ProjectionEngine {
    let boot: Bootstrap
    let fixtures: [APIFixture]
    let gwFrom: Int
    let horizon: Int
    let statGames: Int
    let seasonUnderway: Bool
    private let ratings: TeamRatings
    private let ctx: [[[FixtureContext]]]        // team → gw → fixtures

    // FPL scoring
    static let goalPts: [Double] = [0, 6, 6, 5, 4]
    static let csPts: [Double] = [0, 4, 4, 1, 0]
    static let defconThreshold = [0, 99, 10, 12, 12]   // GK have no DefCon route

    // FDR stabilisers (index = difficulty 1…5). The old model omitted 1
    // entirely, so the easiest fixtures were silently scored as neutral.
    private static let atkMult: [Double] = [1, 1.34, 1.19, 1.0, 0.86, 0.73]
    private static let lambdaMult: [Double] = [1, 0.62, 0.77, 1.0, 1.26, 1.52]
    private static let histMultTable: [Double] = [1, 1.20, 1.12, 1.0, 0.90, 0.80]

    // Positional priors used to shrink thin samples toward something sane.
    private static let xgPrior: [Double] = [0, 0.005, 0.055, 0.13, 0.30]
    private static let xaPrior: [Double] = [0, 0.01, 0.07, 0.13, 0.11]
    private static let dcPrior: [Double] = [0, 0, 7.4, 5.2, 2.4]
    /// Expected defensive-contribution points per gameweek for a regular
    /// starter, by position, used only while the CBIT/CBIRT feed is empty.
    /// Measured: reconstructing last season's points from every other scoring
    /// rule leaves exactly this much unexplained for defenders and midfielders,
    /// and nothing for keepers and forwards. (Derived only from the components
    /// that reconstruct exactly — goals, assists, clean sheets, bonus, cards
    /// and appearances. Season totals cannot be used for conceded or saves,
    /// whose points are floored per match rather than per season.)
    private static let dcBasePts: [Double] = [0, 0, 0.46, 0.26, 0.02]
    private static let bonusPrior: [Double] = [0, 0.14, 0.14, 0.18, 0.28]
    private static let xaToAssist: [Double] = [1, 1.2, 1.32, 1.18, 1.35]
    private static let xgToGoal: [Double] = [1, 1.0, 0.92, 1.02, 1.0]

    // Independent measurement channels, fitted by least squares through the
    // origin against every player with 900+ minutes in the source data. FPL's
    // threat, creativity and BPS indices are built from different inputs than
    // the xG model — shot location and volume, chances created, and the full
    // bonus rubric — so they carry information the expected-goals feed does not,
    // and they correlate strongly enough to be worth blending in:
    //
    //   threat/90     → xG/90     r = 0.77 (DEF)  0.83 (MID)  0.78 (FWD)
    //   creativity/90 → xA/90     r = 0.86        0.88        0.73
    //   bps/90        → bonus/90  r = 0.65        0.72        0.88
    //
    // Each coefficient reproduces the observed mean by construction, so folding
    // them in shifts individual players without moving the population.
    private static let threatToXg: [Double] = [0, 0, 0.00818, 0.01016, 0.01363]
    private static let creativityToXa: [Double] = [0, 0, 0.00632, 0.00643, 0.00551]
    private static let bpsToBonus: [Double] = [0, 0, 0.01735, 0.01880, 0.03542]

    init(boot: Bootstrap, fixtures: [APIFixture], gwFrom: Int, horizon: Int) {
        self.boot = boot
        self.fixtures = fixtures
        self.gwFrom = gwFrom
        self.horizon = horizon
        let played = boot.events.filter(\.finished).count
        // Pre-season: the API still carries last season's totals over 38 games.
        self.statGames = played > 0 ? played : 38
        // Form is a 30-day rolling average, so it reads 0.0 for every player
        // until matches are played. Applying it in pre-season would zero the
        // whole league.
        self.seasonUnderway = played > 0
        let r = TeamRatings(boot: boot, statGames: statGames)
        self.ratings = r

        let nTeams = (boot.teams.map(\.id).max() ?? 20) + 1
        var map = [[[FixtureContext]]](repeating: [[FixtureContext]](repeating: [], count: 40),
                                       count: nTeams)
        let lg = TeamRatings.leagueGoals
        for f in fixtures {
            guard let gw = f.event, gw >= 1, gw < 40,
                  f.team_h < nTeams, f.team_a < nTeams else { continue }

            for home in [true, false] {
                let me = home ? f.team_h : f.team_a
                let opp = home ? f.team_a : f.team_h
                let diff = (home ? f.team_h_difficulty : f.team_a_difficulty) ?? 3
                let d = min(max(diff, 1), 5)

                // Multiplicative ratings model, blended with the FDR bucket.
                let lean = home ? TeamRatings.homeAtk : TeamRatings.awayAtk
                let oppLean = home ? TeamRatings.awayAtk : TeamRatings.homeAtk
                let lamFor = r.attack[me] * (r.defence[opp] / lg) * lean
                let lamAgModel = r.attack[opp] * (r.defence[me] / lg) * oppLean
                let lamAg = max(0.72 * lamAgModel + 0.28 * (lg * Self.lambdaMult[d]), 0.15)

                let scaleModel = lamFor / max(r.attack[me], 0.35)
                let atkScale = 0.72 * scaleModel + 0.28 * Self.atkMult[d]

                map[me][gw].append(FixtureContext(
                    opp: opp, home: home, diff: d,
                    atkScale: max(atkScale, 0.25),
                    csProb: GoalsAgainst.cleanSheet(lamAg),
                    concedePen: GoalsAgainst.halfConceded(lamAg),
                    savesScale: max(min(lamAg / lg, 1.9), 0.45),
                    histMult: 0.6 * Self.histMultTable[d] + 0.4 * min(max(atkScale, 0.6), 1.5)
                ))
            }
        }
        self.ctx = map
    }

    // MARK: fixture lookups

    func contexts(_ teamId: Int, gw: Int) -> [FixtureContext] {
        guard teamId >= 0, teamId < ctx.count, gw >= 1, gw < 40 else { return [] }
        return ctx[teamId][gw]
    }

    func teamFixtures(_ teamId: Int, gw: Int) -> [FixtureInfo] {
        contexts(teamId, gw: gw).map(\.info)
    }

    func horizonFixtures(_ teamId: Int) -> [FixtureInfo] {
        (gwFrom..<min(gwFrom + horizon, 39)).flatMap { teamFixtures(teamId, gw: $0) }
    }

    // MARK: player projections

    /// Derive a player's rate profile from their season stats.
    func rates(for p: FPLElement) -> PlayerRates {
        var r = PlayerRates()
        let games = Double(statGames)
        let pos = min(max(p.element_type, 1), 4)
        let mins = Double(p.minutes)
        let starts = Double(p.starts ?? 0)
        r.pos = pos

        // ---- credibility: how much to trust this player's own numbers
        let cred = mins / (mins + 540)          // ~6 full matches → 50%
        r.cred = cred
        r.epWeight = 1 - min(mins / 900, 1)     // gone by ~10 full matches

        // ---- minutes model
        // The old model used minutes/38 regardless of how many gameweeks had
        // been played, and ignored `starts` entirely — so a nailed-on starter
        // and a busy substitute with the same minutes looked identical. Starts
        // are the strongest available minutes signal.
        // Appearances split into starts plus bench cameos. The cameo rate is
        // modelled as P(appears | doesn't start) rather than inferred from
        // leftover minutes: residual-minute models break down because minutes
        // per start vary far more between players than the cameo rate does.
        // Fitted against true appearance counts (recoverable exactly as
        // total_points / points_per_game) across three minutes bands, this
        // form lands within ~1.5% at every level of squad status.
        let startRate = min(starts / games, 1)
        let mpg = min(mins / games, 90)
        let cameoOdds = 0.24 + 0.24 * min(startRate / 0.5, 1)
        r.pPlay = min(startRate + (1 - startRate) * cameoOdds, 1)
        r.p60 = startRate * 0.93           // cameos essentially never reach 60'
        r.minShare = min(mpg / 90, 1)
        if p.minutes == 0 {
            // No history at all (new signing, promoted club): fall back to a
            // mid-table starter's profile and let ep_next do the work.
            r.pPlay = 0.55; r.p60 = 0.42; r.minShare = 0.48
        }

        // How safe does the starting place look? `starts_per_90` is starts per
        // 90 minutes played, so it separates a man who plays 90 every week from
        // one who is hooked on the hour — two players can share a start rate and
        // not share a role. Combined with minutes per appearance it gives a
        // single number for squad status, which is what decides whether a
        // projection made for April is worth anything.
        let per90Starts = p.starts_per_90 ?? (mins > 0 ? starts / mins * 90 : 0)
        let minsPerApp = r.pPlay > 0.05 ? mpg / r.pPlay : 0
        r.startSecurity = min(startRate, 1) * 0.55
            + min(per90Starts, 1) * 0.2
            + min(minsPerApp / 90, 1) * 0.25
        if p.minutes == 0 { r.startSecurity = 0.42 }

        // ---- availability
        var avail = 1.0
        // Take the lower of the two published chances. FPL updates the
        // this-round figure first when news breaks on a matchday.
        if let c = p.chance_of_playing_next_round { avail = Double(c) / 100 }
        if let c = p.chance_of_playing_this_round { avail = min(avail, Double(c) / 100) }
        switch p.status {
        case "u", "n": avail = min(avail, 0.02)
        case "i", "s": avail = min(avail, 0.08)
        case "d": avail = min(avail, p.chance_of_playing_next_round.map { Double($0) / 100 } ?? 0.5)
        default: break
        }
        r.avail = avail

        // ---- attacking rates, shrunk toward positional priors
        func per90(_ total: String?) -> Double {
            mins > 0 ? (Double(total ?? "") ?? 0) / mins * 90 : 0
        }
        let rawXg90 = p.expected_goals_per_90 ?? per90(p.expected_goals)
        let rawXa90 = p.expected_assists_per_90 ?? per90(p.expected_assists)
        let g90 = mins > 0 ? Double(p.goals_scored) / mins * 90 : 0
        let a90 = mins > 0 ? Double(p.assists) / mins * 90 : 0

        // FPL's assist definition is looser than the one xA is built on — it
        // credits the pass before a deflection, a rebound, or a won penalty.
        // Measured across last season, actual assists exceeded xA by 38% for
        // defenders and 18% for midfielders, so xA is converted into
        // FPL-assist units before it is scored. Goals need only a small
        // defender correction (headers from set pieces underperform their xG).
        // Third channel: FPL's own threat and creativity indices, converted to
        // xG/xA units by the fitted coefficients above. They see things the xG
        // feed doesn't — shot volume and chance creation — and for outfielders
        // they are the single best predictor available after xG itself.
        let threat90 = mins > 0 ? (Double(p.threat ?? "") ?? 0) / mins * 90 : 0
        let creat90 = mins > 0 ? (Double(p.creativity ?? "") ?? 0) / mins * 90 : 0
        let threatXg = Self.threatToXg[pos] * threat90
        let creatXa = Self.creativityToXa[pos] * creat90
        let hasIndices = pos >= 2 && (threat90 > 0 || creat90 > 0)

        let ownXg = hasIndices
            ? 0.58 * rawXg90 * Self.xgToGoal[pos] + 0.20 * g90 + 0.22 * threatXg
            : 0.75 * rawXg90 * Self.xgToGoal[pos] + 0.25 * g90
        let ownXa = hasIndices
            ? 0.44 * rawXa90 * Self.xaToAssist[pos] + 0.30 * a90 + 0.26 * creatXa * Self.xaToAssist[pos]
            : 0.6 * rawXa90 * Self.xaToAssist[pos] + 0.4 * a90
        var xg90 = cred * ownXg + (1 - cred) * Self.xgPrior[pos]
        var xa90 = cred * ownXa + (1 - cred) * Self.xaPrior[pos] * Self.xaToAssist[pos]

        // ---- set-piece and penalty duty
        // xG already contains penalties the player has taken, so an established
        // taker only gets a partial top-up; someone newly on duty (little
        // history) gets close to the full value of the role.
        if (p.penalties_order ?? 99) == 1 { xg90 += 0.085 * (1 - 0.6 * cred) }
        else if (p.penalties_order ?? 99) == 2 { xg90 += 0.02 * (1 - 0.6 * cred) }

        let setPieces = (p.corners_and_indirect_freekicks_order ?? 99) == 1
            || (p.direct_freekicks_order ?? 99) == 1
        if setPieces { xa90 *= 1.10 + 0.10 * (1 - cred) }

        r.goalPts90 = Self.goalPts[pos] * xg90
        r.assistPts90 = 3 * xa90

        // ---- defensive contribution (2 pts at 10 CBIT / 12 CBIRT)
        // The per-90 feed only populates once the season is under way. When it
        // is live, model the count as Poisson and take the tail above the
        // threshold. Before then it reads zero for every player, so fall back
        // to the positional base rate — the previous build ran the empty feed
        // through Poisson and produced ~0 points for every outfielder, quietly
        // removing a scoring rule worth around half a point a game to defenders.
        let rawDc90 = p.defensive_contribution_per_90
            ?? (mins > 0 ? Double(p.defensive_contribution ?? 0) / mins * 90 : 0)
        if pos == 1 {
            r.defconPts = 0
        } else if rawDc90 > 0 {
            let dc90 = cred * rawDc90 + (1 - cred) * Self.dcPrior[pos]
            r.defconPts = 2 * Poisson.atLeast(Self.defconThreshold[pos], dc90 * r.minShare)
        } else {
            r.defconPts = Self.dcBasePts[pos] * min(r.minShare / 0.75, 1.3)
        }

        // ---- bonus: realised bonus rate, blended with a BPS-derived estimate
        // and shrunk toward a positional prior. An earlier build dropped BPS
        // because the estimate it used sat well below observed bonus rates and
        // taxed every projection; the coefficient here is fitted to reproduce
        // the observed mean, so it re-ranks players without moving the total.
        // Bonus is lumpy — a player can out-earn his BPS for half a season by
        // being narrowly first rather than narrowly third — which is exactly why
        // the smoother BPS signal is worth carrying alongside the realised rate.
        let bonus90 = mins > 0 ? Double(p.bonus) / mins * 90 : 0
        let bps90 = mins > 0 ? Double(p.bps ?? 0) / mins * 90 : 0
        let bpsBonus = Self.bpsToBonus[pos] * bps90
        // keepers excluded: their BPS barely predicts their bonus (r = 0.19)
        if pos >= 2, bps90 > 0 {
            r.bonusRate = cred * (0.55 * bonus90 + 0.45 * bpsBonus)
                + (1 - cred) * (0.5 * bpsBonus + 0.5 * Self.bonusPrior[pos])
        } else {
            r.bonusRate = cred * bonus90 + (1 - cred) * Self.bonusPrior[pos]
        }

        // ---- cards
        let y90 = mins > 0 ? Double(p.yellow_cards ?? 0) / mins * 90 : 0.10
        let r90 = mins > 0 ? Double(p.red_cards ?? 0) / mins * 90 : 0.004
        r.cardPts = -(y90 + 3 * r90)

        r.saves90 = pos == 1
            ? (p.saves_per_90 ?? (mins > 0 ? Double(p.saves) / mins * 90 : 0))
            : 0

        r.ppg = Double(p.points_per_game ?? "") ?? 0
        r.form = Double(p.form ?? "") ?? 0
        r.epNext = Double(p.ep_next ?? "") ?? 0

        // ---- form
        // Form is points per match over the last 30 days; points per game is the
        // season-long level. Their ratio is the trend, and it is applied to the
        // parts of the projection that genuinely move with a player's run of
        // touch — goals, assists, bonus — and not to the parts that don't, like
        // appearance points or his team's clean-sheet odds.
        //
        // The weight is deliberately well under 1. Four good matches is a small
        // sample, and chasing it is the standard way to lose a season; but
        // ignoring a player who has changed role, moved up the pecking order or
        // started taking the penalties throws away the freshest information
        // there is. 0.4 splits that difference, and the clamp stops one hat-trick
        // from doubling anyone.
        if seasonUnderway, r.ppg > 0.5, r.form > 0 {
            let trend = r.form / r.ppg
            r.formMult = min(max(1 + 0.4 * (trend - 1), 0.72), 1.45)
            r.goalPts90 *= r.formMult
            r.assistPts90 *= r.formMult
            r.bonusRate *= r.formMult
        }

        // ---- the player's own defensive record
        // Team-level ratings come from the keeper's expected goals conceded, but
        // a defender's own xGC/90 measures what the team conceded *while he was
        // on the pitch* — which separates a first-choice centre-back from a
        // full-back who only plays the comfortable games, and tracks the real
        // thing at r = 0.71 against goals actually conceded. Applied as a
        // multiplier on the fixture's concession rate: for a Poisson clean sheet
        // P(0) = e^-λ, so scaling λ by s is exactly P(0)^s.
        if pos <= 2, mins >= 450 {
            let ownXgc = p.expected_goals_conceded_per_90
                ?? (mins > 0 ? (Double(p.expected_goals_conceded ?? "") ?? 0) / mins * 90 : 0)
            let teamXgc = ratings.defence[min(p.team, ratings.defence.count - 1)]
            if ownXgc > 0.05, teamXgc > 0.05 {
                r.defScale = min(max(ownXgc / teamXgc, 0.78), 1.28)
            }
        }
        return r
    }

    // MARK: - score distribution
    //
    // The mean is what the optimiser maximises, but two players with the same
    // mean are not the same asset: a striker's points arrive in lumps and a
    // defender's arrive steadily. Captaincy and differential picks both turn on
    // the shape of the distribution, so the next gameweek's score is convolved
    // exactly over the components that actually vary — goals, assists, clean
    // sheet — with the rest held at their expected value.

    struct Outcome {
        var ceiling = 0.0     // 90th percentile
        var haul = 0.0        // P(10+)
        var blank = 0.0       // P(2 or fewer)
    }

    static func distribution(_ r: PlayerRates, _ fxs: [FixtureContext]) -> Outcome {
        guard !fxs.isEmpty, r.avail > 0.01 else { return Outcome(ceiling: 0, haul: 0, blank: 1) }

        // Aggregate the fixture-scaled rates across (possibly two) matches, then
        // rescale so the distribution's mean matches the projection the rest of
        // the app shows. The projection blends this component model with the
        // player's scoring history and FPL's own estimate; without the rescale a
        // striker's ceiling would be quoted off a different number than his mean.
        var lamG = 0.0, lamA = 0.0, csP = 0.0, extras = 0.0
        var model = 0.0, final = 0.0
        for fx in fxs {
            let c = r.components(fx)
            lamG += c.goals / max(goalPts[r.pos], 1)
            lamA += c.assists / 3
            csP += fx.csProb
            extras += c.conceded + c.saves + c.defcon + c.bonus + c.cards
            model += c.model
            final += c.final
        }
        csP = min(csP / Double(fxs.count), 1)
        let scale = model > 0.05 ? max(min(final / model, 3), 0.1) : 1
        let gPts = goalPts[r.pos] * scale, aPts = 3.0 * scale
        let cPts = csPts[r.pos] * scale
        extras *= scale

        // Appearance is the thing that actually creates a blank, so it is a
        // random variable here rather than an expected value. Treating it as an
        // average put a floor of two appearance points under every projection
        // and reported a 0% chance of a blank for players who are benched one
        // week in three. Three states: didn't play, came off the bench, started.
        let pNone = max(1 - r.pPlay, 0) + (1 - r.avail) * r.pPlay
        let pCameo = max(r.pPlay - r.p60, 0) * r.avail
        let pFull = r.p60 * r.avail
        // a substitute plays roughly a quarter of a match and never earns a
        // clean sheet, which needs 60 minutes
        let states: [(p: Double, appear: Double, rate: Double, cs: Double)] = [
            (pNone, 0, 0, 0),
            (pCameo, 1 * scale, 0.25, 0),
            (pFull, 2 * scale, 1.0, csP),
        ]

        var pmf = [Double](repeating: 0, count: 61)      // points −5 … 55, offset 5
        let offset = 5
        for st in states where st.p > 1e-6 {
            if st.rate == 0 {
                pmf[offset] += st.p
                continue
            }
            let lg = lamG * st.rate, la = lamA * st.rate
            var pg = exp(-lg)
            for g in 0...5 {
                var pa = exp(-la)
                for a in 0...4 {
                    for (cs, pc) in [(1.0, st.cs), (0.0, 1 - st.cs)] where pc > 1e-6 {
                        let pts = st.appear + extras * st.rate
                            + Double(g) * gPts + Double(a) * aPts + cs * cPts
                        let k = min(max(Int(pts.rounded()) + offset, 0), 60)
                        pmf[k] += st.p * pg * pa * pc
                    }
                    pa *= la / Double(a + 1)
                }
                pg *= lg / Double(g + 1)
            }
        }
        let mass = pmf.reduce(0, +)
        if mass > 0.001 { for i in pmf.indices { pmf[i] /= mass } }

        var out = Outcome()
        var cum = 0.0
        for k in 0...60 {
            cum += pmf[k]
            let pts = k - offset
            if pts <= 2 { out.blank = cum }
            if out.ceiling == 0, cum >= 0.90 { out.ceiling = Double(max(pts, 0)) }
            if pts >= 10 { out.haul += pmf[k] }
        }
        if out.ceiling == 0 { out.ceiling = 55 }
        return out
    }

    // MARK: - assembly

    func buildPlayers(totalManagers: Int) -> [Player] {
        let teamById = Dictionary(uniqueKeysWithValues: boot.teams.map { ($0.id, $0) })
        let games = Double(statGames)
        let lastGw = 38
        // FPL moves a price after net transfers pass roughly this fraction of
        // the total manager base. The published threshold isn't exact, but the
        // ratio ranks movers correctly, which is all the watchlist needs.
        let priceUnit = Double(max(totalManagers, 1)) * 0.0011

        var players: [Player] = boot.elements.map { p in
            let pos = min(max(p.element_type, 1), 4)
            let r = rates(for: p)
            let mpg = min(Double(p.minutes) / games, 90)

            // per-GW projections for every remaining gameweek, so the planner
            // can see all the way to GW 38
            var values = [Double](repeating: 0, count: max(lastGw - gwFrom + 1, 0))
            if !values.isEmpty {
                for gw in gwFrom...lastGw {
                    var sum = 0.0
                    for fx in contexts(p.team, gw: gw) { sum += r.project(fx) }
                    values[gw - gwFrom] = sum
                }
            }
            let projByGw = GWProjection(first: gwFrom, values: values)
            let proj = (gwFrom..<min(gwFrom + horizon, 39))
                .reduce(0.0) { $0 + projByGw.at($1) }
            let t = teamById[p.team]
            let dist = Self.distribution(r, contexts(p.team, gw: gwFrom))
            let net = (p.transfers_in_event ?? 0) - (p.transfers_out_event ?? 0)

            var pl = Player()
            pl.id = p.id; pl.name = p.web_name; pl.pos = pos; pl.team = p.team
            pl.teamShort = t?.short_name ?? "?"; pl.teamName = t?.name ?? "?"
            pl.cost = p.now_cost; pl.proj = proj
            pl.perGw = proj / Double(max(horizon, 1))
            pl.ppg = r.ppg
            pl.xgi90 = (r.goalPts90 / Self.goalPts[pos]) + (r.assistPts90 / 3)
            pl.own = Double(p.selected_by_percent ?? "") ?? 0
            pl.avail = r.avail; pl.flagged = p.status != "a"; pl.mins = p.minutes
            pl.fixtures = horizonFixtures(p.team); pl.projByGw = projByGw
            pl.totalPoints = p.total_points; pl.goals = p.goals_scored
            pl.assists = p.assists; pl.cleanSheets = p.clean_sheets ?? 0
            pl.bonus = p.bonus; pl.saves = p.saves; pl.starts = p.starts ?? 0
            pl.form = r.form
            pl.xg = Double(p.expected_goals ?? "") ?? 0
            pl.xa = Double(p.expected_assists ?? "") ?? 0
            pl.news = p.news ?? ""
            pl.expMins = mpg
            pl.penTaker = (p.penalties_order ?? 99) == 1
            pl.setPieces = (p.corners_and_indirect_freekicks_order ?? 99) == 1
                || (p.direct_freekicks_order ?? 99) == 1
            pl.startRate = min(Double(p.starts ?? 0) / games, 1)
            pl.startSecurity = r.startSecurity
            pl.formMult = r.formMult
            pl.ceiling = dist.ceiling; pl.haulProb = dist.haul; pl.blankProb = dist.blank
            pl.netTransfers = net
            pl.priceMomentum = max(min(Double(net) / priceUnit, 1.5), -1.5)
            pl.costChangeStart = p.cost_change_start ?? 0
            pl.ictIndex = Double(p.ict_index ?? "") ?? 0
            pl.threat = Double(p.threat ?? "") ?? 0
            pl.creativity = Double(p.creativity ?? "") ?? 0
            return pl
        }
        players.sort { $0.proj != $1.proj ? $0.proj > $1.proj : $0.id < $1.id }
        return players
    }

    /// Recompute only the headline horizon total from cached per-GW values.
    /// Changing the horizon doesn't change any per-gameweek projection, so
    /// there is no reason to re-run the whole model for it.
    static func reHorizon(_ players: [Player], gwFrom: Int, horizon: Int,
                          engine: ProjectionEngine) -> [Player] {
        let hi = min(gwFrom + horizon, 39)
        return players.map { p in
            var out = p
            var total = 0.0
            for gw in gwFrom..<hi { total += p.projByGw.at(gw) }
            out.proj = total
            out.perGw = total / Double(max(horizon, 1))
            out.fixtures = engine.horizonFixtures(p.team)
            return out
        }
        .sorted { $0.proj != $1.proj ? $0.proj > $1.proj : $0.id < $1.id }
    }

    // MARK: - team-level ratings, surfaced by the fixture tab

    struct TeamForm {
        let attack: Double      // expected goals scored per match, neutral ground
        let defence: Double     // expected goals conceded per match
    }

    func form(of teamId: Int) -> TeamForm {
        guard teamId >= 0, teamId < ratings.attack.count else {
            return TeamForm(attack: TeamRatings.leagueGoals, defence: TeamRatings.leagueGoals)
        }
        return TeamForm(attack: ratings.attack[teamId], defence: ratings.defence[teamId])
    }
}

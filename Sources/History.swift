import Foundation

// MARK: - Prior-season evidence
//
// A season's first weeks are the hardest time to project anything, and they are
// also when transfers matter most. After one gameweek FPL's own feed says
// Haaland's expected goals are 0.85/90 off ninety minutes and his points per
// game is 2.0 — so a model that trusts only this season shrinks him toward a
// generic forward and ranks a full-back who happened to score above him.
//
// The fix is not to distrust the current season; it is to stop pretending the
// previous ones never happened. FPL publishes every player's per-season totals
// at `element-summary/{id}/`, including expected goals, expected assists,
// expected goals conceded, BPS and starts, back to 2022/23. Those become the
// prior. This season's numbers are then evidence *against* that prior, and by
// October they dominate it on their own.
//
// The seasons are stored as they came, and weighted at the point of use. Two
// different weightings are needed and they are not close: scoring rates carry
// three seasons back because finishing is stable, while minutes barely carry
// one, because a move, a new manager or a breakout rewrites a player's role in
// a summer. Measured out of sample, splitting them is worth more than any other
// single change in the model.

/// One prior season as FPL publishes it. Only the fields the model reads.
struct PastSeason: Decodable {
    let season_name: String
    /// Price at the start and end of that season, which is what makes a
    /// historical squad backtest possible at all.
    let start_cost: Int?
    let end_cost: Int?
    let minutes: Int
    let starts: Int?
    let total_points: Int
    let goals_scored: Int
    let assists: Int
    let clean_sheets: Int
    let goals_conceded: Int
    let bonus: Int
    let bps: Int
    let saves: Int
    let yellow_cards: Int
    let red_cards: Int
    let defensive_contribution: Int?
    let expected_goals: String?
    let expected_assists: String?
    let expected_goals_conceded: String?
    let threat: String?
    let creativity: String?
}

struct ElementSummary: Decodable {
    let history_past: [PastSeason]
}

/// One season, kept whole so it can be weighted differently by different parts
/// of the model — and shown as-is on a player card.
struct SeasonLine: Codable, Equatable {
    var name = ""
    var minutes = 0.0
    var starts = 0.0
    var points = 0.0
    var goals = 0.0
    var assists = 0.0
    var cleanSheets = 0.0
    var bonus = 0.0
    var bps = 0.0
    var defcon = 0.0
    var saves = 0.0
    var yellows = 0.0
    var reds = 0.0
    var xg = 0.0
    var xa = 0.0
    var xgc = 0.0
    var threat = 0.0
    var creativity = 0.0

    /// The calendar year the season began, so a season can be weighted by how
    /// long ago it was rather than by its position in a list. A player who
    /// missed a whole year through injury has a "previous season" that is two
    /// years old, and it should not be treated as if it were last May.
    var startYear: Int { Int(name.prefix(4)) ?? 0 }

    var per90: Double { minutes > 0 ? points / minutes * 90 : 0 }
    var xg90: Double { minutes > 0 ? xg / minutes * 90 : 0 }
    var xa90: Double { minutes > 0 ? xa / minutes * 90 : 0 }
    /// Share of a 38-game season the player started.
    var startShare: Double { min(starts / 38, 1) }

    init(_ s: PastSeason) {
        name = s.season_name
        minutes = Double(s.minutes)
        starts = Double(s.starts ?? 0)
        points = Double(s.total_points)
        goals = Double(s.goals_scored)
        assists = Double(s.assists)
        cleanSheets = Double(s.clean_sheets)
        bonus = Double(s.bonus)
        bps = Double(s.bps)
        defcon = Double(s.defensive_contribution ?? 0)
        saves = Double(s.saves)
        yellows = Double(s.yellow_cards)
        reds = Double(s.red_cards)
        xg = Double(s.expected_goals ?? "") ?? 0
        xa = Double(s.expected_assists ?? "") ?? 0
        xgc = Double(s.expected_goals_conceded ?? "") ?? 0
        threat = Double(s.threat ?? "") ?? 0
        creativity = Double(s.creativity ?? "") ?? 0
    }

    init() {}
}

/// Recency-weighted totals across a player's previous seasons. Everything is a
/// weighted *total*, not a rate, so it can be folded into this season's totals
/// as pseudo-observations and read back as a per-90 in one place.
struct Weighted {
    var minutes = 0.0
    var starts = 0.0
    var seasons = 0.0          // weighted season count — the games denominator
    var points = 0.0
    var goals = 0.0
    var assists = 0.0
    var xg = 0.0
    var xa = 0.0
    var xgc = 0.0
    var bonus = 0.0
    var bps = 0.0
    var defcon = 0.0
    var saves = 0.0
    var yellows = 0.0
    var reds = 0.0
    var cleanSheets = 0.0
    var threat = 0.0
    var creativity = 0.0
}

/// A player's previous seasons, most recent first.
struct PastForm: Codable {
    var lines: [SeasonLine] = []

    /// The most recent season on its own — what a player card shows when it
    /// says "last season".
    var last: SeasonLine? { lines.first }
    var isEmpty: Bool { (lines.first?.minutes ?? 0) < 90 && totalMinutes < 90 }
    var totalMinutes: Double { lines.reduce(0) { $0 + $1.minutes } }

    /// Default weights on scoring rates: a player's last season is the best
    /// guide to the next one, two seasons back still says something about his
    /// level, three is mostly noise about a different player.
    static let recency: [Double] = [1.0, 0.45, 0.18]
    /// Minutes decay far faster. Fitted out of sample; see `Tuning`.
    static let minutesRecency: [Double] = [1.0, 0.05, 0.0]

    init(seasons list: [PastSeason]) {
        lines = list
            .filter { $0.minutes > 0 }
            .sorted { $0.season_name > $1.season_name }
            .prefix(4)
            .map(SeasonLine.init)
    }

    init() {}

    /// Weighted totals under an arbitrary recency profile. `season` is the
    /// year the season being projected began; each line is weighted by how many
    /// years back it was, not by where it sits in the list.
    func weighted(_ recency: [Double], season: Int = 0) -> Weighted {
        var w = Weighted()
        let newest = lines.first?.startYear ?? 0
        let reference = season > newest ? season : newest + 1
        for (i, line) in lines.enumerated() {
            let back = line.startYear > 0 ? reference - line.startYear : i + 1
            guard back >= 1, back <= recency.count else { continue }
            let k = recency[back - 1]
            w.minutes += k * line.minutes
            w.starts += k * line.starts
            w.seasons += k
            w.points += k * line.points
            w.goals += k * line.goals
            w.assists += k * line.assists
            w.xg += k * line.xg
            w.xa += k * line.xa
            w.xgc += k * line.xgc
            w.bonus += k * line.bonus
            w.bps += k * line.bps
            w.defcon += k * line.defcon
            w.saves += k * line.saves
            w.yellows += k * line.yellows
            w.reds += k * line.reds
            w.cleanSheets += k * line.cleanSheets
            w.threat += k * line.threat
            w.creativity += k * line.creativity
        }
        return w
    }
}

/// Prior form for every player, keyed by this season's element id.
struct PastFormBook: Codable {
    var byId: [Int: PastForm] = [:]
    var built = Date.distantPast
    /// The season these ids belong to. Element ids are reassigned every July,
    /// so a change here is the one event that invalidates the whole book.
    var season = 0
    /// Ids already asked about that came back with no senior record. Without
    /// this, every academy player is re-requested for ever.
    var barren: Set<Int> = []

    subscript(id: Int) -> PastForm? { byId[id] }
    var isEmpty: Bool { byId.isEmpty }

    /// Who we still need to ask about. Previous seasons are finished and
    /// cannot change, so this is the entire squad list once and then only the
    /// players who have arrived since — the old code re-downloaded all six
    /// hundred every week for data that was identical every time.
    func outstanding(_ ids: [Int], season: Int) -> [Int] {
        guard season == self.season else { return ids }
        return ids.filter { byId[$0] == nil && !barren.contains($0) }
    }
}

// MARK: - Fetching

enum PastFormService {
    /// Pull `element-summary` for every player and reduce each to its prior-season
    /// digest. ~600 small requests; run eight at a time so it finishes in about
    /// ten seconds on a phone, and cache the result for a week — previous seasons
    /// do not change.
    /// `checkpoint` is called periodically with the book so far. Six hundred
    /// requests take the better part of a minute on a phone, and a first run
    /// that is interrupted — the user switches app, iOS suspends it — used to
    /// throw away every one of them and start again from nothing next launch.
    static func fetch(ids: [Int], into existing: PastFormBook, season: Int,
                      session: URLSession,
                      checkpoint: (PastFormBook) -> Void = { _ in }) async -> PastFormBook {
        var book = existing.season == season ? existing : PastFormBook()
        book.season = season
        book.built = Date()
        await withTaskGroup(of: (Int, PastForm?).self) { group in
            var next = 0
            let lanes = min(8, ids.count)
            while next < lanes {
                let id = ids[next]
                group.addTask { (id, try? await one(id: id, session: session)) }
                next += 1
            }
            var settled = 0
            for await (id, form) in group {
                if let form, !form.isEmpty { book.byId[id] = form } else { book.barren.insert(id) }
                settled += 1
                if settled % 80 == 0 { checkpoint(book) }
                if next < ids.count {
                    let queued = ids[next]
                    group.addTask { (queued, try? await one(id: queued, session: session)) }
                    next += 1
                }
            }
        }
        return book
    }

    private static func one(id: Int, session: URLSession) async throws -> PastForm {
        let url = URL(string: "https://fantasy.premierleague.com/api/element-summary/\(id)/")!
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (PitchIQ iOS)", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await session.data(for: req)
        let summary = try JSONDecoder().decode(ElementSummary.self, from: data)
        return PastForm(seasons: summary.history_past)
    }
}

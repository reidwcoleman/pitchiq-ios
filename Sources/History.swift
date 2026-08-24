import Foundation

// MARK: - Prior-season evidence
//
// A season's first weeks are the hardest time to project anything, and they are
// also when transfers matter most. After one gameweek FPL's own feed says
// Haaland's expected goals are 0.85/90 off ninety minutes and his points per
// game is 2.0 — so a model that trusts only this season shrinks him toward a
// generic forward and ranks a full-back who happened to score above him. That
// is exactly what this app did.
//
// The fix is not to distrust the current season; it is to stop pretending the
// previous ones never happened. FPL publishes every player's per-season totals
// at `element-summary/{id}/`, including expected goals, expected assists,
// expected goals conceded, BPS and starts, back to 2022/23. Those become the
// prior. This season's numbers are then evidence *against* that prior, and by
// October they dominate it on their own.

/// One prior season as FPL publishes it. Only the fields the model reads.
struct PastSeason: Decodable {
    let season_name: String
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

/// Recency-weighted totals across a player's previous seasons. Everything is a
/// weighted *total*, not a rate, so it can be folded into this season's totals
/// as pseudo-observations and read back as a per-90 in one place.
struct PastForm: Codable {
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
    /// The most recent season on its own, unweighted — what a player card
    /// shows when it says "last season".
    var last: SeasonLine?

    var isEmpty: Bool { minutes < 90 }

    /// How much a season counts for, by how long ago it was. A player's last
    /// season is the single best guide to the next one; two seasons back still
    /// carries signal about level, three is mostly noise about a different
    /// player. Weights fall off fast enough that a 30-year-old's peak four
    /// years ago doesn't hold up his projection.
    static let recency: [Double] = [1.0, 0.45, 0.18]

    /// Build from `history_past`, most recent season last (the order FPL uses).
    init(seasons list: [PastSeason]) {
        if let recent = list.filter({ $0.minutes > 0 }).max(by: { $0.season_name < $1.season_name }) {
            last = SeasonLine(recent)
        }
        let ordered = list.sorted { $0.season_name < $1.season_name }.suffix(Self.recency.count)
        for (i, s) in ordered.enumerated().reversed() {
            let age = ordered.count - 1 - i
            guard age < Self.recency.count, s.minutes > 0 else { continue }
            let w = Self.recency[age]
            minutes += w * Double(s.minutes)
            starts += w * Double(s.starts ?? 0)
            seasons += w
            points += w * Double(s.total_points)
            goals += w * Double(s.goals_scored)
            assists += w * Double(s.assists)
            xg += w * (Double(s.expected_goals ?? "") ?? 0)
            xa += w * (Double(s.expected_assists ?? "") ?? 0)
            xgc += w * (Double(s.expected_goals_conceded ?? "") ?? 0)
            bonus += w * Double(s.bonus)
            bps += w * Double(s.bps)
            defcon += w * Double(s.defensive_contribution ?? 0)
            saves += w * Double(s.saves)
            yellows += w * Double(s.yellow_cards)
            reds += w * Double(s.red_cards)
            cleanSheets += w * Double(s.clean_sheets)
            threat += w * (Double(s.threat ?? "") ?? 0)
            creativity += w * (Double(s.creativity ?? "") ?? 0)
        }
    }

    init() {}
}

/// One season as a player card shows it.
struct SeasonLine: Codable, Equatable {
    var name = ""
    var minutes = 0
    var starts = 0
    var points = 0
    var goals = 0
    var assists = 0
    var cleanSheets = 0
    var bonus = 0
    var xg = 0.0
    var xa = 0.0

    var per90: Double { minutes > 0 ? Double(points) / Double(minutes) * 90 : 0 }
    var xg90: Double { minutes > 0 ? xg / Double(minutes) * 90 : 0 }
    var xa90: Double { minutes > 0 ? xa / Double(minutes) * 90 : 0 }

    init(_ s: PastSeason) {
        name = s.season_name
        minutes = s.minutes
        starts = s.starts ?? 0
        points = s.total_points
        goals = s.goals_scored
        assists = s.assists
        cleanSheets = s.clean_sheets
        bonus = s.bonus
        xg = Double(s.expected_goals ?? "") ?? 0
        xa = Double(s.expected_assists ?? "") ?? 0
    }

    init() {}
}

/// Prior form for every player, keyed by this season's element id.
struct PastFormBook: Codable {
    var byId: [Int: PastForm] = [:]
    var built = Date.distantPast

    subscript(id: Int) -> PastForm? { byId[id] }
    var isEmpty: Bool { byId.isEmpty }
}

// MARK: - Fetching

enum PastFormService {
    /// Pull `element-summary` for every player and reduce each to its prior-season
    /// digest. ~600 small requests; run eight at a time so it finishes in about
    /// ten seconds on a phone, and cache the result for a week — previous seasons
    /// do not change.
    static func fetch(ids: [Int], session: URLSession) async -> PastFormBook {
        var book = PastFormBook()
        book.built = Date()
        await withTaskGroup(of: (Int, PastForm?).self) { group in
            var next = 0
            let lanes = min(8, ids.count)
            while next < lanes {
                let id = ids[next]
                group.addTask { (id, try? await one(id: id, session: session)) }
                next += 1
            }
            for await (id, form) in group {
                if let form, !form.isEmpty { book.byId[id] = form }
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

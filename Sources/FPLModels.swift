import Foundation

// MARK: - FPL API payloads (fields we use)

struct Bootstrap: Decodable {
    let events: [GWEvent]
    let teams: [FPLTeam]
    let elements: [FPLElement]
    let chips: [FPLChip]?
}

struct FPLChip: Decodable {
    let name: String          // "wildcard" | "freehit" | "bboost" | "3xc"
    let start_event: Int
    let stop_event: Int
}

func chipDisplayName(_ chip: String) -> String {
    switch chip {
    case "wildcard": return "Wildcard"
    case "freehit": return "Free Hit"
    case "bboost": return "Bench Boost"
    case "3xc": return "Triple Captain"
    default: return chip
    }
}

/// Deterministic RNG (SplitMix64) so optimizer results are reproducible.
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

func chipShortName(_ chip: String) -> String {
    switch chip {
    case "wildcard": return "WC"
    case "freehit": return "FH"
    case "bboost": return "BB"
    case "3xc": return "TC"
    default: return chip
    }
}

struct GWEvent: Decodable {
    let id: Int
    let name: String
    let deadline_time: String
    let is_next: Bool
    let finished: Bool
}

struct FPLTeam: Decodable, Identifiable {
    let id: Int
    let name: String
    let short_name: String
}

struct FPLElement: Decodable {
    let id: Int
    let web_name: String
    let element_type: Int
    let team: Int
    let now_cost: Int
    let minutes: Int
    let starts: Int?
    let bonus: Int
    let saves: Int
    let goals_scored: Int
    let assists: Int
    let total_points: Int
    let points_per_game: String?
    let form: String?
    let ep_next: String?
    let expected_goals: String?
    let expected_assists: String?
    let expected_goal_involvements: String?
    let expected_goals_conceded: String?
    let selected_by_percent: String?
    let status: String
    let chance_of_playing_next_round: Int?
    let clean_sheets: Int?
    let news: String?
}

struct APIFixture: Decodable {
    let event: Int?
    let team_h: Int
    let team_a: Int
    let team_h_difficulty: Int?
    let team_a_difficulty: Int?
}

// MARK: - Derived types

struct FixtureInfo: Hashable {
    let opp: Int
    let home: Bool
    let diff: Int
}

enum Position: Int, CaseIterable {
    case gk = 1, def = 2, mid = 3, fwd = 4
    var short: String { ["", "GK", "DEF", "MID", "FWD"][rawValue] }
}

struct Player: Identifiable, Hashable {
    let id: Int
    let name: String
    let pos: Int
    let team: Int
    let teamShort: String
    let teamName: String
    let cost: Int          // tenths of £m
    let proj: Double       // projected points over horizon
    let perGw: Double
    let ppg: Double
    let xgi90: Double
    let own: Double
    let avail: Double
    let flagged: Bool
    let mins: Int
    let fixtures: [FixtureInfo]
    let projByGw: [Int: Double]   // per-GW projections across the planning window

    // last-season detail stats (for the player card)
    let totalPoints: Int
    let goals: Int
    let assists: Int
    let cleanSheets: Int
    let bonus: Int
    let saves: Int
    let starts: Int
    let form: Double
    let xg: Double
    let xa: Double
    let news: String

    var price: String { String(format: "%.1f", Double(cost) / 10) }
    var posShort: String { Position(rawValue: pos)?.short ?? "?" }

    /// Copy with a different headline projection — lets the optimizer and
    /// best-XI picker run against GW-specific or transfer-weighted values.
    func reprojected(_ v: Double) -> Player {
        Player(id: id, name: name, pos: pos, team: team, teamShort: teamShort,
               teamName: teamName, cost: cost, proj: v, perGw: perGw, ppg: ppg,
               xgi90: xgi90, own: own, avail: avail, flagged: flagged, mins: mins,
               fixtures: fixtures, projByGw: projByGw,
               totalPoints: totalPoints, goals: goals, assists: assists,
               cleanSheets: cleanSheets, bonus: bonus, saves: saves, starts: starts,
               form: form, xg: xg, xa: xa, news: news)
    }

    static func == (l: Player, r: Player) -> Bool { l.id == r.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

struct SquadResult {
    let squad: [Player]
    let xi: [Player]
    let bench: [Player]
    let formation: String
    let total: Double
    let captain: Player
    let vice: Player
    let cost: Int
}

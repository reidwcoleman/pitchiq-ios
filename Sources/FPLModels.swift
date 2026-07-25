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

func chipShortName(_ chip: String) -> String {
    switch chip {
    case "wildcard": return "WC"
    case "freehit": return "FH"
    case "bboost": return "BB"
    case "3xc": return "TC"
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

struct GWEvent: Decodable {
    let id: Int
    let name: String
    let deadline_time: String
    let is_next: Bool
    let finished: Bool
    let is_current: Bool?
}

struct FPLTeam: Decodable, Identifiable {
    let id: Int
    let name: String
    let short_name: String
    // Populated once the season is under way; 0/nil in pre-season.
    let strength_attack_home: Int?
    let strength_attack_away: Int?
    let strength_defence_home: Int?
    let strength_defence_away: Int?
    let strength_overall_home: Int?
    let strength_overall_away: Int?
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
    let bps: Int?
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
    // Per-90s the API already computes — cheaper and better normalised than
    // deriving them from season totals ourselves.
    let expected_goals_per_90: Double?
    let expected_assists_per_90: Double?
    let expected_goals_conceded_per_90: Double?
    let saves_per_90: Double?
    let defensive_contribution: Int?
    let defensive_contribution_per_90: Double?
    let selected_by_percent: String?
    let status: String
    let chance_of_playing_next_round: Int?
    let clean_sheets: Int?
    let goals_conceded: Int?
    let yellow_cards: Int?
    let red_cards: Int?
    let penalties_order: Int?
    let direct_freekicks_order: Int?
    let corners_and_indirect_freekicks_order: Int?
    let news: String?
}

struct APIFixture: Decodable {
    let event: Int?
    let team_h: Int
    let team_a: Int
    let team_h_difficulty: Int?
    let team_a_difficulty: Int?
    let finished: Bool?
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

/// Per-gameweek projections held in a contiguous buffer rather than a
/// `Dictionary`. Projections are read in the optimizer's innermost loops —
/// millions of times per rebuild — where a hashed lookup and the dictionary's
/// copy-on-write bookkeeping dominated the profile. Keeps a dictionary-shaped
/// API so call sites read the same.
struct GWProjection: Hashable {
    private let first: Int
    private let values: [Double]

    init(first: Int, values: [Double]) {
        self.first = first
        self.values = values
    }

    init() {
        self.first = 1
        self.values = []
    }

    subscript(gw: Int) -> Double? {
        let i = gw - first
        guard i >= 0, i < values.count else { return nil }
        return values[i]
    }

    /// Unchecked read used on hot paths; out-of-range gameweeks read as 0.
    @inline(__always)
    func at(_ gw: Int) -> Double {
        let i = gw - first
        guard i >= 0, i < values.count else { return 0 }
        return values[i]
    }

    var keys: [Int] { Array(first..<(first + values.count)) }
}

/// The optimizer's working unit: a 16-byte, reference-free view of a player.
/// `Player` carries four strings, an array and a projection buffer, so every
/// copy meant six retain/release pairs — and simulated annealing copies squads
/// tens of thousands of times per rebuild. `Pick` copies are free.
struct Pick {
    let id: Int32
    let pos: Int8
    let team: Int8
    let cost: Int16
    var proj: Double

    @inline(__always)
    init(_ p: Player, proj: Double) {
        self.id = Int32(p.id)
        self.pos = Int8(p.pos)
        self.team = Int8(p.team)
        self.cost = Int16(p.cost)
        self.proj = proj
    }
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
    let projByGw: GWProjection   // per-GW projections across the planning window

    // detail stats (for the player card)
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

    // model diagnostics surfaced on the player card
    let expMins: Double     // expected minutes per match
    let penTaker: Bool
    let setPieces: Bool

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
               form: form, xg: xg, xa: xa, news: news,
               expMins: expMins, penTaker: penTaker, setPieces: setPieces)
    }

    @inline(__always)
    func pick(_ v: Double) -> Pick { Pick(self, proj: v) }

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

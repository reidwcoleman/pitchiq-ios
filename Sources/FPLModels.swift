import Foundation

// MARK: - FPL API payloads (fields we use)

struct Bootstrap: Decodable {
    let events: [GWEvent]
    let teams: [FPLTeam]
    let elements: [FPLElement]
    let chips: [FPLChip]?
    let total_players: Int?
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

    // Market signals. FPL moves a price when net transfers cross a threshold
    // proportional to the total number of managers, so these three fields are
    // what the price-change watch is built from.
    let transfers_in_event: Int?
    let transfers_out_event: Int?
    let cost_change_event: Int?
    let cost_change_start: Int?

    // Underlying-performance indices, used on the player card and to separate
    // players whose projections are close.
    let ict_index: String?
    let threat: String?
    let creativity: String?
    let influence: String?
    let expected_goal_involvements_per_90: Double?
    let starts_per_90: Double?
    let clean_sheets_per_90: Double?
    let chance_of_playing_this_round: Int?
    let dreamteam_count: Int?
}

// MARK: - A manager's own team (public entry endpoints)

struct EntrySummary: Decodable {
    let id: Int
    let name: String
    let player_first_name: String?
    let player_last_name: String?
    let summary_overall_points: Int?
    let summary_overall_rank: Int?
    let last_deadline_bank: Int?
    let last_deadline_value: Int?
    let current_event: Int?
}

struct EntryPicks: Decodable {
    struct Pick: Decodable {
        let element: Int
        let position: Int
        let multiplier: Int
        let is_captain: Bool
        let is_vice_captain: Bool
    }
    struct History: Decodable {
        let event: Int
        let bank: Int
        let value: Int
        let event_transfers: Int
        let event_transfers_cost: Int
        let points: Int?
    }
    let picks: [Pick]
    let entry_history: History?
    let active_chip: String?
}

struct EntryHistory: Decodable {
    struct ChipUse: Decodable { let name: String; let event: Int }
    let chips: [ChipUse]
}

/// Everything the planner needs to know about the squad the user actually owns.
struct TeamState: Codable, Equatable {
    var entryId: Int
    var teamName: String
    var managerName: String
    var squadIds: [Int]
    var captainId: Int
    var bank: Int              // tenths of £m
    var squadValue: Int        // tenths of £m, excluding the bank
    var freeTransfers: Int
    var chipsUsed: [String]    // chip names already played this season
    var overallPoints: Int
    var overallRank: Int
    var gw: Int                // the gameweek these picks are from
    var fetched: Date

    var budget: Int { squadValue + bank }
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

/// A player as the app uses them: identity, price, the projection for whatever
/// window is selected, per-gameweek projections, and the season stats behind
/// the number. Stored with `var` properties and copied by value — `reprojected`
/// used to be a 20-argument re-construction that had to be edited every time a
/// field was added, and silently dropped anything forgotten.
struct Player: Identifiable, Hashable {
    var id = 0
    var name = ""
    var pos = 0
    var team = 0
    var teamShort = ""
    var teamName = ""
    var cost = 0            // tenths of £m
    var proj = 0.0          // projected points over the selected window
    var perGw = 0.0
    var ppg = 0.0
    var xgi90 = 0.0
    var own = 0.0           // % of managers who own them
    var avail = 1.0
    var flagged = false
    var mins = 0
    var fixtures: [FixtureInfo] = []
    var projByGw = GWProjection()

    // detail stats (player card)
    var totalPoints = 0
    var goals = 0
    var assists = 0
    var cleanSheets = 0
    var bonus = 0
    var saves = 0
    var starts = 0
    var form = 0.0
    var xg = 0.0
    var xa = 0.0
    var news = ""

    // model diagnostics
    var expMins = 0.0       // expected minutes per match
    var penTaker = false
    var setPieces = false
    var startRate = 0.0     // P(starts) — the minutes-security number
    var startSecurity = 0.0 // how safe the starting place looks over months, 0…1
    var formMult = 1.0      // recent form as a multiplier on attacking output

    // distribution of next gameweek's score, not just its mean
    var ceiling = 0.0       // 90th-percentile return
    var haulProb = 0.0      // P(10+ points)
    var blankProb = 0.0     // P(2 or fewer)

    // market
    var netTransfers = 0    // this gameweek's transfers in minus out
    var priceMomentum = 0.0 // -1 … +1, progress toward a fall or a rise
    var costChangeStart = 0 // price movement since the season opened
    var ictIndex = 0.0
    var threat = 0.0
    var creativity = 0.0

    var price: String { String(format: "%.1f", Double(cost) / 10) }
    var posShort: String { Position(rawValue: pos)?.short ?? "?" }
    /// Points per £m over the selected window — the value metric.
    var valueScore: Double { cost > 0 ? proj / (Double(cost) / 10) : 0 }

    /// Copy with a different headline projection — lets the solver and the
    /// best-XI picker run against gameweek-specific or transfer-weighted values.
    func reprojected(_ v: Double) -> Player {
        var c = self
        c.proj = v
        return c
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

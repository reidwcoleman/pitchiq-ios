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

    var deadline: Date? { ISO8601DateFormatter().date(from: deadline_time) }
}

struct FPLTeam: Decodable, Identifiable {
    let id: Int
    /// Club code, used for the crest asset. Also stable across seasons.
    let code: Int?
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
    /// Stable across seasons, and the key to the player's photograph on
    /// resources.premierleague.com. `id` is not — it is reassigned every July.
    let code: Int
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
    /// FPL's own price-change meter, added for 2026/27: how far the player is
    /// toward a change (100 = it happens), how fast, and what it projects for
    /// tonight and the two nights after, with a −5…5 confidence. Strictly
    /// better than inferring it from net transfers, which is what this app did.
    let price_change_percent: String?
    let price_change_hourly_rate: Int?
    let price_change_projections: [PriceProjection]?

    struct PriceProjection: Decodable {
        let offset: Int              // nights from now
        let projected_percent: String
        let likelihood: Int          // −5 … 5
        var percent: Double { Double(projected_percent) ?? 0 }
    }

    // Underlying-performance indices, used on the player card and to separate
    // players whose projections are close.
    let ict_index: String?
    let threat: String?
    let creativity: String?
    let influence: String?
    let expected_goal_involvements_per_90: Double?
    let starts_per_90: Double?
    /// Age and the date the player joined his current club. Both matter: output
    /// declines after the late twenties, and a player three weeks into a new
    /// club has a minutes history that belongs to a different manager.
    let birth_date: String?
    let team_join_date: String?
    let clean_sheets_per_90: Double?
    let chance_of_playing_this_round: Int?
    let dreamteam_count: Int?
}

// MARK: - A manager's own team (public entry endpoints)

struct EntrySummary: Decodable {
    struct Leagues: Decodable { let classic: [League]? }
    struct League: Decodable {
        let id: Int
        let name: String
        let entry_rank: Int?
        let entry_last_rank: Int?
        let rank_count: Int?
        let league_type: String?
    }
    let id: Int
    let name: String
    let player_first_name: String?
    let player_last_name: String?
    let summary_overall_points: Int?
    let summary_overall_rank: Int?
    let summary_event_points: Int?
    let summary_event_rank: Int?
    let last_deadline_bank: Int?
    let last_deadline_value: Int?
    let current_event: Int?
    let leagues: Leagues?
}

/// One mini-league as it appears on the manager's own entry — enough for a
/// standings card without a second request per league.
struct LeagueSummary: Codable, Equatable, Identifiable {
    var id: Int
    var name: String
    var rank: Int
    var lastRank: Int
    var size: Int
    var isGlobal: Bool

    /// Places gained (positive) or lost since last gameweek. A last rank of
    /// zero means the league had not been ranked yet, not a climb of a million.
    var movement: Int { lastRank > 0 && rank > 0 ? lastRank - rank : 0 }
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

    var squadPicks: [SquadPick] {
        picks.map { SquadPick(element: $0.element, position: $0.position,
                              multiplier: $0.multiplier,
                              isCaptain: $0.is_captain, isVice: $0.is_vice_captain) }
    }
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
    // Added after the first release, so all optional: an existing saved team
    // decodes without them and fills them in on the next refresh.
    var picks: [SquadPick]?        // with multipliers and bench order
    var activeChip: String?
    var transferCost: Int?
    var eventPoints: Int?
    var leagues: [LeagueSummary]?

    var budget: Int { squadValue + bank }
}

// MARK: - mini-league standings

struct LeagueStandings: Decodable {
    struct Meta: Decodable { let id: Int; let name: String }
    struct Page: Decodable { let has_next: Bool; let results: [Row] }
    struct Row: Decodable, Identifiable {
        let entry: Int?
        let entry_name: String
        let player_name: String
        let rank: Int
        let last_rank: Int
        let event_total: Int
        let total: Int

        var id: Int { entry ?? rank }
        var movement: Int { last_rank > 0 ? last_rank - rank : 0 }
    }
    let league: Meta
    let standings: Page
}

struct APIFixture: Decodable, Identifiable {
    let id: Int?
    let event: Int?
    let team_h: Int
    let team_a: Int
    let team_h_difficulty: Int?
    let team_a_difficulty: Int?
    let finished: Bool?
    let finished_provisional: Bool?
    let started: Bool?
    let minutes: Int?
    let team_h_score: Int?
    let team_a_score: Int?
    let kickoff_time: String?

    var kickoff: Date? {
        guard let kickoff_time else { return nil }
        return ISO8601DateFormatter().date(from: kickoff_time)
    }
    /// Everything about where this match is in its life, in one value.
    var liveState: MatchState {
        if finished == true || finished_provisional == true { return .finished }
        if started == true { return .live(minutes ?? 0) }
        return .upcoming
    }
}

enum MatchState: Equatable {
    case upcoming
    case live(Int)
    case finished

    var isLive: Bool { if case .live = self { return true }; return false }
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
    /// P(the player appears at all this gameweek). Carried into the optimiser
    /// because it is what decides whether a bench is worth anything: a
    /// substitute is paid exactly when a starter doesn't turn up.
    let play: Float

    @inline(__always)
    init(_ p: Player, proj: Double) {
        self.id = Int32(p.id)
        self.pos = Int8(p.pos)
        self.team = Int8(p.team)
        self.cost = Int16(p.cost)
        self.proj = proj
        self.play = Float(p.playProb)
    }
}

/// A player as the app uses them: identity, price, the projection for whatever
/// window is selected, per-gameweek projections, and the season stats behind
/// the number. Stored with `var` properties and copied by value — `reprojected`
/// used to be a 20-argument re-construction that had to be edited every time a
/// field was added, and silently dropped anything forgotten.
struct Player: Identifiable, Hashable {
    var id = 0
    var code = 0            // stable player code — the photo asset
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
    var playProb = 0.85     // P(appears at all in a given gameweek)
    var startSecurity = 0.0 // how safe the starting place looks over months, 0…1
    var formMult = 1.0      // recent form as a multiplier on attacking output

    // distribution of next gameweek's score, not just its mean
    var ceiling = 0.0       // 90th-percentile return
    var haulProb = 0.0      // P(10+ points)
    var blankProb = 0.0     // P(2 or fewer)

    // market
    var netTransfers = 0    // this gameweek's transfers in minus out
    var priceMomentum = 0.0 // -1 … +1, progress toward a fall or a rise
    /// Nights until FPL's own model expects the price to change, and how
    /// confident it is. Nil when no change is projected within three nights.
    var priceChangeIn: Int?
    var priceConfidence = 0.0   // 0…1
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

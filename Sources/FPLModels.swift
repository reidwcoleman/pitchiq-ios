import Foundation

// MARK: - FPL API payloads (fields we use)

struct Bootstrap: Decodable {
    let events: [GWEvent]
    let teams: [FPLTeam]
    let elements: [FPLElement]
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

    var price: String { String(format: "%.1f", Double(cost) / 10) }
    var posShort: String { Position(rawValue: pos)?.short ?? "?" }

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

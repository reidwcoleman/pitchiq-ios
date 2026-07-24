import SwiftUI

@MainActor
final class AppState: ObservableObject {
    enum Phase { case loading, optimizing, ready, error(String) }

    @Published var phase: Phase = .loading
    @Published var boot: Bootstrap?
    @Published var fixtures: [APIFixture] = []
    @Published var players: [Player] = []
    @Published var squad: SquadResult?
    @Published var plan: SeasonPlan?
    @Published var lastUpdated: Date?

    @Published var gwFrom = 1
    @Published var horizon = 3 { didSet { rebuild() } }
    @Published var budget = 100.0
    @Published var fitOnly = true { didSet { rebuild() } }

    /// The user's own 15 (player ids) after editing the AI squad. Persisted.
    @Published var customSquadIds: [Int]?

    let planWindow = 6
    private static let customKey = "customSquadIds"

    var teams: [Int: FPLTeam] = [:]
    var isPreseason: Bool { !(boot?.events.contains { $0.finished } ?? false) }
    var gwOptions: [GWEvent] { boot?.events ?? [] }
    var isEdited: Bool { customSquadIds != nil }

    init() {
        customSquadIds = UserDefaults.standard.array(forKey: Self.customKey) as? [Int]
    }

    func teamShort(_ id: Int) -> String { teams[id]?.short_name ?? "?" }
    func teamName(_ id: Int) -> String { teams[id]?.name ?? "?" }

    func load() async {
        phase = .loading
        do {
            let (boot, fixtures) = try await FPLService.fetch()
            self.boot = boot
            self.fixtures = fixtures
            self.teams = Dictionary(uniqueKeysWithValues: boot.teams.map { ($0.id, $0) })
            // auto-advance to the next gameweek once one finishes
            self.gwFrom = boot.events.first { $0.is_next }?.id
                ?? boot.events.first { !$0.finished }?.id ?? 1
            self.lastUpdated = Date()
            rebuild()
        } catch {
            phase = .error("Couldn't reach the FPL API — check your connection.\n(\(error.localizedDescription))")
        }
    }

    /// Refetch live data if it's stale (call when app returns to foreground).
    func refreshIfStale() {
        guard let last = lastUpdated, Date().timeIntervalSince(last) > 30 * 60 else { return }
        Task { await load() }
    }

    func rebuild() {
        guard let boot else { return }
        phase = .optimizing
        let engine = ProjectionEngine(boot: boot, fixtures: fixtures, gwFrom: gwFrom, horizon: horizon)
        let budgetM = budget
        let fit = fitOnly
        let gwFrom = gwFrom
        let window = planWindow
        let customIds = customSquadIds
        Task.detached(priority: .userInitiated) {
            let players = engine.buildPlayers()
            var squad: SquadResult?
            var userSquad: [Player]?
            if let ids = customIds, let custom = Self.buildSquad(ids: ids, players: players) {
                userSquad = custom.squad
                // display XI/captain/points for the selected GW only
                squad = Self.buildSquad(ids: ids, players: players, displayGw: gwFrom)
            } else if let ai = Optimizer.optimize(players: players, budgetM: budgetM, fitOnly: fit) {
                squad = Self.buildSquad(ids: ai.squad.map(\.id), players: players, displayGw: gwFrom)
            }
            let plan = Planner.plan(players: players, budgetM: budgetM, fitOnly: fit,
                                    from: gwFrom, window: window, userSquad: userSquad)
            await MainActor.run {
                self.players = players
                self.squad = squad
                self.plan = plan
                self.phase = .ready
            }
        }
    }

    // MARK: - team editing

    /// Swap `out` for `inn` in the displayed squad and make it the user's team.
    func applySwap(out: Player, inn: Player) {
        guard let current = squad?.squad else { return }
        let ids = current.map { $0.id == out.id ? inn.id : $0.id }
        customSquadIds = ids
        UserDefaults.standard.set(ids, forKey: Self.customKey)
        rebuild()
    }

    func resetToAI() {
        customSquadIds = nil
        UserDefaults.standard.removeObject(forKey: Self.customKey)
        rebuild()
    }

    /// Legal replacements for `out` given the current squad.
    func swapCandidates(for out: Player) -> [Player] {
        guard let current = squad?.squad else { return [] }
        let ids = Set(current.map(\.id))
        let budgetTenths = Int((budget * 10).rounded())
        let costWithoutOut = current.reduce(0) { $0 + $1.cost } - out.cost
        var clubs: [Int: Int] = [:]
        for p in current where p.id != out.id { clubs[p.team, default: 0] += 1 }
        return players.filter { p in
            p.pos == out.pos && !ids.contains(p.id)
                && costWithoutOut + p.cost <= budgetTenths
                && clubs[p.team, default: 0] < 3
        }
    }

    /// Build a SquadResult from ids; with displayGw set, XI/captain/points are
    /// computed for that single gameweek's projections.
    nonisolated static func buildSquad(ids: [Int], players: [Player], displayGw: Int? = nil) -> SquadResult? {
        let byId = Dictionary(uniqueKeysWithValues: players.map { ($0.id, $0) })
        var squad = ids.compactMap { byId[$0] }
        if let gw = displayGw { squad = squad.map { $0.reprojected($0.projByGw[gw] ?? 0) } }
        guard squad.count == 15, let r = Optimizer.bestXI(squad) else { return nil }
        let sorted = r.xi.sorted { $0.proj > $1.proj }
        return SquadResult(squad: squad, xi: r.xi, bench: r.bench, formation: r.formation,
                           total: r.total, captain: sorted[0], vice: sorted[1],
                           cost: squad.reduce(0) { $0 + $1.cost })
    }

    /// All upcoming fixtures for a team from the selected GW (for player detail).
    func upcomingFixtures(teamId: Int, limit: Int = 12) -> [(gw: Int, fx: FixtureInfo)] {
        var out: [(Int, FixtureInfo)] = []
        for f in fixtures {
            guard let e = f.event, e >= gwFrom else { continue }
            if f.team_h == teamId {
                out.append((e, FixtureInfo(opp: f.team_a, home: true, diff: f.team_h_difficulty ?? 3)))
            } else if f.team_a == teamId {
                out.append((e, FixtureInfo(opp: f.team_h, home: false, diff: f.team_a_difficulty ?? 3)))
            }
        }
        return Array(out.sorted { $0.0 < $1.0 }.prefix(limit))
    }

    // fixture grid helper
    func gridFixtures(teamId: Int, gws: [Int]) -> [[FixtureInfo]] {
        guard let boot else { return [] }
        let engine = ProjectionEngine(boot: boot, fixtures: fixtures, gwFrom: gwFrom, horizon: horizon)
        return gws.map { engine.teamFixtures(teamId, gw: $0) }
    }
}

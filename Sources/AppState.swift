import SwiftUI

@MainActor
final class AppState: ObservableObject {
    enum Phase { case loading, optimizing, ready, error(String) }

    @Published var phase: Phase = .loading
    @Published var boot: Bootstrap?
    @Published var fixtures: [APIFixture] = []
    @Published var players: [Player] = []
    @Published var squad: SquadResult?

    @Published var gwFrom = 1
    @Published var horizon = 3 { didSet { rebuild() } }
    @Published var budget = 100.0
    @Published var fitOnly = true { didSet { rebuild() } }

    var teams: [Int: FPLTeam] = [:]
    var isPreseason: Bool { !(boot?.events.contains { $0.finished } ?? false) }
    var gwOptions: [GWEvent] { boot?.events ?? [] }

    func teamShort(_ id: Int) -> String { teams[id]?.short_name ?? "?" }
    func teamName(_ id: Int) -> String { teams[id]?.name ?? "?" }

    func load() async {
        phase = .loading
        do {
            let (boot, fixtures) = try await FPLService.fetch()
            self.boot = boot
            self.fixtures = fixtures
            self.teams = Dictionary(uniqueKeysWithValues: boot.teams.map { ($0.id, $0) })
            self.gwFrom = boot.events.first { $0.is_next }?.id
                ?? boot.events.first { !$0.finished }?.id ?? 1
            rebuild()
        } catch {
            phase = .error("Couldn't reach the FPL API — check your connection.\n(\(error.localizedDescription))")
        }
    }

    func rebuild() {
        guard let boot else { return }
        phase = .optimizing
        let engine = ProjectionEngine(boot: boot, fixtures: fixtures, gwFrom: gwFrom, horizon: horizon)
        let budgetM = budget
        let fit = fitOnly
        Task.detached(priority: .userInitiated) {
            let players = engine.buildPlayers()
            let squad = Optimizer.optimize(players: players, budgetM: budgetM, fitOnly: fit)
            await MainActor.run {
                self.players = players
                self.squad = squad
                self.phase = .ready
            }
        }
    }

    // fixture grid helper
    func gridFixtures(teamId: Int, gws: [Int]) -> [[FixtureInfo]] {
        guard let boot else { return [] }
        let engine = ProjectionEngine(boot: boot, fixtures: fixtures, gwFrom: gwFrom, horizon: horizon)
        return gws.map { engine.teamFixtures(teamId, gw: $0) }
    }
}

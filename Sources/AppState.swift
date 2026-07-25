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
    @Published var refreshing = false

    @Published var gwFrom = 1
    @Published var horizon = 3 { didSet { if horizon != oldValue { rebuild() } } }
    @Published var budget = 100.0
    @Published var fitOnly = true { didSet { if fitOnly != oldValue { rebuild() } } }

    /// The user's own 15 (player ids) after editing the AI squad. Persisted.
    @Published var customSquadIds: [Int]?

    /// Plan every remaining gameweek of the season (through GW 38).
    var planWindow: Int { max(38 - gwFrom + 1, 1) }
    private static let customKey = "customSquadIds"

    var teams: [Int: FPLTeam] = [:]

    // MARK: - caches
    // Every one of these used to be rebuilt from scratch on each `rebuild()`,
    // and `gridFixtures` rebuilt an entire ProjectionEngine per call — from
    // inside view bodies, once per team row.

    private var engine: ProjectionEngine?
    private var engineGw: Int?
    private var modelPlayers: [Player] = []        // horizon-independent per-GW model
    private var cachedDoubleGws: Set<Int>?
    private var cachedPlan: SeasonPlan?
    private var cachedPlanKey: PlanKey?

    /// Bumped on every rebuild request. A background result whose token no
    /// longer matches is discarded — previously two quick control changes
    /// raced and whichever finished last won, so the screen could end up
    /// showing a squad that didn't match the visible settings.
    private var generation = 0

    private struct PlanKey: Equatable {
        let gwFrom: Int
        let budget: Int
        let fitOnly: Bool
        let custom: [Int]?
        let dataStamp: Int
    }

    /// Gameweeks where at least one team plays twice (announced mid-season).
    var doubleGws: Set<Int> {
        if let c = cachedDoubleGws { return c }
        var counts: [Int: [Int: Int]] = [:]
        for f in fixtures {
            guard let gw = f.event else { continue }
            counts[gw, default: [:]][f.team_h, default: 0] += 1
            counts[gw, default: [:]][f.team_a, default: 0] += 1
        }
        let s = Set(counts.filter { $0.value.values.contains { $0 >= 2 } }.keys)
        cachedDoubleGws = s
        return s
    }

    var isPreseason: Bool { !(boot?.events.contains { $0.finished } ?? false) }
    var gwOptions: [GWEvent] { boot?.events ?? [] }
    var isEdited: Bool { customSquadIds != nil }

    init() {
        customSquadIds = UserDefaults.standard.array(forKey: Self.customKey) as? [Int]
    }

    func teamShort(_ id: Int) -> String { teams[id]?.short_name ?? "?" }
    func teamName(_ id: Int) -> String { teams[id]?.name ?? "?" }

    // MARK: - loading

    /// Render from the on-disk cache first, then refresh over the network.
    /// A cold launch no longer blocks on two HTTP round trips before drawing.
    func load() async {
        if boot == nil {
            let cached = await Task.detached(priority: .userInitiated) { DataCache.read() }.value
            if let cached {
                apply(boot: cached.boot, fixtures: cached.fixtures, stamp: cached.fetched)
            }
        }
        await refresh()
    }

    /// Fetch live data. Keeps whatever is already on screen if the network
    /// fails, and never drops the UI back to the loading spinner.
    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            let (boot, fixtures) = try await FPLService.fetch()
            apply(boot: boot, fixtures: fixtures, stamp: Date())
        } catch {
            if self.boot == nil {
                phase = .error("Couldn't reach the FPL API — check your connection.\n(\(error.localizedDescription))")
            }
        }
    }

    private func apply(boot: Bootstrap, fixtures: [APIFixture], stamp: Date) {
        self.boot = boot
        self.fixtures = fixtures
        self.teams = Dictionary(uniqueKeysWithValues: boot.teams.map { ($0.id, $0) })
        // auto-advance to the next gameweek once one finishes
        self.gwFrom = boot.events.first { $0.is_next }?.id
            ?? boot.events.first { !$0.finished }?.id ?? 1
        self.lastUpdated = stamp
        self.cachedDoubleGws = nil
        self.engine = nil
        self.engineGw = nil
        self.modelPlayers = []
        self.cachedPlanKey = nil
        rebuild()
    }

    /// Refetch live data if it's stale (call when app returns to foreground).
    func refreshIfStale() {
        guard let last = lastUpdated, Date().timeIntervalSince(last) > 30 * 60 else { return }
        Task { await refresh() }
    }

    // MARK: - rebuild

    func rebuild() {
        guard let boot else { return }
        generation += 1
        let gen = generation

        // The engine is expensive to construct (it precomputes every fixture's
        // clean-sheet and concession maths) but only depends on the data and
        // the starting gameweek.
        let eng: ProjectionEngine
        if let e = engine, engineGw == gwFrom {
            eng = e
        } else {
            eng = ProjectionEngine(boot: boot, fixtures: fixtures, gwFrom: gwFrom, horizon: horizon)
            engine = eng
            engineGw = gwFrom
            modelPlayers = []
        }

        if players.isEmpty { phase = .loading } else { phase = .optimizing }

        let budgetM = budget
        let fit = fitOnly
        let gwFrom = gwFrom
        let horizon = horizon
        let window = planWindow
        let customIds = customSquadIds
        let dgws = doubleGws
        let cachedModel = modelPlayers
        let chipsMeta = (boot.chips ?? []).map {
            ChipMeta(name: $0.name, start: $0.start_event, stop: $0.stop_event)
        }
        // Changing the horizon changes only the headline number shown against
        // each player — per-gameweek projections, and therefore the whole
        // season plan, are unaffected. Reuse the plan instead of re-running the
        // most expensive computation in the app for a display-only change.
        let key = PlanKey(gwFrom: gwFrom, budget: Int(budget * 10), fitOnly: fit,
                          custom: customIds, dataStamp: boot.elements.count)
        let reusablePlan = (cachedPlanKey == key) ? cachedPlan : nil

        Task.detached(priority: .userInitiated) {
            // reuse the per-gameweek model when only the horizon changed
            let players: [Player] = cachedModel.isEmpty
                ? eng.buildPlayers()
                : ProjectionEngine.reHorizon(cachedModel, gwFrom: gwFrom,
                                             horizon: horizon, engine: eng)
            let baseModel = cachedModel.isEmpty ? players : cachedModel

            var squad: SquadResult?
            var userSquad: [Player]?
            var staleCustom = false
            if let ids = customIds {
                if let custom = Self.buildSquad(ids: ids, players: players) {
                    userSquad = custom.squad
                    // display XI/captain/points for the selected GW only
                    squad = Self.buildSquad(ids: ids, players: players, displayGw: gwFrom)
                } else {
                    staleCustom = true // a saved player no longer exists — fall back to AI
                }
            }
            if squad == nil, let ai = Optimizer.optimize(players: players, budgetM: budgetM, fitOnly: fit) {
                squad = Self.buildSquad(ids: ai.squad.map(\.id), players: players, displayGw: gwFrom)
            }

            let plan = reusablePlan ?? Planner.plan(
                players: players, budgetM: budgetM, fitOnly: fit,
                from: gwFrom, window: window, userSquad: userSquad,
                chipsMeta: chipsMeta, doubleGws: dgws)

            await MainActor.run {
                guard gen == self.generation else { return }   // a newer rebuild won
                if staleCustom {
                    self.customSquadIds = nil
                    UserDefaults.standard.removeObject(forKey: Self.customKey)
                }
                self.modelPlayers = baseModel
                self.players = players
                self.squad = squad
                self.plan = plan
                if let plan { self.cachedPlan = plan; self.cachedPlanKey = key }
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
        var byId = [Int: Player](minimumCapacity: players.count)
        for p in players { byId[p.id] = p }
        var squad = ids.compactMap { byId[$0] }
        if let gw = displayGw { squad = squad.map { $0.reprojected($0.projByGw.at(gw)) } }
        guard squad.count == 15, let r = Optimizer.bestXI(squad) else { return nil }
        let sorted = r.xi.sorted { $0.proj != $1.proj ? $0.proj > $1.proj : $0.id < $1.id }
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

    // fixture grid helper — reads the cached engine instead of building one
    func gridFixtures(teamId: Int, gws: [Int]) -> [[FixtureInfo]] {
        guard let eng = engine else { return gws.map { _ in [] } }
        return gws.map { eng.teamFixtures(teamId, gw: $0) }
    }
}

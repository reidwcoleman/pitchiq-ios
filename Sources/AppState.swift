import SwiftUI

/// Everything the app derives from one set of projections, computed once on a
/// background task and handed to the views ready to draw. Views used to do this
/// work inside `body` — the fixture grid rebuilt a whole projection engine per
/// team row — which is why scrolling stuttered.
struct Insights {
    var players: [Player] = []
    var squad: SquadResult?
    var plan: SeasonPlan?
    var board = Advisor.TransferBoard()
    var audit: [Advisor.SquadCheck] = []
    var captains: [Advisor.CaptainPick] = []
    var differentials: [Advisor.Differential] = []
    var valuePicks: [Player] = []
    var template: [Player] = []
    var risers: [Advisor.PriceMove] = []
    var fallers: [Advisor.PriceMove] = []

    /// How the recommended squad was arrived at: each value profile that was
    /// tried and what it actually scored over a simulated season.
    struct Trial: Identifiable {
        var id: String { profile }
        let profile: String
        let blurb: String
        let points: Double
    }
    var openingTrials: [Trial] = []
    var chosenProfile = ""
}

@MainActor
final class AppState: ObservableObject {
    enum Phase { case loading, ready, error(String) }

    @Published var phase: Phase = .loading
    @Published var boot: Bootstrap?
    @Published var fixtures: [APIFixture] = []
    @Published var insights = Insights()
    @Published var lastUpdated: Date?
    /// Prior-season form for every player. Empty until the first fetch lands;
    /// the projections work without it and get materially better with it.
    @Published var pastForm = PastFormBook()
    /// Per-gameweek minutes over the last few weeks — the rotation signal a
    /// season aggregate cannot carry.
    @Published var recentMinutes = RecentMinutes()
    /// The gameweek in progress: every player's points as they are scored.
    @Published var live = LiveBook()
    @Published var liveSquad = LiveSquad()
    @Published var liveRefreshing = false
    @Published var refreshing = false
    /// A rebuild is in flight but the previous answer is still on screen. The
    /// old build swapped the whole team view for a spinner on every settings
    /// change, which made a 40 ms recomputation feel like a page load.
    @Published var working = false

    @Published var gwFrom = 1
    @Published var horizon = 6 { didSet { if horizon != oldValue { rebuild() } } }
    @Published var budget = 100.0
    @Published var fitOnly = true { didSet { if fitOnly != oldValue { rebuild() } } }

    /// The user's connected FPL team, if they've linked one.
    @Published var team: TeamState?
    @Published var importing = false
    @Published var importError: String?

    /// Manual edits to the recommended squad, when no team is connected.
    @Published var customSquadIds: [Int]?

    var players: [Player] { insights.players }
    var squad: SquadResult? { insights.squad }
    var plan: SeasonPlan? { insights.plan }
    var teams: [Int: FPLTeam] = [:]

    var planWindow: Int { max(38 - gwFrom + 1, 1) }
    var isPreseason: Bool { !(boot?.events.contains { $0.finished } ?? false) }
    var gwOptions: [GWEvent] { boot?.events ?? [] }
    var isEdited: Bool { customSquadIds != nil }
    var isConnected: Bool { team != nil }

    /// Where the fifteen on screen comes from, for labelling.
    var squadSource: String {
        if let t = team { return t.teamName.uppercased() }
        if customSquadIds != nil { return "YOUR TEAM" }
        return "OPTIMAL XV"
    }

    // MARK: - persistence

    private enum Key {
        static let custom = "customSquadIds"
        static let committed = "committedSquadIds"
        static let team = "connectedTeam"
    }

    /// The fifteen the app last showed. Fed back into the solver as the
    /// incumbent so an unchanged week produces an unchanged team.
    private var committedSquadIds: [Int]?

    // MARK: - caches

    private var engine: ProjectionEngine?
    private var engineGw: Int?
    private var modelPlayers: [Player] = []        // horizon-independent per-GW model
    private var cachedDoubleGws: Set<Int>?
    private var cachedPlan: SeasonPlan?
    private var cachedPlanKey: PlanKey?
    private var generation = 0

    private struct PlanKey: Equatable {
        let gwFrom: Int
        let budget: Int
        let fitOnly: Bool
        let custom: [Int]?
        let team: [Int]?
        let dataStamp: Int
    }

    /// Gameweeks where at least one club plays twice.
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

    init() {
        let d = UserDefaults.standard
        customSquadIds = d.array(forKey: Key.custom) as? [Int]
        committedSquadIds = d.array(forKey: Key.committed) as? [Int]
        if let data = d.data(forKey: Key.team) {
            team = try? JSONDecoder().decode(TeamState.self, from: data)
        }
    }

    // MARK: - the live gameweek

    /// The gameweek being played, which is not the one being planned: FPL keeps
    /// a week "current" from its deadline until the next one's, so between
    /// Sunday night and Friday the app plans for GW n+1 while GW n is still the
    /// one with points on it.
    var liveGw: Int {
        boot?.events.first { $0.is_current == true }?.id
            ?? boot?.events.last { $0.finished }?.id
            ?? max(gwFrom - 1, 1)
    }

    /// The next deadline, and how long there is left. The single most useful
    /// number in fantasy football, and the app did not show it anywhere.
    var nextDeadline: (gw: Int, date: Date)? {
        let now = Date()
        let upcoming = (boot?.events ?? [])
            .compactMap { e -> (Int, Date)? in e.deadline.map { (e.id, $0) } }
            .filter { $0.1 > now }
            .min { $0.1 < $1.1 }
        return upcoming.map { (gw: $0.0, date: $0.1) }
    }

    var liveFixtures: [APIFixture] {
        fixtures.filter { $0.event == liveGw }
            .sorted { ($0.kickoff ?? .distantFuture) < ($1.kickoff ?? .distantFuture) }
    }

    var fixtureStates: [Int: MatchState] {
        var out: [Int: MatchState] = [:]
        for f in fixtures where f.id != nil { out[f.id!] = f.liveState }
        return out
    }

    /// True while at least one match in the current gameweek is being played.
    var matchesInPlay: Bool { liveFixtures.contains { $0.liveState.isLive } }

    /// Live points for the whole gameweek, refreshed while matches are on.
    func refreshLive() async {
        guard boot != nil, !liveRefreshing else { return }
        let gw = liveGw
        liveRefreshing = true
        defer { liveRefreshing = false }
        guard let payload = try? await FPLService.fetchLive(gw: gw) else { return }
        live = LiveBook(gw: gw, live: payload, fixtures: fixtures)
        // The picks that are actually on the pitch this week may be a gameweek
        // ahead of the ones the planner is working from.
        if let t = team, t.gw != gw || t.picks == nil,
           let picks = try? await FPLService.fetchPicks(entryId: t.entryId, gw: gw) {
            var updated = t
            updated.picks = picks.squadPicks
            updated.activeChip = picks.active_chip
            updated.transferCost = picks.entry_history?.event_transfers_cost ?? 0
            team = updated
        }
        rebuildLiveSquad()
    }

    func rebuildLiveSquad() {
        guard let picks = team?.picks, !picks.isEmpty, !live.isEmpty else {
            liveSquad = LiveSquad(); return
        }
        var byId: [Int: Player] = [:]
        for p in players { byId[p.id] = p }
        liveSquad = LiveSquad(picks: picks, players: byId, live: live,
                              fixtures: fixtureStates,
                              transferCost: team?.transferCost ?? 0,
                              chip: team?.activeChip)
    }

    func teamShort(_ id: Int) -> String { teams[id]?.short_name ?? "?" }
    func teamCode(_ id: Int) -> Int? { teams[id]?.code }
    func teamName(_ id: Int) -> String { teams[id]?.name ?? "?" }

    // MARK: - loading

    /// Draw from disk first, and only go to the network when the cache is
    /// actually stale. A cold launch used to download 1.3 MB and re-decode it
    /// before showing anything, every single time.
    func load() async {
        if boot == nil {
            let cached = await Task.detached(priority: .userInitiated) {
                (DataCache.read(), DataCache.readPastForm(), DataCache.readRecentMinutes())
            }.value
            if let book = cached.1 { pastForm = book }
            if let r = cached.2 { recentMinutes = r }
            if let payload = cached.0 {
                apply(boot: payload.boot, fixtures: payload.fixtures, stamp: payload.fetched)
            }
        }
        let age = lastUpdated.map { Date().timeIntervalSince($0) } ?? .infinity
        // FPL prices move once a day and injury news a few times a day; a
        // fifteen-minute cache costs nothing and removes the wait entirely.
        if age > 15 * 60 { await refresh() }
        // testing hook, alongside `-tab`: launch with `-entry N` to connect a
        // team without typing an id into the simulator
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-entry"), i + 1 < args.count,
           let id = Int(args[i + 1]), team?.entryId != id {
            await connect(entryId: id)
        }
        await refreshLive()
        await refreshRecentMinutesIfNeeded()
        await refreshPastFormIfNeeded()
    }

    /// One request per recent gameweek, and only when the gameweek has moved
    /// on — the answer cannot change until a match is played.
    private func refreshRecentMinutesIfNeeded() async {
        let latest = liveGw
        guard latest >= 1, recentMinutes.throughGw < latest || recentMinutes.isEmpty else { return }
        let fetched = await FPLService.fetchRecentMinutes(through: latest)
        guard !fetched.isEmpty else { return }
        recentMinutes = fetched
        DataCache.write(recent: fetched)
        engine = nil
        engineGw = nil
        modelPlayers = []
        cachedPlanKey = nil
        rebuild()
    }

    /// Six hundred requests, so this runs at most once a week — and once
    /// whenever the player list has moved on far enough that the cache no
    /// longer covers it (a January window, or a fresh install mid-season).
    private func refreshPastFormIfNeeded() async {
        guard let boot else { return }
        let ids = boot.elements.map(\.id)
        let covered = ids.filter { pastForm[$0] != nil }.count
        let stale = Date().timeIntervalSince(pastForm.built) > 7 * 24 * 3600
        // Roughly a fifth of any squad list is academy players with no senior
        // record, so full coverage is never expected — half is the signal that
        // the cache is genuinely for a different season.
        guard stale || Double(covered) < Double(ids.count) * 0.5 else { return }
        let book = await FPLService.fetchPastForm(ids: ids)
        guard !book.isEmpty else { return }
        pastForm = book
        engine = nil
        engineGw = nil
        modelPlayers = []
        cachedPlanKey = nil
        rebuild()
    }

    /// Fetch live data. Keeps whatever is on screen if the network fails.
    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            let (boot, fixtures) = try await FPLService.fetch()
            apply(boot: boot, fixtures: fixtures, stamp: Date())
            if let t = team, Date().timeIntervalSince(t.fetched) > 30 * 60 {
                await connect(entryId: t.entryId, silent: true)
            }
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

    func refreshIfStale() {
        Task { await refreshLive() }
        guard let last = lastUpdated, Date().timeIntervalSince(last) > 15 * 60 else { return }
        Task { await refresh() }
    }

    // MARK: - connecting an FPL team

    func connect(entryId: Int, silent: Bool = false) async {
        guard let boot else { return }
        if !silent { importing = true; importError = nil }
        defer { importing = false }
        do {
            let state = try await FPLService.fetchTeam(entryId: entryId, currentGw: gwFrom, boot: boot)
            team = state
            customSquadIds = nil
            UserDefaults.standard.removeObject(forKey: Key.custom)
            if let data = try? JSONEncoder().encode(state) {
                UserDefaults.standard.set(data, forKey: Key.team)
            }
            rebuild()
        } catch {
            if !silent { importError = error.localizedDescription }
        }
    }

    func disconnect() {
        team = nil
        UserDefaults.standard.removeObject(forKey: Key.team)
        rebuild()
    }

    // MARK: - rebuild

    func rebuild() {
        guard let boot else { return }
        generation += 1
        let gen = generation

        let eng: ProjectionEngine
        if let e = engine, engineGw == gwFrom {
            eng = e
        } else {
            eng = ProjectionEngine(boot: boot, fixtures: fixtures, gwFrom: gwFrom,
                                   horizon: horizon, pastForm: pastForm,
                                   recent: recentMinutes)
            engine = eng
            engineGw = gwFrom
            modelPlayers = []
        }

        if insights.players.isEmpty { phase = .loading } else { working = true }

        let budgetM = budget
        let fit = fitOnly
        let gwFrom = gwFrom
        let horizon = horizon
        let window = planWindow
        let customIds = customSquadIds
        let connected = team
        let incumbent = committedSquadIds
        let dgws = doubleGws
        let cachedModel = modelPlayers
        let managers = boot.total_players ?? 11_000_000
        let chipsMeta = (boot.chips ?? []).map {
            ChipMeta(name: $0.name, start: $0.start_event, stop: $0.stop_event)
        }
        // Changing the horizon changes only the headline number shown against
        // each player — per-gameweek projections, and therefore the season plan,
        // are unaffected. Reuse the plan rather than re-running the single most
        // expensive computation in the app for a display-only change.
        let key = PlanKey(gwFrom: gwFrom, budget: Int(budget * 10), fitOnly: fit,
                          custom: customIds, team: connected?.squadIds,
                          dataStamp: boot.elements.count)
        let reusablePlan = (cachedPlanKey == key) ? cachedPlan : nil

        Task.detached(priority: .userInitiated) {
            let players: [Player] = cachedModel.isEmpty
                ? eng.buildPlayers(totalManagers: managers)
                : ProjectionEngine.reHorizon(cachedModel, gwFrom: gwFrom,
                                             horizon: horizon, engine: eng)
            let baseModel = cachedModel.isEmpty ? players : cachedModel

            let result = Self.compute(
                players: players, gwFrom: gwFrom, horizon: horizon, window: window,
                budgetM: budgetM, fitOnly: fit, customIds: customIds, team: connected,
                incumbent: incumbent, chipsMeta: chipsMeta, doubleGws: dgws,
                reusablePlan: reusablePlan)

            await MainActor.run {
                guard gen == self.generation else { return }   // a newer rebuild won
                if result.staleCustom {
                    self.customSquadIds = nil
                    UserDefaults.standard.removeObject(forKey: Key.custom)
                }
                self.modelPlayers = baseModel
                self.insights = result.insights
                if let plan = result.insights.plan {
                    self.cachedPlan = plan
                    self.cachedPlanKey = key
                }
                // Remember the fifteen so the next rebuild keeps it unless a
                // materially better squad exists.
                if self.team == nil, self.customSquadIds == nil,
                   let ids = result.insights.squad?.squad.map(\.id) {
                    self.committedSquadIds = ids
                    UserDefaults.standard.set(ids, forKey: Key.committed)
                }
                self.working = false
                self.phase = .ready
                self.rebuildLiveSquad()
            }
        }
    }

    /// How much better a new squad has to be before the app swaps the team it
    /// is already showing. Projections wobble by tenths of a point every time
    /// prices move; without this the recommended fifteen churned on every
    /// refresh and the app looked like it had no conviction.
    /// Measured in simulated points across the whole remaining season, so it is
    /// directly interpretable: a new squad has to be worth at least this many
    /// points between now and GW38 before it is worth the churn.
    static let switchMargin = 12.0

    private struct ComputeResult {
        var insights: Insights
        var staleCustom: Bool
    }

    nonisolated private static func compute(
        players: [Player], gwFrom: Int, horizon: Int, window: Int,
        budgetM: Double, fitOnly: Bool, customIds: [Int]?, team: TeamState?,
        incumbent: [Int]?, chipsMeta: [ChipMeta], doubleGws: Set<Int>,
        reusablePlan: SeasonPlan?
    ) -> ComputeResult {
        var out = Insights()
        out.players = players

        // --- which fifteen are we advising on
        //
        // Exactly one squad drives every screen. An earlier build optimised one
        // squad for the ranking horizon on the Team tab and let the planner
        // build a different, season-weighted one, so the transfer board audited
        // a team the pitch never showed.
        var squadIds: [Int]?
        var staleCustom = false
        var start = PlanStart()
        if let t = team {
            squadIds = t.squadIds
            start = PlanStart(squadIds: t.squadIds, bank: t.bank, budget: t.budget,
                              freeTransfers: t.freeTransfers, chipsUsed: Set(t.chipsUsed),
                              isUserTeam: true)
        } else if let ids = customIds {
            if buildSquad(ids: ids, players: players) != nil {
                let budgetTenths = Int(budgetM * 10)
                let spent = ids.compactMap { id in players.first { $0.id == id }?.cost }.reduce(0, +)
                squadIds = ids
                start = PlanStart(squadIds: ids, bank: max(budgetTenths - spent, 0),
                                  budget: budgetTenths, freeTransfers: 1, isUserTeam: true)
            } else {
                staleCustom = true      // a saved player no longer exists
            }
        }

        if squadIds == nil {
            // Nothing connected or edited: build a candidate squad under each
            // value profile, simulate the rest of the season from each, and keep
            // whichever actually scores most — anchored to whatever the app
            // showed last so the answer doesn't churn between visits.
            let opening = Planner.bestOpeningSquad(
                players: players, budgetM: budgetM, fitOnly: fitOnly,
                from: gwFrom, end: 38, incumbent: incumbent,
                incumbentMargin: switchMargin)
            squadIds = opening?.ids
            out.openingTrials = opening?.trials.map {
                Insights.Trial(profile: $0.profile, blurb: $0.blurb, points: $0.points)
            } ?? []
            out.chosenProfile = opening?.profile ?? ""
            let budgetTenths = Int(budgetM * 10)
            let spent = squadIds?.compactMap { id in players.first { $0.id == id }?.cost }
                .reduce(0, +) ?? budgetTenths
            start = PlanStart(squadIds: squadIds, bank: max(budgetTenths - spent, 0),
                              budget: budgetTenths, freeTransfers: 0, isUserTeam: false)
        }
        if let ids = squadIds {
            out.squad = buildSquad(ids: ids, players: players, displayGw: gwFrom)
        }

        // --- the season plan
        out.plan = reusablePlan ?? Planner.plan(
            players: players, fitOnly: fitOnly, from: gwFrom, window: window,
            start: start, chipsMeta: chipsMeta, doubleGws: doubleGws)

        // --- decision tools
        let held = out.squad?.squad ?? []
        let bank = start.bank
        if !held.isEmpty {
            out.board = Advisor.transferBoard(squad: held, players: players, from: gwFrom,
                                              horizon: horizon, bank: bank, fitOnly: fitOnly)
            out.audit = Advisor.audit(squad: held, gw: gwFrom, bank: bank, players: players)
        }
        out.captains = Advisor.captainBoard(squad: held.isEmpty ? nil : held,
                                            players: players, gw: gwFrom)
        out.differentials = Advisor.differentials(players)
        out.valuePicks = Advisor.valuePicks(players)
        out.template = Advisor.template(players)
        let watch = Advisor.priceWatch(players)
        out.risers = watch.rising
        out.fallers = watch.falling
        return ComputeResult(insights: out, staleCustom: staleCustom)
    }

    // MARK: - manual team editing

    func applySwap(out: Player, inn: Player) {
        guard let current = squad?.squad else { return }
        let ids = current.map { $0.id == out.id ? inn.id : $0.id }
        customSquadIds = ids
        UserDefaults.standard.set(ids, forKey: Key.custom)
        rebuild()
    }

    func resetToAI() {
        customSquadIds = nil
        committedSquadIds = nil
        UserDefaults.standard.removeObject(forKey: Key.custom)
        UserDefaults.standard.removeObject(forKey: Key.committed)
        rebuild()
    }

    /// Legal replacements for `out` given the current squad.
    func swapCandidates(for out: Player) -> [Player] {
        guard let current = squad?.squad else { return [] }
        let ids = Set(current.map(\.id))
        let budgetTenths = team?.budget ?? Int((budget * 10).rounded())
        let costWithoutOut = current.reduce(0) { $0 + $1.cost } - out.cost
        var clubs: [Int: Int] = [:]
        for p in current where p.id != out.id { clubs[p.team, default: 0] += 1 }
        return players.filter { p in
            p.pos == out.pos && !ids.contains(p.id)
                && costWithoutOut + p.cost <= budgetTenths
                && clubs[p.team, default: 0] < 3
        }
        .sorted { $0.proj != $1.proj ? $0.proj > $1.proj : $0.id < $1.id }
    }

    nonisolated static func buildSquad(ids: [Int], players: [Player],
                                       displayGw: Int? = nil) -> SquadResult? {
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

    // MARK: - fixture helpers (read the cached engine; never build one)

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

    func gridFixtures(teamId: Int, gws: [Int]) -> [[FixtureInfo]] {
        guard let eng = engine else { return gws.map { _ in [] } }
        return gws.map { eng.teamFixtures(teamId, gw: $0) }
    }

    func teamForm(_ teamId: Int) -> ProjectionEngine.TeamForm? { engine?.form(of: teamId) }
}

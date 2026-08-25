import Foundation

let sp = "/private/tmp/claude-501/-Users-reidcoleman/04fba495-9dc0-4407-9e4b-42b78aeb9a8d/scratchpad"
func data(_ f: String) -> Data { try! Data(contentsOf: URL(fileURLWithPath: "\(sp)/\(f)")) }
let dec = JSONDecoder()
let boot = try! dec.decode(Bootstrap.self, from: data("bootstrap.json"))
let fixtures = try! dec.decode([APIFixture].self, from: data("fixtures.json"))
let rawPast = try! dec.decode([String: [PastSeason]].self, from: data("past_all.json"))
var book = PastFormBook()
for (k, v) in rawPast { if let id = Int(k) { let f = PastForm(seasons: v); if !f.isEmpty { book.byId[id] = f } } }
print("past forms:", book.byId.count)

if let w = CommandLine.arguments.firstIndex(of: "--why"), w + 1 < CommandLine.arguments.count {
    let name = CommandLine.arguments[w + 1]
    let gw = boot.events.first { $0.is_next }?.id ?? 2
    let eng = ProjectionEngine(boot: boot, fixtures: fixtures, gwFrom: gw, horizon: 6, pastForm: book)
    guard let el = boot.elements.first(where: { $0.web_name.lowercased().contains(name.lowercased()) })
    else { print("no such player"); exit(1) }
    let r = eng.rates(for: el)
    let fx = eng.contexts(el.team, gw: gw).first ?? Eval.neutral
    let c = r.components(fx)
    let hist = book[el.id]
    print("\n\(el.web_name)  (pos \(el.element_type), £\(Double(el.now_cost)/10)m)")
    print(String(format: "  this season   %d mins, %d starts, %d pts", el.minutes, el.starts ?? 0, el.total_points))
    for line in hist?.lines.prefix(3) ?? [] {
        print(String(format: "  %@       %.0f mins, %.0f starts, %.0f pts  (%.2f per 90)",
                     line.name as NSString, line.minutes, line.starts, line.points, line.per90))
    }
    print(String(format: "  minutes model  pPlay %.2f  p60 %.2f  minShare %.2f (%.0f mins/match)",
                 r.pPlay, r.p60, r.minShare, r.minShare * 90))
    print(String(format: "  anchor         %.2f pts per appearance × %.2f = %.2f per gameweek",
                 r.ppg, max(r.pPlay, 0.3), r.ppg * max(r.pPlay, 0.3)))
    print(String(format: "  rate model     appearance %.2f  goals %.2f  assists %.2f  CS %.2f  defcon %.2f  bonus %.2f",
                 c.appearance, c.goals, c.assists, c.cleanSheet, c.defcon, c.bonus))
    print(String(format: "  blend          model %.2f × %.2f  +  anchor %.2f × %.2f  →  %.2f",
                 c.model, r.modelShare, c.anchor, 1 - r.modelShare, c.final))
    exit(0)
}

if CommandLine.arguments.contains("--chips") {
    let gw = boot.events.first { $0.is_next }?.id ?? 2
    let eng = ProjectionEngine(boot: boot, fixtures: fixtures, gwFrom: gw, horizon: 6, pastForm: book)
    let all = eng.buildPlayers(totalManagers: boot.total_players ?? 11_000_000)
    var counts: [Int: [Int: Int]] = [:]
    for f in fixtures {
        guard let g = f.event else { continue }
        counts[g, default: [:]][f.team_h, default: 0] += 1
        counts[g, default: [:]][f.team_a, default: 0] += 1
    }
    let dgws = Set(counts.filter { $0.value.values.contains { $0 >= 2 } }.keys)
    let blanks = Set((gw...38).filter { g in (counts[g]?.count ?? 0) < 20 })
    print("\n=== the fixture list ===")
    print("  double gameweeks: \(dgws.sorted().map(String.init).joined(separator: ", "))")
    print("  gameweeks where some clubs don't play: \(blanks.sorted().map(String.init).joined(separator: ", "))")

    let chips = (boot.chips ?? []).map { ChipMeta(name: $0.name, start: $0.start_event, stop: $0.stop_event) }
    print("\n=== chips the game offers ===")
    for c in chips { print("  \(c.name)  GW\(c.start)–\(c.stop)") }

    guard let opening = Optimizer.optimize(players: all, budgetM: 100, fitOnly: true) else { exit(1) }
    let start = PlanStart(squadIds: opening.squad.map(\.id), bank: 0, budget: 1000,
                          freeTransfers: 1, isUserTeam: false)
    guard let plan = Planner.plan(players: all, fitOnly: true, from: gw, window: 38 - gw + 1,
                                  start: start, chipsMeta: chips, doubleGws: dgws) else {
        print("no plan"); exit(1)
    }
    print("\n=== what the planner schedules ===")
    if plan.chips.isEmpty { print("  nothing") }
    for c in plan.chips {
        print(String(format: "  %-9@ GW%-3d gain %+5.1f%@", c.chip as NSString, c.gw, c.gain,
                     (c.forced ? "  (forced — the window was closing)" : "") as NSString))
    }
    guard let bare = Planner.plan(players: all, fitOnly: true, from: gw, window: 38 - gw + 1,
                                  start: start, chipsMeta: [], doubleGws: dgws) else { exit(1) }
    print(String(format: "\n  season total with the chips scheduled: %.0f", plan.totalPts))
    print(String(format: "  season total with no chips at all:     %.0f", bare.totalPts))
    print(String(format: "  the chips are worth %+.0f points", plan.totalPts - bare.totalPts))

    let scheduled = Set(plan.chips.map { "\($0.chip)-\($0.gw <= 19 ? 19 : 38)" })
    let offered = Set(chips.map { "\($0.name)-\($0.stop)" })
    let missed = offered.subtracting(scheduled)
    print("\n  scheduled \(scheduled.count) of \(offered.count)")
    if !missed.isEmpty { print("  NEVER PLAYED: \(missed.sorted().joined(separator: ", "))") }
    exit(0)
}

if CommandLine.arguments.contains("--recency") {
    let raw = try! JSONSerialization.jsonObject(with: data("bootstrap.json")) as! [String: Any]
    let eval = Eval(bootJSON: raw, boot: boot, fixtures: fixtures, rawPast: rawPast)
    let livePayload = try! dec.decode(EventLive.self, from: data("live1.json"))
    var stats: [Int: LiveStats] = [:]
    var minutes: [Int: Int] = [:]
    for e in livePayload.elements {
        stats[e.id] = e.stats
        if e.stats.minutes > 0 { minutes[e.id] = e.stats.minutes }
    }
    var recent = RecentMinutes()
    recent.season = 2026
    recent.absorb(gw: 1, minutes: minutes)
    RecencyAudit(eval: eval, book: book, recent: recent).report(gw: 1, live: stats)
    exit(0)
}

if CommandLine.arguments.contains("--policy") {
    let gw = boot.events.first { $0.is_next }?.id ?? 2
    let eng = ProjectionEngine(boot: boot, fixtures: fixtures, gwFrom: gw, horizon: 6, pastForm: book)
    let all = eng.buildPlayers(totalManagers: boot.total_players ?? 11_000_000)
    let seasons = 200

    // --- squad construction: does pricing the bench and the vice-captain
    //     properly actually win points, or does it just move players around?
    var oldWay = SquadSolver.Weights()
    oldWay.bench = 0.12; oldWay.autosub = 0; oldWay.vice = 0
    let shipped = Optimizer.optimize(players: all, budgetM: 100, fitOnly: true)!
    let before = Optimizer.optimize(players: all, budgetM: 100, fitOnly: true,
                                    weightOverride: oldWay)!
    print("\nopening fifteen, old scoring:  " + before.squad.map(\.name).joined(separator: ", "))
    print("opening fifteen, new scoring:  " + shipped.squad.map(\.name).joined(separator: ", "))
    print(String(format: "  bench cost: old £%.1fm, new £%.1fm",
                 Double(before.bench.reduce(0) { $0 + $1.cost }) / 10,
                 Double(shipped.bench.reduce(0) { $0 + $1.cost }) / 10))

    let greedy = PolicyBench.Rule(name: "greedy singles", usePairs: false, maxMoves: 4)
    PolicyBench.compareSquads(players: all, squads: [
        ("picked the old way", before.squad.map(\.id)),
        ("bench + vice priced properly", shipped.squad.map(\.id)),
    ], budget: 1000, from: gw, end: 38, seasons: seasons, rule: greedy)

    // --- the decision constants, swept against simulated seasons from a
    //     squad that needs work: the case a real user is actually in
    let byOwnership = all.map { p -> Player in var c = p; c.proj = c.own; return c }
    guard let rough = Optimizer.optimize(players: byOwnership, budgetM: 100, fitOnly: true)
    else { exit(0) }
    print("\n--- chips: are the thresholds right? ---")
    func rule(_ name: String, chips: Bool = true, bb: Double = Planner.chipThreshold("bboost"),
              tc: Double = Planner.chipThreshold("3xc"), wc: Double = Planner.chipThreshold("wildcard"),
              fh: Double = Planner.chipThreshold("freehit"), panic: Int = 3) -> PolicyBench.Rule {
        var r = PolicyBench.Rule(name: name, usePairs: false, maxMoves: 4)
        r.chips = chips; r.bbBar = bb; r.tcBar = tc; r.wcBar = wc; r.fhBar = fh
        r.chipPanic = panic
        return r
    }
    PolicyBench.compare(players: all, start: rough.squad.map(\.id), budget: 1000,
                        from: gw, end: 38, seasons: 300, rules: [
                            rule("no chips at all", chips: false),
                            rule("shipped thresholds"),
                            rule("play them immediately", bb: 0, tc: 0, wc: 0, fh: 0),
                            rule("twice as fussy", bb: 16, tc: 10, wc: 16, fh: 24),
                            rule("half as fussy", bb: 4, tc: 2.5, wc: 4, fh: 6),
                            rule("hold to the deadline", bb: 999, tc: 999, wc: 999, fh: 999),
                        ])
    exit(0)
}

if CommandLine.arguments.contains("--compare") {
    let raw = try! JSONSerialization.jsonObject(with: data("bootstrap.json")) as! [String: Any]
    let eval = Eval(bootJSON: raw, boot: boot, fixtures: fixtures, rawPast: rawPast)
    var old = Tuning.default
    old.modelShare = 0.62; old.modelShareFull = 0.62
    old.minutesRecency = [1.0, 0.22, 0.06]
    var noGapFix = Tuning.default          // new defaults, for reference
    print("\n=== configuration comparison (mean over three replayed seasons) ===")
    print("  config                    rho     top50   squad   objective")
    for (name, t) in [("before this session", old), ("shipped now", noGapFix)] {
        var rho = 0.0, top = 0.0, squad = 0.0
        for season in Eval.seasons {
            let m = eval.measure(t, on: season)
            rho += m.rho; top += m.top50; squad += m.squad
        }
        let n = Double(Eval.seasons.count)
        print(String(format: "  %@%.3f   %.3f   %.0f    %.4f",
                     name.padding(toLength: 26, withPad: " ", startingAt: 0) as NSString,
                     rho / n, top / n, squad / n, (0.5 * top + 0.5 * rho) / n))
    }
    exit(0)
}

if CommandLine.arguments.contains("--mins") {
    let raw = try! JSONSerialization.jsonObject(with: data("bootstrap.json")) as! [String: Any]
    let eval = Eval(bootJSON: raw, boot: boot, fixtures: fixtures, rawPast: rawPast)
    var flat = Tuning.default; flat.minutesRecency = [1.0, 0.0, 0.0]
    var mild = Tuning.default; mild.minutesRecency = [1.0, 0.10, 0.0]
    var wide = Tuning.default; wide.minutesRecency = [1.0, 0.45, 0.20]
    eval.minutesReport([("shipped [1,.22,.06]", .default),
                        ("last season only", flat),
                        ("[1,.10,0]", mild),
                        ("[1,.45,.20]", wide)])
    exit(0)
}

if CommandLine.arguments.contains("--diagnose") {
    let raw = try! JSONSerialization.jsonObject(with: data("bootstrap.json")) as! [String: Any]
    Eval(bootJSON: raw, boot: boot, fixtures: fixtures, rawPast: rawPast).diagnose(tuning: .default)
    exit(0)
}

if CommandLine.arguments.contains("--sweep") {
    let raw = try! JSONSerialization.jsonObject(with: data("bootstrap.json")) as! [String: Any]
    Eval(bootJSON: raw, boot: boot, fixtures: fixtures, rawPast: rawPast).sweep()
    exit(0)
}

if CommandLine.arguments.contains("--tune") {
    let raw = try! JSONSerialization.jsonObject(with: data("bootstrap.json")) as! [String: Any]
    let eval = Eval(bootJSON: raw, boot: boot, fixtures: fixtures, rawPast: rawPast)
    if CommandLine.arguments.contains("--cv") { eval.crossValidate() }
    let fitted = eval.fit()
    print("\n--- fitted tuning ---")
    print("  recency          \(fitted.recency)")
    print("  minutesRecency   \(fitted.minutesRecency)")
    print("  priorCap         \(fitted.priorCap)")
    print("  credHalf         \(fitted.credHalf)")
    print("  modelShare       \(fitted.modelShare)")
    print("  minutesPriorScale \(fitted.minutesPriorScale)")
    print("  agePenalty/peak  \(fitted.agePenalty) / \(fitted.peakAge)")
    print("  minsAgePen/peak  \(fitted.minutesAgePenalty) / \(fitted.minutesPeakAge)")
    for season in Eval.seasons { eval.report(target: season, tuning: fitted) }
    exit(0)
}

if CommandLine.arguments.contains("--fullplay") {
    let gw = boot.events.first { $0.is_next }?.id ?? 2
    let eng = ProjectionEngine(boot: boot, fixtures: fixtures, gwFrom: gw, horizon: 6, pastForm: book)
    let all = eng.buildPlayers(totalManagers: boot.total_players ?? 11_000_000)
    guard let opening = Optimizer.optimize(players: all, budgetM: 100, fitOnly: true) else { exit(1) }

    // Calibrate the injury model against what really happened: across three
    // backtested seasons a squad expected to cover 85% of the available
    // minutes covered about 70%, so a realised share near 0.82 of expectation.
    print("\n=== calibrating the simulator's injuries to the historical record ===")
    var chosen = SeasonSim.injuryChancePerGw
    for rate in [0.01, 0.02, 0.035, 0.05, 0.07, 0.09, 0.12] {
        SeasonSim.injuryChancePerGw = rate
        let sim = SeasonSim(players: all, from: gw, end: 38)
        let share = sim.realisedMinuteShare()
        print(String(format: "  injury chance %.3f/GW → squads play %.0f%% of the minutes expected of them", rate, share * 100))
        if abs(share - 0.82) < abs({ () -> Double in
            SeasonSim.injuryChancePerGw = chosen
            return SeasonSim(players: all, from: gw, end: 38).realisedMinuteShare()
        }() - 0.82) { chosen = rate }
        SeasonSim.injuryChancePerGw = rate
    }
    SeasonSim.injuryChancePerGw = chosen
    print(String(format: "  using %.3f", chosen))

    print("\n=== what the machinery the backtest could not use is worth ===")
    PolicyBench.compare(players: all, start: opening.squad.map(\.id), budget: 1000,
                        from: gw, end: 38, seasons: 400, rules: [
                            PolicyBench.Rule(name: "frozen squad, as backtested", usePairs: false,
                                             maxMoves: 0, enabled: false),
                            PolicyBench.Rule(name: "transfers, as the app plans them",
                                             usePairs: false, maxMoves: 4),
                        ])
    exit(0)
}

if CommandLine.arguments.contains("--seasonsweep") {
    let raw = try! JSONSerialization.jsonObject(with: data("bootstrap.json")) as! [String: Any]
    let eval = Eval(bootJSON: raw, boot: boot, fixtures: fixtures, rawPast: rawPast)
    let back = Backtest(eval: eval)
    print("\n  15 squads per setting: three seasons × five budgets")
    print("  knob / value       season points ± se     rho    top50")
    for knob in Eval.knobs {
        var any = false
        for value in knob.values {
            var t = Tuning.default
            knob.apply(&t, value)
            let m = back.meanPoints(tuning: t)
            guard m.points > 0 else { continue }
            var rhos: [Double] = [], tops: [Double] = []
            for season in Eval.seasons {
                let s = eval.measure(t, on: season)
                rhos.append(s.rho); tops.append(s.top50)
            }
            if !any { print("\n\(knob.name)  (shipped \(knob.read(.default)))"); any = true }
            let mark = value == knob.read(.default) ? "  <- shipped" : ""
            print(String(format: "  %8.3f            %6.0f ± %4.0f      %.3f  %.3f%@", value,
                         m.points, m.spread,
                         rhos.reduce(0,+) / Double(rhos.count),
                         tops.reduce(0,+) / Double(tops.count), mark as NSString))
        }
    }
    exit(0)
}

if CommandLine.arguments.contains("--season") {
    let raw = try! JSONSerialization.jsonObject(with: data("bootstrap.json")) as! [String: Any]
    let eval = Eval(bootJSON: raw, boot: boot, fixtures: fixtures, rawPast: rawPast)
    let curveJSON = (try? JSONSerialization.jsonObject(with: data("rankcurve.json")))
        as? [String: [[Int]]] ?? [:]
    Backtest(eval: eval).report(tuning: .default,
                                curve: Backtest.RankCurve(json: curveJSON))
    exit(0)
}

if CommandLine.arguments.contains("--eval") {
    let raw = try! JSONSerialization.jsonObject(with: data("bootstrap.json")) as! [String: Any]
    let eval = Eval(bootJSON: raw, boot: boot, fixtures: fixtures, rawPast: rawPast)
    for season in ["2024/25", "2025/26"] { eval.report(target: season, tuning: .default) }
    exit(0)
}

let gw = boot.events.first { $0.is_next }?.id ?? 2
let usePast = CommandLine.arguments.contains("--past")
let eng = ProjectionEngine(boot: boot, fixtures: fixtures, gwFrom: gw, horizon: 6,
                           pastForm: usePast ? book : PastFormBook())
let players = eng.buildPlayers(totalManagers: boot.total_players ?? 11_000_000)
print("mode:", usePast ? "WITH prior seasons" : "current season only", "· gw", gw, "· players", players.count)

func line(_ p: Player) -> String {
    String(format: "%-16@ %-3@ %-4@ £%4.1f  perGW %5.2f  6gw %5.1f  mins %4.1f  ceil %4.1f haul %3.0f%% blank %3.0f%%",
           p.name as NSString, p.posShort as NSString, p.teamShort as NSString,
           Double(p.cost)/10, p.perGw, p.proj, p.expMins, p.ceiling, p.haulProb*100, p.blankProb*100)
}
print("\n— top 20 by per-GW —")
for p in players.sorted(by: { $0.perGw > $1.perGw }).prefix(20) { print(line(p)) }
print("\n— named —")
for n in ["Haaland","Palmer","Saka","Isak","Watkins","Gabriel","Raya","Semenyo","Mbeumo","Wood"] {
    if let p = players.filter({ $0.name == n }).max(by: { $0.perGw < $1.perGw }) { print(line(p)) }
}
print("\n— team ratings (attack / defence xG per match) —")
for t in boot.teams.sorted(by: { $0.id < $1.id }) {
    let f = eng.form(of: t.id)
    print(String(format: "%-4@ atk %.2f  def %.2f", t.short_name as NSString, f.attack, f.defence))
}
let gwTotal = players.reduce(0.0) { $0 + $1.projByGw.at(gw) }
print(String(format: "\nleague-wide GW%d projected points: %.0f  (a real gameweek pays out ~1000)", gw, gwTotal))
let byPos = [1,2,3,4].map { pp in players.filter { $0.pos == pp }.reduce(0.0) { $0 + $1.projByGw.at(gw) } }
print(String(format: "  GK %.0f  DEF %.0f  MID %.0f  FWD %.0f", byPos[0], byPos[1], byPos[2], byPos[3]))
let starters = players.sorted { $0.projByGw.at(gw) > $1.projByGw.at(gw) }.prefix(220)
print(String(format: "  top-220 mean %.2f", starters.reduce(0.0) { $0 + $1.projByGw.at(gw) } / 220))
let mean = players.filter { $0.expMins > 60 }.map(\.perGw)
print(String(format: "\nregular starters: n=%d mean perGW %.2f", mean.count, mean.reduce(0,+)/Double(max(mean.count,1))))

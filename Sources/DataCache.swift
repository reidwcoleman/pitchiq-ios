import Foundation

// MARK: - On-disk payload cache
// The FPL bootstrap is ~1.3 MB of JSON. Fetching it before drawing anything
// meant every cold launch waited on the network. We now persist the raw
// payloads and render from disk immediately, then refresh in the background.

enum DataCache {
    struct Payload {
        let boot: Bootstrap
        let fixtures: [APIFixture]
        let fetched: Date
    }

    private static let dir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let d = base.appendingPathComponent("PitchIQCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    private static var bootURL: URL { dir.appendingPathComponent("bootstrap.json") }
    private static var fixturesURL: URL { dir.appendingPathComponent("fixtures.json") }
    private static var pastURL: URL { dir.appendingPathComponent("pastform.json") }

    /// Decoded cached payload, or nil when there's nothing usable on disk.
    /// Runs off the main actor — decoding 1.3 MB is not free.
    static func read() -> Payload? {
        guard let bootData = try? Data(contentsOf: bootURL),
              let fixData = try? Data(contentsOf: fixturesURL) else { return nil }
        let dec = JSONDecoder()
        guard let boot = try? dec.decode(Bootstrap.self, from: bootData),
              let fixtures = try? dec.decode([APIFixture].self, from: fixData),
              !boot.elements.isEmpty else { return nil }
        let stamp = (try? FileManager.default
            .attributesOfItem(atPath: bootURL.path)[.modificationDate] as? Date) ?? nil
        return Payload(boot: boot, fixtures: fixtures, fetched: stamp ?? .distantPast)
    }

    static func write(boot: Data, fixtures: Data) {
        try? boot.write(to: bootURL, options: .atomic)
        try? fixtures.write(to: fixturesURL, options: .atomic)
    }

    // MARK: prior-season form
    //
    // Six hundred small requests, so this is cached hard: previous seasons are
    // finished and cannot change. It is re-fetched only when the file is more
    // than a week old, or when the squad list has moved on enough that a
    // meaningful number of players are missing from it.

    static func readPastForm() -> PastFormBook? {
        guard let data = try? Data(contentsOf: pastURL),
              let book = try? JSONDecoder().decode(PastFormBook.self, from: data),
              !book.isEmpty else { return nil }
        return book
    }

    static func write(pastForm book: PastFormBook) {
        guard let data = try? JSONEncoder().encode(book) else { return }
        try? data.write(to: pastURL, options: .atomic)
    }

    static var age: TimeInterval? {
        guard let d = try? FileManager.default
            .attributesOfItem(atPath: bootURL.path)[.modificationDate] as? Date else { return nil }
        return Date().timeIntervalSince(d)
    }
}

// MARK: - Fetching

enum FPLService {
    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 40
        cfg.waitsForConnectivity = false
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }()

    /// Fetch both payloads concurrently and persist them for the next launch.
    static func fetch() async throws -> (Bootstrap, [APIFixture]) {
        async let bootData = getData("https://fantasy.premierleague.com/api/bootstrap-static/")
        async let fixData = getData("https://fantasy.premierleague.com/api/fixtures/")
        let (b, f) = try await (bootData, fixData)
        let dec = JSONDecoder()
        let boot = try dec.decode(Bootstrap.self, from: b)
        let fixtures = try dec.decode([APIFixture].self, from: f)
        DataCache.write(boot: b, fixtures: f)
        return (boot, fixtures)
    }

    /// Prior-season digests for every player. Cheap to keep, expensive to
    /// rebuild, and the difference between a sane August projection and a
    /// nonsense one.
    static func fetchPastForm(ids: [Int]) async -> PastFormBook {
        let book = await PastFormService.fetch(ids: ids, session: session)
        if !book.isEmpty { DataCache.write(pastForm: book) }
        return book
    }

    // MARK: - a manager's own team
    //
    // All three endpoints are public — no login, no token. `picks` only exists
    // once a gameweek's deadline has passed, so a brand-new entry returns 404
    // until the season starts; that is reported as a readable message rather
    // than an error.

    enum ImportError: LocalizedError {
        case notFound
        case noPicksYet(Int)
        case badResponse

        var errorDescription: String? {
            switch self {
            case .notFound:
                return "No FPL team with that ID. It's the number in the URL when you view your team on the FPL site: fantasy.premierleague.com/entry/YOUR-ID/event/1"
            case .noPicksYet(let gw):
                return "That team exists, but FPL hasn't published its picks yet — they go public after the GW\(gw) deadline. Try again once the season is under way."
            case .badResponse:
                return "FPL returned something unexpected. Try again in a moment."
            }
        }
    }

    static func fetchTeam(entryId: Int, currentGw: Int, boot: Bootstrap) async throws -> TeamState {
        let base = "https://fantasy.premierleague.com/api/entry/\(entryId)"
        guard let summaryData = try? await getData(base + "/"),
              let summary = try? JSONDecoder().decode(EntrySummary.self, from: summaryData)
        else { throw ImportError.notFound }

        // the most recent gameweek whose picks are published
        let finished = boot.events.filter { $0.finished || $0.is_current == true }.map(\.id)
        let pickGw = finished.max() ?? max(currentGw - 1, 1)
        guard pickGw >= 1,
              let picksData = try? await getData(base + "/event/\(pickGw)/picks/"),
              let picks = try? JSONDecoder().decode(EntryPicks.self, from: picksData),
              picks.picks.count == 15
        else { throw ImportError.noPicksYet(currentGw) }

        var chipsUsed: [String] = []
        if let hData = try? await getData(base + "/history/"),
           let hist = try? JSONDecoder().decode(EntryHistory.self, from: hData) {
            // chips are one per half-season, so record which half each was spent in
            chipsUsed = hist.chips.map { "\($0.name)-\($0.event <= 19 ? 19 : 38)" }
        }

        let hist = picks.entry_history
        let bank = hist?.bank ?? summary.last_deadline_bank ?? 0
        let value = (hist?.value ?? summary.last_deadline_value ?? 1000) - bank
        // FPL grants one free transfer per gameweek, banking to five. Without an
        // authenticated endpoint the exact count isn't published, so it is
        // reconstructed from how many transfers were made in recent weeks.
        let usedLast = hist?.event_transfers ?? 0
        let fts = max(1, min(usedLast == 0 ? 2 : 1, 5))

        let leagues = (summary.leagues?.classic ?? []).map {
            LeagueSummary(id: $0.id, name: $0.name,
                          rank: $0.entry_rank ?? 0, lastRank: $0.entry_last_rank ?? 0,
                          size: $0.rank_count ?? 0, isGlobal: $0.league_type == "s")
        }

        return TeamState(
            entryId: entryId,
            teamName: summary.name,
            managerName: [summary.player_first_name, summary.player_last_name]
                .compactMap { $0 }.joined(separator: " "),
            squadIds: picks.picks.sorted { $0.position < $1.position }.map(\.element),
            captainId: picks.picks.first { $0.is_captain }?.element ?? 0,
            bank: bank, squadValue: value, freeTransfers: fts,
            chipsUsed: chipsUsed,
            overallPoints: summary.summary_overall_points ?? 0,
            overallRank: summary.summary_overall_rank ?? 0,
            gw: pickGw, fetched: Date(),
            picks: picks.squadPicks,
            activeChip: picks.active_chip,
            transferCost: hist?.event_transfers_cost ?? 0,
            eventPoints: summary.summary_event_points,
            leagues: leagues)
    }

    /// Shared GET for the endpoints defined in other files.
    static func get(_ url: String) async throws -> Data { try await getData(url) }

    private static func getData(_ url: String) async throws -> Data {
        var req = URLRequest(url: URL(string: url)!)
        req.setValue("Mozilla/5.0 (PitchIQ iOS)", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
            throw ImportError.notFound
        }
        return data
    }
}

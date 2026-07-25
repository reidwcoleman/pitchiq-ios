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

    private static func getData(_ url: String) async throws -> Data {
        var req = URLRequest(url: URL(string: url)!)
        req.setValue("Mozilla/5.0 (PitchIQ iOS)", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await session.data(for: req)
        return data
    }
}

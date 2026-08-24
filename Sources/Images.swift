import SwiftUI

// MARK: - Premier League image assets
//
// FPL publishes a headshot for every player and a crest for every club on a
// public CDN, keyed by the codes in the bootstrap. The app drew coloured
// t-shirt glyphs instead, which made fifteen players look like fifteen
// identical rectangles — the one thing a squad screen must never do.
//
// Both are cached twice: in memory for the current session, and on disk by
// URLCache so a second launch draws them without touching the network.

enum PLImage {
    static func player(code: Int) -> URL? {
        guard code > 0 else { return nil }
        return URL(string: "https://resources.premierleague.com/premierleague/photos/players/110x140/p\(code).png")
    }

    static func badge(teamCode: Int) -> URL? {
        guard teamCode > 0 else { return nil }
        return URL(string: "https://resources.premierleague.com/premierleague/badges/70/t\(teamCode).png")
    }
}

/// A small image loader. `AsyncImage` re-requests on every appearance and
/// forgets everything on scroll, which is unusable in a list of 600 players.
@MainActor
final class ImageStore: ObservableObject {
    static let shared = ImageStore()

    private let memory = NSCache<NSURL, UIImage>()
    private var inFlight: [URL: Task<UIImage?, Never>] = [:]
    private let session: URLSession

    init() {
        memory.countLimit = 400
        let cfg = URLSessionConfiguration.default
        cfg.urlCache = URLCache(memoryCapacity: 8 << 20, diskCapacity: 96 << 20,
                                diskPath: "PitchIQImages")
        cfg.requestCachePolicy = .returnCacheDataElseLoad
        cfg.timeoutIntervalForRequest = 12
        session = URLSession(configuration: cfg)
    }

    func cached(_ url: URL) -> UIImage? { memory.object(forKey: url as NSURL) }

    func load(_ url: URL) async -> UIImage? {
        if let hit = cached(url) { return hit }
        if let running = inFlight[url] { return await running.value }
        let task = Task<UIImage?, Never> { [session] in
            guard let (data, response) = try? await session.data(from: url),
                  (response as? HTTPURLResponse).map({ $0.statusCode < 400 }) ?? true,
                  let image = UIImage(data: data) else { return nil }
            return image
        }
        inFlight[url] = task
        let image = await task.value
        inFlight[url] = nil
        if let image { memory.setObject(image, forKey: url as NSURL) }
        return image
    }
}

/// Loads `url`, showing `placeholder` until it arrives and keeping it if the
/// asset is missing — plenty of squad players have no headshot on file.
struct RemoteImage<Placeholder: View>: View {
    let url: URL?
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            guard let url, !failed else { return }
            if let hit = ImageStore.shared.cached(url) { image = hit; return }
            let loaded = await ImageStore.shared.load(url)
            if loaded == nil { failed = true }
            withAnimation(.easeOut(duration: 0.18)) { image = loaded }
        }
    }
}

// MARK: - the two things the app actually draws

/// A club crest at a given size, falling back to the club's colour.
struct TeamBadge: View {
    @EnvironmentObject private var state: AppState
    let teamId: Int
    var size: CGFloat = 22

    var body: some View {
        let short = state.teamShort(teamId)
        RemoteImage(url: state.teamCode(teamId).flatMap { PLImage.badge(teamCode: $0) }) {
            Circle().fill(Theme.teamColor(short).opacity(0.9))
                .overlay(Text(String(short.prefix(1)))
                    .font(.mono(size * 0.5, .black)).foregroundColor(.white))
        }
        .frame(width: size, height: size)
    }
}

/// A player headshot with the club crest tucked into the corner. Falls back to
/// a club-coloured shirt when the CDN has no photograph.
struct PlayerShot: View {
    let player: Player
    var size: CGFloat = 46
    var showBadge = true

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            RemoteImage(url: PLImage.player(code: player.code)) {
                ZStack {
                    Circle().fill(Theme.teamColor(player.teamShort).opacity(0.16))
                    Image(systemName: "tshirt.fill")
                        .font(.system(size: size * 0.42))
                        .foregroundColor(Theme.teamColor(player.teamShort))
                }
            }
            .frame(width: size, height: size)
            .background(
                Circle().fill(Theme.teamColor(player.teamShort).opacity(0.13))
            )
            .clipShape(Circle())
            .overlay(Circle().stroke(Theme.line, lineWidth: 1))

            if showBadge {
                TeamBadge(teamId: player.team, size: size * 0.38)
                    .background(Circle().fill(Theme.panel).padding(-1.5))
                    .offset(x: 2, y: 1)
            }
        }
        .frame(width: size, height: size)
    }
}

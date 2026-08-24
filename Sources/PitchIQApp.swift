import SwiftUI

@main
struct PitchIQApp: App {
    @StateObject private var state = AppState()

    /// Testing hook, alongside `-tab` and `-entry`: `-appearance light|dark`
    /// pins the colour scheme so both can be screenshotted from a script. Nil
    /// in normal use, which is what lets the app follow the phone.
    static var forcedScheme: ColorScheme? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-appearance"), i + 1 < args.count else { return nil }
        switch args[i + 1] {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(state)
                .preferredColorScheme(Self.forcedScheme)
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            switch state.phase {
            case .loading:
                VStack(spacing: 18) {
                    ProgressView().tint(Theme.lime).scaleEffect(1.3)
                    Text("Reading the season…").font(.mono(13)).foregroundColor(Theme.inkDim)
                }
            case .error(let msg):
                VStack(spacing: 16) {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.system(size: 34)).foregroundColor(Theme.amber)
                    Text(msg)
                        .font(.system(size: 14)).foregroundColor(Theme.inkDim)
                        .multilineTextAlignment(.center).padding(.horizontal, 40)
                    Button("Retry") { Task { await state.load() } }
                        .buttonStyle(.borderedProminent).tint(Theme.lime)
                }
            case .ready:
                MainTabs()
            }
        }
        .task { await state.load() }
        .onChange(of: scenePhase) { p in
            if p == .active { state.refreshIfStale() }
        }
    }
}

struct MainTabs: View {
    @State private var tab: Int

    init() {
        // The bar was pinned to white, which in dark mode is a white slab at
        // the bottom of a black screen. It follows the palette now.
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? 0x111612 : 0xFFFFFF)
        }
        appearance.shadowColor = UIColor(Theme.line)
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
        // testing hook: launch with `-tab N` to open a specific tab
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-tab"), i + 1 < args.count, let t = Int(args[i + 1]) {
            _tab = State(initialValue: t)
        } else {
            _tab = State(initialValue: 0)
        }
    }

    var body: some View {
        TabView(selection: $tab) {
            LiveView().tabItem { Label("Live", systemImage: "dot.radiowaves.left.and.right") }.tag(0)
            SquadView().tabItem { Label("Team", systemImage: "sportscourt.fill") }.tag(1)
            TransfersView().tabItem { Label("Transfers", systemImage: "arrow.left.arrow.right") }.tag(2)
            BrowseView().tabItem { Label("Players", systemImage: "list.number") }.tag(3)
            CaptainsView().tabItem { Label("Captain", systemImage: "crown.fill") }.tag(4)
        }
        .tint(Theme.lime)
    }
}

/// Rankings and the fixture ticker are both "look at the league" screens, and
/// iOS only gives five tabs before it starts hiding things behind a More
/// button. They share one.
struct BrowseView: View {
    @EnvironmentObject var state: AppState
    @State private var mode = 0

    var body: some View {
        VStack(spacing: 0) {
            AppHeader(subtitle: mode == 0
                      ? "Rankings · next \(state.horizon) GW"
                      : "Fixtures · from GW \(state.gwFrom)")
            SegmentBar(titles: ["Players", "Fixtures"], selection: $mode)
                .padding(.horizontal, Theme.Space.l)
                .padding(.bottom, Theme.Space.s)
            if mode == 0 { PlayersView(embedded: true) } else { FixturesView(embedded: true) }
        }
        .background(Theme.bg)
    }
}

// MARK: - header

/// One compact header shared by every tab: identity, freshness, and the way in
/// to settings. The old build put four filter menus at the top of all four
/// tabs, which pushed the actual content below the fold on a phone.
struct AppHeader: View {
    @EnvironmentObject var state: AppState
    var subtitle: String
    @State private var showSettings = false

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.s) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 0) {
                    Text("PITCH").font(.system(size: 21, weight: .black)).foregroundColor(Theme.ink)
                    Text("IQ").font(.system(size: 21, weight: .black)).foregroundColor(Theme.lime)
                }
                .kerning(-0.4)
                Text(subtitle.uppercased())
                    .font(.system(size: 9, weight: .heavy)).tracking(1.5)
                    .foregroundColor(Theme.inkDim)
                    .lineLimit(1).minimumScaleFactor(0.75)
            }
            Spacer(minLength: 4)
            if state.working || state.refreshing {
                ProgressView().tint(Theme.limeDim).scaleEffect(0.7)
                    .transition(.opacity)
            }
            DeadlineChip()
            Button { Haptics.tap(); showSettings = true } label: {
                Image(systemName: state.isConnected ? "person.crop.circle.fill" : "slider.horizontal.3")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(state.isConnected ? Theme.lime : Theme.ink)
                    .frame(width: 34, height: 34)
                    .background(Theme.panel)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Theme.line, lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
        .animation(.easeInOut(duration: 0.2), value: state.working)
        .padding(.horizontal, Theme.Space.l)
        .padding(.top, 2)
        .padding(.bottom, Theme.Space.s)
        .sheet(isPresented: $showSettings) { SettingsSheet() }
    }
}

/// Time to the next deadline, counted down in the header of every screen.
/// Turns amber inside twelve hours and red inside two.
struct DeadlineChip: View {
    @EnvironmentObject var state: AppState
    @State private var now = Date()
    private let tick = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        if let next = state.nextDeadline {
            let left = next.date.timeIntervalSince(now)
            let color: Color = left < 2 * 3600 ? Theme.red : (left < 12 * 3600 ? Theme.amber : Theme.inkDim)
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 5, height: 5)
                VStack(alignment: .leading, spacing: -1) {
                    Text(Self.format(left))
                        .font(.mono(12, .heavy)).foregroundColor(color).figures()
                    Text("GW \(next.gw)")
                        .font(.system(size: 8, weight: .heavy)).tracking(0.7)
                        .foregroundColor(Theme.inkFaint)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(Theme.bg2)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Theme.line, lineWidth: 1))
            .onReceive(tick) { now = $0 }
        }
    }

    static func format(_ seconds: TimeInterval) -> String {
        let s = max(Int(seconds), 0)
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }
}

// MARK: - settings

struct SettingsSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var entryText = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    connectCard
                    modelCard
                    dataCard
                }
                .padding(16)
            }
            .background(Theme.bg)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.tint(Theme.lime)
                }
            }
        }
        .onAppear { entryText = state.team.map { String($0.entryId) } ?? "" }
    }

    // --- connect an FPL team

    var connectCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(text: "Your FPL team", accent: Theme.lime)
            if let t = state.team {
                VStack(alignment: .leading, spacing: 8) {
                    Text(t.teamName).font(.system(size: 18, weight: .black)).foregroundColor(Theme.ink)
                    Text(t.managerName).font(.system(size: 12)).foregroundColor(Theme.inkDim)
                    HStack(spacing: 16) {
                        miniStat("\(t.overallPoints)", "PTS")
                        miniStat(t.overallRank > 0 ? rankText(t.overallRank) : "—", "RANK")
                        miniStat(String(format: "£%.1fm", Double(t.bank) / 10), "BANK")
                        miniStat("\(t.freeTransfers)", "FREE")
                    }
                    Text("Picks read from gameweek \(t.gw). The plan, the transfer board and the squad audit all work from these fifteen.")
                        .font(.system(size: 12)).foregroundColor(Theme.inkDim)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(role: .destructive) {
                        state.disconnect()
                    } label: {
                        Text("Disconnect").font(.system(size: 13, weight: .semibold))
                    }
                }
            } else {
                Text("Link your real team and every screen switches from “here is a good squad” to “here is what to do with yours”.")
                    .font(.system(size: 13)).foregroundColor(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    TextField("FPL team ID", text: $entryText)
                        .keyboardType(.numberPad)
                        .font(.mono(15, .bold))
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .background(Theme.bg2)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    Button {
                        if let id = Int(entryText.trimmingCharacters(in: .whitespaces)) {
                            Task { await state.connect(entryId: id) }
                        }
                    } label: {
                        if state.importing {
                            ProgressView().tint(.white).frame(width: 60)
                        } else {
                            Text("Connect").font(.system(size: 14, weight: .bold))
                                .foregroundColor(.white).frame(width: 60)
                        }
                    }
                    .padding(.vertical, 11)
                    .background(Theme.lime)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .disabled(state.importing || entryText.isEmpty)
                }
                Text("Find the ID in the URL when you open your team on the FPL website: fantasy.premierleague.com/entry/**1234567**/event/1")
                    .font(.system(size: 11.5)).foregroundColor(Theme.inkDim)
                    .fixedSize(horizontal: false, vertical: true)
                if let err = state.importError {
                    Text(err).font(.system(size: 12)).foregroundColor(Theme.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    func miniStat(_ v: String, _ k: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(v).font(.mono(14, .bold)).foregroundColor(Theme.ink)
            Text(k).font(.label(8)).tracking(1).foregroundColor(Theme.inkDim)
        }
    }

    func rankText(_ r: Int) -> String {
        r >= 1_000_000 ? String(format: "%.1fM", Double(r) / 1_000_000)
            : (r >= 1000 ? String(format: "%.0fk", Double(r) / 1000) : "\(r)")
    }

    // --- model settings

    var modelCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel(text: "Model")
            row("Planning from", "GW \(state.gwFrom)") {
                Menu {
                    ForEach(state.gwOptions, id: \.id) { e in
                        Button("GW \(e.id)\(e.is_next ? "  (next)" : "")") {
                            state.gwFrom = e.id
                            state.rebuild()
                        }
                    }
                } label: { chevron("GW \(state.gwFrom)") }
            }
            row("Ranking horizon", "") {
                Menu {
                    ForEach([1, 3, 6, 8, 12], id: \.self) { h in
                        Button(h == 1 ? "This gameweek only" : "Next \(h) gameweeks") {
                            state.horizon = h
                        }
                    }
                } label: {
                    chevron(state.horizon == 1 ? "1 GW" : "Next \(state.horizon)")
                }
            }
            if !state.isConnected {
                row("Budget", "") {
                    Menu {
                        ForEach([95.0, 97.5, 100.0, 102.5, 105.0], id: \.self) { b in
                            Button(String(format: "£%.1fm", b)) {
                                state.budget = b
                                state.rebuild()
                            }
                        }
                    } label: { chevron(String(format: "£%.1fm", state.budget)) }
                }
            }
            Toggle(isOn: Binding(get: { state.fitOnly }, set: { state.fitOnly = $0 })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hide flagged players").font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Theme.ink)
                    Text("Injured, suspended and doubtful players are excluded from every recommendation.")
                        .font(.system(size: 11.5)).foregroundColor(Theme.inkDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(Theme.lime)
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    func row<C: View>(_ title: String, _ value: String,
                      @ViewBuilder control: () -> C) -> some View {
        HStack {
            Text(title).font(.system(size: 14, weight: .semibold)).foregroundColor(Theme.ink)
            Spacer()
            control()
        }
    }

    func chevron(_ text: String) -> some View {
        HStack(spacing: 5) {
            Text(text).font(.mono(13, .bold))
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
        }
        .foregroundColor(Theme.lime)
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Theme.lime.opacity(0.1))
        .clipShape(Capsule())
    }

    // --- data

    var dataCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "Data")
            if let u = state.lastUpdated {
                Text("Live FPL data, updated \(u.formatted(date: .abbreviated, time: .shortened)).")
                    .font(.system(size: 12.5)).foregroundColor(Theme.inkDim)
            }
            Text(state.isPreseason
                 ? "Pre-season: projections run off last season's per-90 rates, minutes security and set-piece duty, adjusted for each opponent. Form joins the blend as soon as matches are played."
                 : "Projections blend current form with xG/xA per-90 rates, minutes security, bonus rates and each opponent's strength, home and away.")
                .font(.system(size: 12.5)).foregroundColor(Theme.inkDim)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                Task { await state.refresh() }
            } label: {
                Label("Refresh now", systemImage: "arrow.clockwise")
                    .font(.system(size: 14, weight: .semibold)).foregroundColor(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 11)
                    .background(Theme.lime)
                    .clipShape(RoundedRectangle(cornerRadius: 11))
            }
            .disabled(state.refreshing)
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }
}

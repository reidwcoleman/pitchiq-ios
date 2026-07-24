import SwiftUI

@main
struct PitchIQApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(state)
                .preferredColorScheme(.light)
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
                loadingView("Pulling live FPL data…")
            case .error(let msg):
                VStack(spacing: 16) {
                    Text("⚠︎").font(.system(size: 40))
                    Text(msg)
                        .font(.system(size: 14))
                        .foregroundColor(Theme.inkDim)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                    Button("Retry") { Task { await state.load() } }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.lime)
                        .foregroundColor(.white)
                }
            default:
                MainTabs()
            }
        }
        .task { await state.load() }
        // refetch live data when the app comes back to the foreground, so
        // played gameweeks (form, points, injuries, next GW) flow in automatically
        .onChange(of: scenePhase) { p in
            if p == .active { state.refreshIfStale() }
        }
    }

    func loadingView(_ msg: String) -> some View {
        VStack(spacing: 18) {
            ProgressView().tint(Theme.lime).scaleEffect(1.4)
            Text(msg).font(.mono(13)).foregroundColor(Theme.inkDim)
        }
    }
}

struct MainTabs: View {
    @EnvironmentObject var state: AppState
    @State private var tab: Int

    init() {
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor.white
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
            SquadView()
                .tabItem { Label("Optimal XV", systemImage: "sportscourt") }.tag(0)
            PlannerView()
                .tabItem { Label("Planner", systemImage: "point.topleft.down.curvedto.point.bottomright.up") }.tag(1)
            PlayersView()
                .tabItem { Label("Players", systemImage: "list.number") }.tag(2)
            CaptainsView()
                .tabItem { Label("Captaincy", systemImage: "crown") }.tag(3)
            FixturesView()
                .tabItem { Label("Fixtures", systemImage: "calendar") }.tag(4)
        }
        .tint(Theme.lime)
    }
}

// MARK: - shared header controls

struct ControlsBar: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 0) {
                        Text("PITCH").font(.system(size: 22, weight: .black))
                        Text("IQ").font(.system(size: 22, weight: .black)).foregroundColor(Theme.lime)
                    }
                    Text(state.isPreseason ? "2026/27 · PRE-SEASON" : "2026/27 · LIVE")
                        .font(.label(9)).tracking(2).foregroundColor(Theme.inkDim)
                    if let updated = state.lastUpdated {
                        Text("Updated \(updated.formatted(date: .omitted, time: .shortened))")
                            .font(.label(8)).foregroundColor(Theme.inkDim.opacity(0.8))
                            .lineLimit(1)
                    }
                }
                Spacer()
                Button {
                    state.rebuild()
                } label: {
                    Label("Rebuild", systemImage: "arrow.triangle.2.circlepath")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(Theme.lime)
                        .clipShape(Capsule())
                        .shadow(color: Theme.lime.opacity(0.3), radius: 6, x: 0, y: 3)
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Menu {
                        ForEach(state.gwOptions, id: \.id) { e in
                            Button("GW \(e.id)\(e.is_next ? " (next)" : "")") {
                                state.gwFrom = e.id
                                state.rebuild()
                            }
                        }
                    } label: {
                        chip("GW \(state.gwFrom)", icon: "chevron.down")
                    }
                    Menu {
                        Button("This GW only") { state.horizon = 1 }
                        Button("Next 3 GWs") { state.horizon = 3 }
                        Button("Next 6 GWs") { state.horizon = 6 }
                    } label: {
                        chip(state.horizon == 1 ? "1 GW" : "Next \(state.horizon)", icon: "chevron.down")
                    }
                    Menu {
                        ForEach([95.0, 97.5, 100.0, 102.5, 105.0], id: \.self) { b in
                            Button("£\(b == b.rounded() ? String(Int(b)) : String(format: "%.1f", b))m") {
                                state.budget = b
                                state.rebuild()
                            }
                        }
                    } label: {
                        chip("£\(state.budget == state.budget.rounded() ? String(Int(state.budget)) : String(format: "%.1f", state.budget))m", icon: "chevron.down")
                    }
                    Button { state.fitOnly.toggle() } label: {
                        chip(state.fitOnly ? "Fit only ✓" : "All players", icon: nil,
                             color: state.fitOnly ? Theme.lime : Theme.inkDim)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }

    func chip(_ text: String, icon: String?, color: Color = Theme.ink) -> some View {
        HStack(spacing: 5) {
            Text(text).font(.mono(12))
            if let icon { Image(systemName: icon).font(.system(size: 9, weight: .semibold)) }
        }
        .foregroundColor(color)
        .padding(.horizontal, 13).padding(.vertical, 9)
        .background(Theme.panel)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Theme.line, lineWidth: 1))
        .shadow(color: Color.black.opacity(0.03), radius: 5, x: 0, y: 2)
    }
}

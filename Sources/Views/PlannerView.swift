import SwiftUI

struct PlannerView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                ControlsBar()
                if case .optimizing = state.phase {
                    VStack(spacing: 14) {
                        ProgressView().tint(Theme.lime)
                        Text("Planning \(state.planWindow) gameweeks ahead…")
                            .font(.mono(12)).foregroundColor(Theme.inkDim)
                    }
                    .frame(maxWidth: .infinity, minHeight: 300)
                } else if let plan = state.plan {
                    PlanSummary(plan: plan)
                        .padding(.horizontal, 14)
                    Text("The opening squad is picked to stay strong across all \(plan.gws.count) gameweeks, so it needs few transfers. Free transfers roll over (max 5); a hit (-4) is only planned when the gain clearly beats it.")
                        .font(.system(size: 12)).foregroundColor(Theme.inkDim)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 18)
                    ForEach(plan.gws) { gp in
                        GWPlanCard(gwPlan: gp, isFirst: gp.gw == plan.gws.first?.gw)
                            .padding(.horizontal, 14)
                    }
                } else {
                    Text("No plan available — raise the budget or allow flagged players.")
                        .font(.system(size: 14)).foregroundColor(Theme.inkDim)
                        .padding(.top, 60)
                }
            }
            .padding(.bottom, 24)
        }
        .background(Theme.bg)
    }
}

struct PlanSummary: View {
    let plan: SeasonPlan

    var body: some View {
        HStack(spacing: 10) {
            tile(String(format: "%.0f", plan.totalPts), "PROJ PTS", Theme.lime)
            tile("\(plan.totalTransfers)", "TRANSFERS", Theme.cyan)
            tile(plan.totalHits > 0 ? "-\(plan.totalHits)" : "0", "HIT COST", plan.totalHits > 0 ? Theme.red : Theme.cyan)
        }
    }

    func tile(_ v: String, _ k: String, _ c: Color) -> some View {
        VStack(spacing: 4) {
            Text(v).font(.mono(22, .bold)).foregroundColor(c)
            Text(k).font(.label(8)).tracking(1.5).foregroundColor(Theme.inkDim)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .panel()
    }
}

struct GWPlanCard: View {
    @EnvironmentObject var state: AppState
    let gwPlan: GWPlan
    let isFirst: Bool
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("GW \(gwPlan.gw)")
                    .font(.system(size: 16, weight: .black)).foregroundColor(Theme.ink)
                Text(gwPlan.formation)
                    .font(.mono(11, .bold)).foregroundColor(Theme.cyan)
                Spacer()
                Text(String(format: "%.1f pts", gwPlan.projPts))
                    .font(.mono(15, .bold)).foregroundColor(Theme.lime)
            }

            HStack(spacing: 6) {
                Text("C").font(.system(size: 10, weight: .black)).foregroundColor(.black)
                    .frame(width: 17, height: 17).background(Theme.magenta).clipShape(Circle())
                Text(gwPlan.captain.name).font(.system(size: 13, weight: .heavy)).foregroundColor(Theme.ink)
                Text("(\(String(format: "%.1f", gwPlan.captain.proj))×2)")
                    .font(.mono(10, .medium)).foregroundColor(Theme.inkDim)
                Spacer()
                Text("FT banked: \(gwPlan.ftsLeft)")
                    .font(.mono(10, .medium)).foregroundColor(Theme.inkDim)
            }

            if isFirst {
                Label("Opening squad — built for the whole run", systemImage: "flag.fill")
                    .font(.system(size: 11.5, weight: .semibold)).foregroundColor(Theme.cyan)
            } else if gwPlan.transfers.isEmpty {
                Label("No transfers — roll the free transfer", systemImage: "arrow.uturn.right")
                    .font(.system(size: 11.5, weight: .semibold)).foregroundColor(Theme.inkDim)
            } else {
                ForEach(gwPlan.transfers) { t in
                    HStack(spacing: 7) {
                        Image(systemName: "arrow.left.arrow.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(t.paid ? Theme.red : Theme.lime)
                        Text(t.out.name).font(.system(size: 12.5, weight: .semibold))
                            .foregroundColor(Theme.inkDim).strikethrough()
                        Image(systemName: "arrow.right").font(.system(size: 9)).foregroundColor(Theme.inkDim)
                        Text(t.inn.name).font(.system(size: 12.5, weight: .heavy)).foregroundColor(Theme.ink)
                        Text("(\(t.inn.teamShort) £\(t.inn.price))")
                            .font(.mono(10, .medium)).foregroundColor(Theme.inkDim)
                        Spacer()
                        Text(t.paid ? "-4 HIT" : "FREE")
                            .font(.mono(9, .bold))
                            .foregroundColor(t.paid ? Theme.red : Theme.lime)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background((t.paid ? Theme.red : Theme.lime).opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                }
            }

            Button {
                withAnimation(.spring(response: 0.3)) { expanded.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Text(expanded ? "Hide XI" : "Show XI")
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                }
                .font(.system(size: 11.5, weight: .bold)).foregroundColor(Theme.cyan)
            }

            if expanded {
                VStack(spacing: 5) {
                    ForEach(gwPlan.xi) { p in
                        HStack {
                            Text(p.posShort).font(.mono(9, .bold)).foregroundColor(Theme.inkDim)
                                .frame(width: 32, alignment: .leading)
                            Text(p.name).font(.system(size: 12.5, weight: .semibold)).foregroundColor(Theme.ink)
                            if p.id == gwPlan.captain.id {
                                Text("C").font(.system(size: 8, weight: .black)).foregroundColor(.black)
                                    .frame(width: 13, height: 13).background(Theme.magenta).clipShape(Circle())
                            }
                            Spacer()
                            Text(p.teamShort).font(.mono(10, .medium)).foregroundColor(Theme.inkDim)
                            Text(String(format: "%.1f", p.proj))
                                .font(.mono(11, .bold)).foregroundColor(Theme.lime)
                                .frame(width: 36, alignment: .trailing)
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(isFirst ? Theme.cyan.opacity(0.4) : Theme.line, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

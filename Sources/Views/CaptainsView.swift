import SwiftUI

struct CaptainsView: View {
    @EnvironmentObject var state: AppState

    var picks: [Player] {
        Array(state.players.filter { state.fitOnly ? !$0.flagged : true }.prefix(10))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                ControlsBar()
                let maxProj = picks.first?.proj ?? 1
                ForEach(Array(picks.enumerated()), id: \.element.id) { i, p in
                    CaptainRow(rank: i + 1, player: p, frac: p.proj / maxProj)
                        .padding(.horizontal, 14)
                }
            }
            .padding(.bottom, 24)
        }
        .background(Theme.bg)
    }
}

struct CaptainRow: View {
    @EnvironmentObject var state: AppState
    let rank: Int
    let player: Player
    let frac: Double

    var body: some View {
        HStack(spacing: 14) {
            Text(String(format: "%02d", rank))
                .font(.mono(18, .bold))
                .foregroundColor(rank == 1 ? Theme.magenta : Theme.inkDim)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(player.name).font(.system(size: 15, weight: .heavy)).foregroundColor(Theme.ink)
                    Text("\(player.teamName) · \(player.posShort) · £\(player.price)")
                        .font(.system(size: 11)).foregroundColor(Theme.inkDim)
                        .lineLimit(1)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.bg2)
                        Capsule()
                            .fill(LinearGradient(colors: [Theme.limeDim, Theme.lime],
                                                 startPoint: .leading, endPoint: .trailing))
                            .frame(width: geo.size.width * frac)
                    }
                }
                .frame(height: 7)
            }
            VStack(alignment: .trailing, spacing: 2) {
                Text(String(format: "%.1f", player.proj * 2))
                    .font(.mono(20, .bold)).foregroundColor(Theme.lime)
                Text("AS CAPTAIN").font(.label(8)).tracking(1).foregroundColor(Theme.inkDim)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(Theme.panel)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(rank == 1 ? Theme.magenta.opacity(0.5) : Theme.line, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

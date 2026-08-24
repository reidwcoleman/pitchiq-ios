import SwiftUI

// MARK: - Handing a move to the official app
//
// The obvious feature is a button that makes the transfer for you. It cannot
// be built honestly.
//
// FPL's read endpoints are open — everything this app shows comes from them
// without a login. The *write* endpoints are not: `/api/transfers/` and
// `/api/my-team/{id}/` both answer 403 to anyone without a session cookie, and
// there is no OAuth, no token exchange and no developer programme to get one.
// The only way a third-party app can post a transfer is to take your Premier
// League email and password, sign in as you, and hold the session. That is
// credential harvesting whatever the intention behind it, it is against the
// game's terms, and one FPL login change would strand every user of it.
//
// So the app does the part it can do properly: it puts the move on the
// clipboard and opens the transfer page, where you make it yourself. Two taps
// instead of one, and nobody has to hand over a password.

enum FPLHandoff {
    static let transfers = URL(string: "https://fantasy.premierleague.com/transfers")!
    static let myTeam = URL(string: "https://fantasy.premierleague.com/my-team")!

    /// Universal links mean iOS opens these in the official app when it is
    /// installed, and in Safari when it isn't. Either way the user lands on the
    /// screen where the change is made.
    static func open(_ url: URL, copying text: String?, via openURL: OpenURLAction) {
        if let text { UIPasteboard.general.string = text }
        Haptics.success()
        openURL(url)
    }
}

/// "Do it in FPL" — copies the instruction and opens the official transfer
/// page. Deliberately not called "make this transfer", because the app isn't
/// making it.
struct HandoffButton: View {
    let summary: String
    var title = "Make it in FPL"
    var destination = FPLHandoff.transfers
    var accent: Color = Theme.lime

    @Environment(\.openURL) private var openURL
    @State private var copied = false

    var body: some View {
        Button {
            FPLHandoff.open(destination, copying: summary, via: openURL)
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { copied = true }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: copied ? "checkmark" : "arrow.up.forward.app.fill")
                    .font(.system(size: 12, weight: .bold))
                Text(copied ? "Copied — finish it in FPL" : title)
                    .font(.system(size: 13, weight: .bold))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(accent)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Copies the move and opens the official Fantasy Premier League transfer page")
    }
}

/// The one-line explanation, shown next to the button the first time it
/// matters, so nobody wonders why the app stops short of doing it.
struct HandoffNote: View {
    var body: some View {
        WhyNote(text: "FPL has no public way for another app to change your team — the transfer endpoints reject anyone without a Premier League login session, and there is no way to get one except by holding your password. PitchIQ won't ask for it. The button copies the move and opens the official transfer page instead.",
                label: "Why not automatic?")
    }
}

import SwiftUI
import simd

/// The play client: the game's view, filling the window. Everything a player sees over
/// it is the game's own GUI (`ClientRootView` draws it) — the default HUD is StarterGui's
/// PlayerHud — so nothing is drawn here.
struct ClientView: View {
    let player: PlayController

    var body: some View {
        ViewportView(player: player)
            .background(Color.black)
            .preferredColorScheme(.dark)
    }
}

struct HUDBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.black.opacity(0.5))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.1), lineWidth: 1))
    }
}

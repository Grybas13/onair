import SwiftUI

enum Theme {
    static let background = Color(red: 0.031, green: 0.035, blue: 0.039)
    static let card = Color.white.opacity(0.06)
    static let cardStroke = Color.white.opacity(0.08)
    static let accent = Color(red: 1.0, green: 0.33, blue: 0.20)
    static let spotifyGreen = Color(red: 0.12, green: 0.84, blue: 0.38)
    static let muted = Color.white.opacity(0.55)
}

/// Raudona „ON AIR“ lemputė, kaip studijoje.
struct OnAirBadge: View {
    let live: Bool
    @State private var glow = false

    var body: some View {
        Text("ON AIR")
            .font(.system(size: 13, weight: .heavy, design: .rounded))
            .tracking(2)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .foregroundStyle(live ? Color.white : Theme.muted)
            .background(
                Capsule().fill(live ? Theme.accent : Color.white.opacity(0.08))
            )
            .shadow(color: live ? Theme.accent.opacity(glow ? 0.9 : 0.3) : .clear, radius: glow ? 14 : 4)
            .onAppear { animateIfNeeded() }
            .onChange(of: live) { _, _ in animateIfNeeded() }
            .accessibilityLabel(live ? "DJ kalba" : "DJ tyli")
    }

    private func animateIfNeeded() {
        if live {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                glow = true
            }
        } else {
            withAnimation(.easeOut(duration: 0.2)) {
                glow = false
            }
        }
    }
}

extension View {
    func card() -> some View {
        self
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Theme.cardStroke, lineWidth: 1))
    }
}

func formatDuration(ms: Int) -> String {
    let total = max(0, ms / 1000)
    return String(format: "%d:%02d", total / 60, total % 60)
}

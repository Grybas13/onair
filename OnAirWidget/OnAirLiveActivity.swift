import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct OnAirWidgetBundle: WidgetBundle {
    var body: some Widget {
        OnAirLiveActivity()
    }
}

private enum WidgetTheme {
    static let accent = Color(red: 1.0, green: 0.33, blue: 0.20)
    static let background = Color(red: 0.05, green: 0.05, blue: 0.07)
    static let muted = Color.white.opacity(0.6)
}

struct OnAirLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: OnAirActivityAttributes.self) { context in
            LockScreenView(state: context.state)
                .activityBackgroundTint(WidgetTheme.background)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    OnAirPill(isTalking: context.state.isTalking)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.vibe)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(WidgetTheme.muted)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 2) {
                        Text(context.state.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text(context.state.artist)
                            .font(.caption)
                            .foregroundStyle(WidgetTheme.muted)
                            .lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ControlsRow(state: context.state)
                }
            } compactLeading: {
                Image(systemName: context.state.isTalking ? "mic.fill" : "dot.radiowaves.left.and.right")
                    .foregroundStyle(WidgetTheme.accent)
            } compactTrailing: {
                Text(context.state.isTalking ? "ON AIR" : talkCountdown(context.state))
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(context.state.isTalking ? WidgetTheme.accent : .white)
            } minimal: {
                Image(systemName: context.state.isTalking ? "mic.fill" : "dot.radiowaves.left.and.right")
                    .foregroundStyle(WidgetTheme.accent)
            }
            .keylineTint(WidgetTheme.accent)
        }
    }
}

private func talkCountdown(_ state: OnAirActivityAttributes.ContentState) -> String {
    state.tracksUntilTalk <= 1 ? "DJ next" : "DJ \(state.tracksUntilTalk)"
}

private struct LockScreenView: View {
    let state: OnAirActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                OnAirPill(isTalking: state.isTalking)
                Text(state.isTalking ? "\(state.djName) kalba" : state.djName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(WidgetTheme.muted)
                Spacer()
                Text(state.vibe)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.white.opacity(0.12)))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(state.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(state.artist)
                    .font(.subheadline)
                    .foregroundStyle(WidgetTheme.muted)
                    .lineLimit(1)
            }

            if let nextTitle = state.nextTitle {
                HStack(spacing: 4) {
                    Text("Toliau:")
                        .foregroundStyle(WidgetTheme.muted)
                    Text(nextTitle + (state.nextArtist.map { " · \($0)" } ?? ""))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if !state.isTalking {
                        Text(talkCountdown(state))
                            .foregroundStyle(WidgetTheme.accent)
                    }
                }
                .font(.caption)
            }

            ControlsRow(state: state)
        }
        .foregroundStyle(.white)
        .padding(14)
    }
}

private struct ControlsRow: View {
    let state: OnAirActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 8) {
            ControlButton(intent: DislikeIntent(), systemImage: "hand.thumbsdown.fill", label: nil, highlighted: false)
            ControlButton(intent: SwitchUpIntent(), systemImage: "arrow.triangle.2.circlepath", label: "Keisti", highlighted: false)
            ControlButton(intent: SkipIntent(), systemImage: "forward.fill", label: nil, highlighted: false)
            ControlButton(intent: LikeIntent(), systemImage: state.isLiked ? "heart.fill" : "heart", label: nil, highlighted: state.isLiked)
        }
    }
}

private struct ControlButton<Intent: AppIntent>: View {
    let intent: Intent
    let systemImage: String
    let label: String?
    let highlighted: Bool

    var body: some View {
        Button(intent: intent) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                if let label {
                    Text(label).font(.caption.weight(.semibold))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(highlighted ? WidgetTheme.accent : Color.white.opacity(0.14))
            )
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
    }
}

private struct OnAirPill: View {
    let isTalking: Bool

    var body: some View {
        Text("ON AIR")
            .font(.system(size: 10, weight: .heavy, design: .rounded))
            .tracking(1.2)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(isTalking ? WidgetTheme.accent : Color.white.opacity(0.15)))
            .foregroundStyle(.white)
    }
}

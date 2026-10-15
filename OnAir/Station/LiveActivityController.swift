import Foundation
import ActivityKit

/// Mygtukų iš užrakinto ekrano vykdymas programėlėje.
enum LiveActivityActions {
    enum Action {
        case switchUp, like, dislike, skip
    }

    @MainActor
    static func run(_ action: Action) async {
        guard let engine = StationEngine.current else {
            trace("Live Activity: stotis neparuošta")
            return
        }
        trace("Live Activity: paspausta \(action)")
        // Grąžiname atsakymą iškart, o veiksmą atliekame atskirai (kad mygtukas nestrigtų).
        Task { @MainActor in
            switch action {
            case .switchUp: await engine.switchItUp()
            case .like: await engine.likeCurrent()
            case .dislike: await engine.dislikeCurrent()
            case .skip: await engine.skip()
            }
        }
    }
}

/// Valdo Live Activity: paleidžia (tik kai programėlė ekrane – taip reikalauja iOS),
/// atnaujina tik pasikeitus turiniui ir užbaigia sustabdžius stotį.
@MainActor
final class LiveActivityController {
    private var activity: Activity<OnAirActivityAttributes>?
    private var lastState: OnAirActivityAttributes.ContentState?
    private var pending: OnAirActivityAttributes.ContentState?
    private var updateTask: Task<Void, Never>?

    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: SettingsKeys.liveActivity) as? Bool ?? true
    }

    var isRunning: Bool { activity != nil }

    /// Bando paleisti. Grąžina false, jei iOS neleido (pvz. programėlė ne ekrane ar išjungta nustatymuose).
    @discardableResult
    func startIfNeeded(_ state: OnAirActivityAttributes.ContentState) -> Bool {
        guard isEnabled else { return false }
        if activity != nil { update(state); return true }

        // Jei liko ankstesnės sesijos veikla – užbaigiame ją.
        for old in Activity<OnAirActivityAttributes>.activities {
            Task { await old.end(nil, dismissalPolicy: .immediate) }
        }

        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            trace("Live Activity išjungta iPhone nustatymuose (Nustatymai → OnAir → Live Activities)")
            return false
        }
        do {
            let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(4 * 3600))
            activity = try Activity.request(
                attributes: OnAirActivityAttributes(stationName: "OnAir"),
                content: content,
                pushType: nil
            )
            lastState = state
            trace("Live Activity paleista")
            return true
        } catch {
            trace("Live Activity nepavyko paleisti: \(error.localizedDescription)")
            return false
        }
    }

    /// Atnaujina (sutraukia dažnus pokyčius į vieną per ~0.5 s).
    func update(_ state: OnAirActivityAttributes.ContentState) {
        guard activity != nil, state != lastState else { return }
        pending = state
        guard updateTask == nil else { return }
        updateTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, let activity = self.activity, let next = self.pending else {
                self?.updateTask = nil
                return
            }
            self.pending = nil
            self.lastState = next
            let content = ActivityContent(state: next, staleDate: Date().addingTimeInterval(4 * 3600))
            await activity.update(content)
            self.updateTask = nil
            // Jei per tą laiką atsirado naujesnė būsena – atnaujiname dar kartą.
            if let newer = self.pending {
                self.pending = nil
                self.update(newer)
            }
        }
    }

    func end() {
        updateTask?.cancel()
        updateTask = nil
        pending = nil
        guard let activity else { return }
        self.activity = nil
        lastState = nil
        Task {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        trace("Live Activity užbaigta")
    }
}

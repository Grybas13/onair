import SwiftUI

@main
struct OnAirApp: App {
    @StateObject private var auth: SpotifyAuth
    @StateObject private var engine: StationEngine

    init() {
        SettingsKeys.registerDefaults()
        let auth = SpotifyAuth()
        let engine = StationEngine(
            api: SpotifyAPI(auth: auth),
            audio: AudioController(),
            voice: DJVoice()
        )
        _auth = StateObject(wrappedValue: auth)
        _engine = StateObject(wrappedValue: engine)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(auth)
                .environmentObject(engine)
                .environmentObject(AppLog.shared)
                .preferredColorScheme(.dark)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var auth: SpotifyAuth

    var body: some View {
        if auth.isLoggedIn {
            MainTabs()
        } else {
            LoginView()
        }
    }
}

struct MainTabs: View {
    var body: some View {
        TabView {
            StationView()
                .tabItem { Label("Stotis", systemImage: "dot.radiowaves.left.and.right") }
            SettingsView()
                .tabItem { Label("Nustatymai", systemImage: "slider.horizontal.3") }
            LogView()
                .tabItem { Label("Žurnalas", systemImage: "list.bullet.rectangle") }
        }
        .tint(Theme.accent)
    }
}

import SwiftUI

@main
struct OnAirApp: App {
    @StateObject private var auth: SpotifyAuth
    @StateObject private var engine: StationEngine
    @Environment(\.scenePhase) private var scenePhase

    init() {
        SettingsKeys.registerDefaults()
        let auth = SpotifyAuth()
        let api = SpotifyAPI(auth: auth)
        let store = ListeningStore()
        let curator = MusicCurator(lastFM: LastFMAPI(), spotify: api, store: store)
        let writer = DedisWriter(groq: GroqClient(), store: store, curator: curator)
        let engine = StationEngine(
            api: api,
            audio: AudioController(),
            voice: DJVoice(),
            store: store,
            curator: curator,
            writer: writer
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
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active: trace("Programėlė: ekrane")
            case .inactive: trace("Programėlė: neaktyvi")
            case .background: trace("Programėlė: fone")
            @unknown default: break
            }
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

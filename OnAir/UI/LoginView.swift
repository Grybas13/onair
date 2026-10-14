import SwiftUI
import AuthenticationServices

struct LoginView: View {
    @EnvironmentObject private var auth: SpotifyAuth
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @State private var errorText: String?
    @State private var isWorking = false

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            VStack(spacing: 20) {
                Spacer()

                OnAirBadge(live: true)

                Text("OnAir")
                    .font(.system(size: 52, weight: .black, design: .rounded))

                Text("Tavo asmeninė radijo stotis.\nDJ, kuris groja iš tavo Spotify.")
                    .font(.title3)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.muted)

                Spacer()

                if let reason = auth.reloginReason {
                    Text(reason)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.orange)
                }

                if !Config.isClientIDConfigured {
                    Text("Programėlė sukompiliuota be Spotify Client ID. Įrašyk SPOTIFY_CLIENT_ID GitHub nustatymuose ir paleisk kompiliavimą iš naujo (žr. README).")
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.orange)
                }

                Button {
                    Task { await login() }
                } label: {
                    HStack(spacing: 10) {
                        if isWorking {
                            ProgressView().tint(.black)
                        }
                        Text("Prisijungti su Spotify")
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Capsule().fill(Theme.spotifyGreen))
                    .foregroundStyle(.black)
                }
                .disabled(isWorking)

                if let errorText {
                    Text(errorText)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.red)
                }
            }
            .padding(24)
        }
    }

    private func login() async {
        isWorking = true
        errorText = nil
        defer { isWorking = false }

        do {
            let url = try auth.makeAuthorizationURL()
            let callbackURL = try await webAuthenticationSession.authenticate(
                using: url,
                callback: .customScheme(Config.callbackScheme),
                preferredBrowserSession: .shared,
                additionalHeaderFields: [:]
            )
            try await auth.handleCallback(callbackURL)
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            trace("Prisijungimas atšauktas")
        } catch {
            trace("Prisijungimo klaida: \(error.localizedDescription)")
            errorText = error.localizedDescription
        }
    }
}

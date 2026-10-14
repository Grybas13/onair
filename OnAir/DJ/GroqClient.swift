import Foundation

/// Groq (nemokamas planas) – kalbos modelis Dėdžio tekstams.
/// Jei modelio nebėra, bandomas kitas; pasiekus limitą – kurį laiką naudojami šablonai.
@MainActor
final class GroqClient {
    private let endpoint = URL(string: "https://api.groq.com/openai/v1/chat/completions")!
    private var models = ["llama-3.3-70b-versatile", "llama-3.1-8b-instant", "openai/gpt-oss-20b"]
    private var pausedUntil = Date.distantPast

    var isConfigured: Bool { !Config.groqAPIKey.isEmpty }

    func complete(system: String, user: String) async -> String? {
        guard isConfigured else { return nil }
        guard Date() >= pausedUntil else { return nil }

        let index = 0
        while index < models.count {
            let model = models[index]
            let outcome = await request(model: model, system: system, user: user)
            switch outcome {
            case .success(let text):
                return text
            case .modelUnavailable:
                trace("Groq: modelis \(model) nepasiekiamas – bandau kitą")
                models.remove(at: index)
                continue
            case .rateLimited(let seconds):
                pausedUntil = Date().addingTimeInterval(seconds)
                trace("Groq: pasiektas limitas, \(Int(seconds)) s naudoju šablonus")
                return nil
            case .unauthorized:
                pausedUntil = .distantFuture
                trace("Groq: neteisingas API raktas (GROQ_API_KEY) – naudoju šablonus")
                return nil
            case .failed:
                return nil
            }
        }
        return nil
    }

    private enum Outcome {
        case success(String)
        case modelUnavailable
        case rateLimited(TimeInterval)
        case unauthorized
        case failed
    }

    private func request(model: String, system: String, user: String) async -> Outcome {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("Bearer \(Config.groqAPIKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user]
            ],
            "temperature": 1.0,
            "max_tokens": 160
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return .failed }
        request.httpBody = data

        do {
            let (responseData, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let json = (try? JSONSerialization.jsonObject(with: responseData)) as? [String: Any]

            switch status {
            case 200:
                let choices = json?["choices"] as? [[String: Any]]
                let message = choices?.first?["message"] as? [String: Any]
                if let content = message?["content"] as? String, !content.isEmpty {
                    return .success(content)
                }
                return .failed
            case 401, 403:
                return .unauthorized
            case 429:
                let header = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After")
                return .rateLimited(max(30, Double(header ?? "") ?? 120))
            case 400, 404:
                let error = json?["error"] as? [String: Any]
                let code = (error?["code"] as? String ?? "") + " " + (error?["message"] as? String ?? "")
                if code.contains("model") {
                    return .modelUnavailable
                }
                trace("Groq HTTP \(status): \(code)")
                return .failed
            default:
                trace("Groq HTTP \(status)")
                return .failed
            }
        } catch {
            if (error as? URLError)?.code != .cancelled {
                trace("Groq nepavyko: \(error.localizedDescription)")
            }
            return .failed
        }
    }
}

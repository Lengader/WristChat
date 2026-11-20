import Foundation
import SwiftUI

struct ChatMessage: Identifiable, Codable {
    enum Role: String, Codable { case user, assistant }
    var id = UUID()
    let role: Role
    let content: String
}

@MainActor
final class WatchChat: ObservableObject {
    @Published var draft = ""
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var pending: ChatMessage?
    @Published private(set) var sending = false
    @Published private(set) var error: String?
    @Published private var credential: ChatSession?

    var connected: Bool { credential != nil }

    private let link = CompanionLink()
    private let credentialKey = "watch-session"
    private var model: String?

    init() {
        do {
            credential = try SecretStore.load(ChatSession.self, key: credentialKey)
            if let credential { messages = loadChat(for: credential.subject) }
        } catch { self.error = error.localizedDescription }
        link.onContext = { [weak self] context in self?.receive(context) }
        link.start()
    }

    private func receive(_ context: [String: Any]) {
        guard let data = context[CompanionLink.credentialKey] as? Data else { return }
        do {
            let incoming = try JSONDecoder().decode(ChatSession.self, from: data)
            if incoming.id != credential?.id {
                try SecretStore.save(incoming, key: credentialKey)
                if incoming.subject != credential?.subject {
                    messages = loadChat(for: incoming.subject)
                    draft = ""
                }
                credential = incoming
                model = nil
                error = nil
            }
            try link.session.updateApplicationContext([CompanionLink.acknowledgmentKey: incoming.id.uuidString])
        } catch { self.error = error.localizedDescription }
    }

    func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sending, !text.isEmpty, var session = credential else { return }
        guard text.count <= 3_000 else {
            error = "Сократи сообщение до 3 000 символов."
            return
        }

        let question = ChatMessage(role: .user, content: text)
        sending = true
        pending = question
        error = nil
        defer {
            sending = false
            pending = nil
        }
        do {
            if session.expiration.timeIntervalSinceNow < 90 {
                let renewed: OpenAI.TokenResponse
                do {
                    renewed = try await OpenAI.token([
                        "grant_type": "refresh_token", "client_id": session.clientID,
                        "refresh_token": session.refreshToken,
                    ])
                } catch WristError.service(400) {
                    throw WristError.service(401)
                }
                guard credential?.id == session.id else { return }
                if let scopes = renewed.scope, !scopes.split(separator: " ").contains(Substring(OpenAI.planScope)) {
                    throw WristError.permissionDenied
                }
                session.accessToken = renewed.accessToken
                session.refreshToken = renewed.refreshToken ?? session.refreshToken
                session.expiration = Date().addingTimeInterval(renewed.expiresIn)
                try SecretStore.save(session, key: credentialKey)
                credential = session
            }

            let selected = try await chooseModel(token: session.accessToken)
            guard credential?.id == session.id else { return }
            model = selected
            let context = Array(messages.suffix(12)) + [question]
            let reply = try await fetchReply(model: selected, context: context, token: session.accessToken)
            guard credential?.id == session.id else { return }
            messages = Array((messages + [question, ChatMessage(role: .assistant, content: reply)]).suffix(40))
            draft = ""
            saveChat()
        } catch {
            if credential?.id == session.id { self.error = error.localizedDescription }
        }
    }

    private struct Catalog: Decodable {
        struct Model: Decodable { let slug: String; let visibility: String }
        let models: [Model]
    }

    private func chooseModel(token: String) async throws -> String {
        if let model { return model }
        let (data, response) = try await URLSession.shared.data(for: OpenAI.authorized("/models", token: token))
        try OpenAI.check(response)
        let catalog = try JSONDecoder().decode(Catalog.self, from: data)
        guard let first = catalog.models.first(where: { $0.visibility == "list" }) else { throw WristError.noModels }
        return first.slug
    }

    private struct StreamEvent: Decodable {
        struct Failure: Decodable { let code: String? }
        struct Result: Decodable { let error: Failure? }
        let type: String
        let delta: String?
        let code: String?
        let response: Result?
    }

    private func fetchReply(model: String, context: [ChatMessage], token: String) async throws -> String {
        var request = OpenAI.authorized("/responses", token: token)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model, "store": false, "stream": true,
            "instructions": "Reply concisely in the user's language. The answer will be read on an Apple Watch.",
            "input": context.map { ["role": $0.role.rawValue, "content": $0.content] },
        ])
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        try OpenAI.check(response)
        let decoder = JSONDecoder()
        var text = ""
        for try await line in bytes.lines where line.hasPrefix("data:") {
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            let event = try decoder.decode(StreamEvent.self, from: Data(payload.utf8))
            switch event.type {
            case "response.output_text.delta", "response.refusal.delta": text += event.delta ?? ""
            case "response.completed":
                let answer = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !answer.isEmpty else { throw WristError.invalidResponse }
                return answer
            case "response.failed", "response.incomplete", "error":
                if event.response?.error?.code == "subscription_sharing_usage_limit_exceeded" ||
                    event.code == "subscription_sharing_usage_limit_exceeded" { throw WristError.service(429) }
                throw WristError.invalidResponse
            default: continue
            }
        }
        throw WristError.invalidResponse
    }

    func reset() {
        guard !sending else { return }
        messages = []
        draft = ""
        error = nil
        saveChat()
    }

    private func chatURL(for subject: String) -> URL {
        let file = Data(subject.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_")
        return URL.applicationSupportDirectory.appending(path: "chat-" + file + ".json")
    }

    private func loadChat(for subject: String) -> [ChatMessage] {
        guard let data = try? Data(contentsOf: chatURL(for: subject)) else { return [] }
        return (try? JSONDecoder().decode([ChatMessage].self, from: data)) ?? []
    }

    private func saveChat() {
        guard let credential else { return }
        do {
            let url = chatURL(for: credential.subject)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(messages).write(to: url, options: .atomic)
        } catch { self.error = "Не удалось сохранить переписку на часах." }
    }
}

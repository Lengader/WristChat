import Foundation
import SwiftUI

@MainActor
final class WatchChat: ObservableObject {
    @Published private(set) var book = ChatBook()
    @Published private(set) var replyingTo: UUID?
    @Published private(set) var liveText = ""
    @Published private(set) var error: String?
    @Published private var credential: ChatSession?

    var connected: Bool { credential != nil }

    private let link = CompanionLink()
    private let credentialKey = "watch-session"
    private var model: String?
    private var renewal: Task<ChatSession, Error>?
    private var request: Task<Void, Never>?
    private var turnID: UUID?
    private var accumulated = ""
    private var lastUpdate = Date.distantPast
    private var historyNeedsSync = true

    init() {
        do {
            credential = try SecretStore.load(ChatSession.self, key: credentialKey)
            if let credential { book = ChatStorage.load(credential.subject, migrateLegacy: true) }
        } catch { self.error = error.localizedDescription }
        link.onContext = { [weak self] context in self?.receiveCredential(context) }
        link.onActivation = { [weak self] in self?.sync() }
        link.onReasoningChange = { [weak self] data in self?.receiveReasoning(data) }
        link.onHistorySent = { [weak self] error in
            if error == nil { self?.sync() } else { self?.historyNeedsSync = true }
        }
        link.start()
    }

    func setMode(_ mode: ReasoningMode?, for thread: UUID?) {
        guard let credential else { return }
        book.apply(ReasoningChange(subject: credential.subject, threadID: thread, mode: mode))
        save()
    }

    func startReply(to thread: UUID, text: String, photo: Data?) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard replyingTo == nil, connected, !text.isEmpty || photo != nil else { return false }
        guard text.count <= 3_000 else {
            error = "Сократи сообщение до 3 000 символов."
            return false
        }

        let id = UUID()
        let question = ChatMessage(role: .user, content: text, photo: photo)
        book.add([question], to: thread)
        let messages = book.threads.first(where: { $0.id == thread })?.messages ?? []
        let context = Array(messages.filter { !$0.content.isEmpty || $0.photo != nil }.suffix(13))
        let mode = book.mode(for: thread)
        replyingTo = thread
        turnID = id
        accumulated = ""
        liveText = ""
        lastUpdate = .distantPast
        error = nil
        save()

        request = Task { [weak self] in
            guard let self else { return }
            do {
                let session = try await self.validSession()
                try Task.checkCancellation()
                let selected: String
                if let cached = self.model { selected = cached }
                else { selected = try await ResponseStream.model(using: session.accessToken) }
                guard self.turnID == id else { return }
                self.model = selected
                let reply = try await ResponseStream.answer(model: selected, mode: mode, context: context, token: session.accessToken) { delta in
                    await MainActor.run { self.receiveDelta(delta, for: id) }
                }
                self.finish(id: id, text: reply, ending: nil)
            } catch {
                guard self.turnID == id else { return }
                self.error = error.localizedDescription
                self.finish(id: id, text: self.accumulated, ending: .interrupted)
            }
        }
        return true
    }

    func stop() {
        guard let id = turnID else { return }
        request?.cancel()
        finish(id: id, text: accumulated, ending: .stopped)
    }

    private func receiveDelta(_ delta: String, for id: UUID) {
        guard turnID == id else { return }
        accumulated += delta
        let now = Date()
        if now.timeIntervalSince(lastUpdate) >= 0.07 {
            lastUpdate = now
            liveText = accumulated
        }
    }

    private func finish(id: UUID, text: String, ending: ChatMessage.Ending?) {
        guard turnID == id, let thread = replyingTo else { return }
        book.add([ChatMessage(role: .assistant, content: text, ending: ending)], to: thread)
        turnID = nil
        request = nil
        liveText = ""
        accumulated = ""
        replyingTo = nil
        save()
    }

    private func validSession() async throws -> ChatSession {
        guard let session = credential else { throw WristError.service(401) }
        if session.expiration.timeIntervalSinceNow >= 90 { return session }
        if let renewal { return try await renewal.value }
        let task = Task { () throws -> ChatSession in
            defer { if self.credential?.id == session.id { self.renewal = nil } }
            let renewed: OpenAI.TokenResponse
            do {
                renewed = try await OpenAI.token([
                    "grant_type": "refresh_token", "client_id": session.clientID,
                    "refresh_token": session.refreshToken,
                ])
            } catch WristError.service(400) {
                throw WristError.service(401)
            }
            guard self.credential?.id == session.id else { throw CancellationError() }
            if let scopes = renewed.scope, !scopes.split(separator: " ").contains(Substring(OpenAI.planScope)) {
                throw WristError.permissionDenied
            }
            var updated = session
            updated.accessToken = renewed.accessToken
            updated.refreshToken = renewed.refreshToken ?? session.refreshToken
            updated.expiration = Date().addingTimeInterval(renewed.expiresIn)
            try SecretStore.save(updated, key: self.credentialKey)
            self.credential = updated
            return updated
        }
        renewal = task
        return try await task.value
    }

    private func receiveCredential(_ context: [String: Any]) {
        guard let data = context[CompanionLink.credentialKey] as? Data else { return }
        do {
            let incoming = try JSONDecoder().decode(ChatSession.self, from: data)
            if incoming.id != credential?.id {
                try SecretStore.save(incoming, key: credentialKey)
                stop()
                renewal?.cancel()
                renewal = nil
                if incoming.subject != credential?.subject {
                    book = ChatStorage.load(incoming.subject, migrateLegacy: true)
                }
                credential = incoming
                model = nil
                error = nil
                historyNeedsSync = true
                sync()
            }
            try link.session.updateApplicationContext([CompanionLink.acknowledgmentKey: incoming.id.uuidString])
        } catch { self.error = error.localizedDescription }
    }

    private func receiveReasoning(_ data: Data) {
        guard let change = try? JSONDecoder().decode(ReasoningChange.self, from: data),
              change.subject == credential?.subject, book.apply(change) else { return }
        save()
    }

    private func save() {
        guard let credential else { return }
        do {
            book.revision += 1
            try ChatStorage.save(book, for: credential.subject)
            historyNeedsSync = true
            sync()
        } catch { self.error = "Не удалось сохранить переписку на часах." }
    }

    func sync() {
        guard historyNeedsSync, let credential else { return }
        do {
            if try link.sendHistory(HistorySnapshot(subject: credential.subject, book: book)) {
                historyNeedsSync = false
            }
        } catch { historyNeedsSync = true }
    }
}

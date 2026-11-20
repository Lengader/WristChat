import AuthenticationServices
import SwiftUI

@main
struct WristChatPhoneApp: App {
    @StateObject private var signIn = PhoneSignIn()

    var body: some Scene {
        WindowGroup {
            VStack(alignment: .leading, spacing: 18) {
                Label("WristChat", systemImage: "applewatch").font(.largeTitle.bold())
                Text("Подключи подписку ChatGPT для ответов на Apple Watch.")
                    .foregroundStyle(.secondary)
                Button("Continue with ChatGPT") { signIn.begin() }
                    .buttonStyle(.borderedProminent)
                    .tint(.primary)
                    .disabled(signIn.busy || !signIn.watchReady)
                if signIn.busy { ProgressView() }
                if let status = signIn.status {
                    Text(status).font(.footnote).foregroundStyle(.secondary)
                } else if !signIn.watchReady {
                    Text("Установи WristChat на Apple Watch и открой его.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(24)
        }
    }
}

@MainActor
final class PhoneSignIn: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    private struct Registration: Codable {
        let clientID: String
        let subject: String
    }

    private struct Attempt {
        let host: String
        let state: String
        let nonce: String
        let verifier: String
        let registration: Registration?
    }

    @Published private(set) var busy = false
    @Published private(set) var watchReady = false
    @Published private(set) var status: String?

    private let link = CompanionLink()
    private var listener: OAuthLoopback?
    private var browser: ASWebAuthenticationSession?
    private var attempt: Attempt?

    override init() {
        super.init()
        link.onActivation = { [weak self] in self?.updateWatchStatus() }
        link.onContext = { [weak self] in self?.acknowledge($0) }
        link.start()
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })?.keyWindow ?? ASPresentationAnchor()
    }

    func begin() {
        guard watchReady, !busy else { return }
        do {
            let host: String
            if let saved = try SecretStore.load(String.self, key: "chat-host") {
                host = saved
            } else {
                host = "urn:uuid:" + UUID().uuidString.lowercased()
                try SecretStore.save(host, key: "chat-host")
            }
            let attempt = Attempt(host: host, state: try OAuthRandom.make(), nonce: try OAuthRandom.make(),
                                  verifier: try OAuthRandom.make(),
                                  registration: try SecretStore.load(Registration.self, key: "chat-registration"))
            let server = try OAuthLoopback(
                state: attempt.state,
                ready: { [weak self] port in Task { @MainActor in self?.openBrowser(port: port, attempt: attempt) } },
                callback: { [weak self] callback, port in Task { @MainActor in await self?.finish(callback, port: port, attempt: attempt) } },
                failed: { [weak self] in Task { @MainActor in self?.fail(WristError.callbackUnavailable, state: attempt.state) } }
            )
            self.attempt = attempt
            listener = server
            busy = true
            status = nil
            server.start()
        } catch { status = error.localizedDescription }
    }

    private func openBrowser(port: UInt16, attempt: Attempt) {
        guard self.attempt?.state == attempt.state else { return }
        var url = URLComponents(string: OpenAI.issuer + "/api/accounts/authorize")!
        var parameters = [
            "client_id": attempt.registration?.clientID ?? OpenAI.initialClient,
            "ext_agent_host_id": attempt.host,
            "response_type": "code", "redirect_uri": OAuthLoopback.redirectURI(port),
            "scope": "openid profile email offline_access resource.invoke " + OpenAI.planScope,
            "resource": OpenAI.resource, "state": attempt.state, "nonce": attempt.nonce,
            "code_challenge_method": "S256", "code_challenge": OAuthRandom.challenge(attempt.verifier),
        ]
        if attempt.registration == nil { parameters["agent_name_hint"] = "WristChat" }
        url.queryItems = parameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }

        // OpenAI's registered redirect goes to the loopback listener. It closes this browser after receipt.
        let browser = ASWebAuthenticationSession(url: url.url!, callback: .customScheme(OAuthLoopback.returnScheme)) { [weak self] _, error in
            Task { @MainActor in
                guard let self, let error, self.attempt?.state == attempt.state else { return }
                if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                    self.cancelAttempt()
                } else {
                    self.fail(error, state: attempt.state)
                }
            }
        }
        browser.presentationContextProvider = self
        self.browser = browser
        if !browser.start() { fail(WristError.callbackUnavailable, state: attempt.state) }
    }

    private func finish(_ callback: OAuthLoopback.Callback, port: UInt16, attempt: Attempt) async {
        guard self.attempt?.state == attempt.state else { return }
        closeBrowser()
        defer { busy = false }
        do {
            if callback.denied { throw WristError.permissionDenied }
            let clientID = attempt.registration?.clientID ?? callback.clientID
            guard let code = callback.code, let clientID, !clientID.isEmpty, clientID != OpenAI.initialClient,
                  callback.clientID == nil || callback.clientID == clientID else { throw WristError.invalidIdentity }
            let tokens = try await OpenAI.token([
                "grant_type": "authorization_code", "client_id": clientID, "code": code,
                "code_verifier": attempt.verifier, "redirect_uri": OAuthLoopback.redirectURI(port),
            ])
            guard let idToken = tokens.idToken else { throw WristError.invalidIdentity }
            let subject = try await TokenIdentity.validate(idToken, clientID: clientID, nonce: attempt.nonce)
            if let registration = attempt.registration, registration.subject != subject { throw WristError.invalidIdentity }
            guard let scope = tokens.scope, scope.split(separator: " ").contains(Substring(OpenAI.planScope)),
                  let renewable = tokens.refreshToken else { throw WristError.permissionDenied }

            let session = ChatSession(id: UUID(), clientID: clientID, subject: subject,
                                      accessToken: tokens.accessToken, refreshToken: renewable,
                                      expiration: Date().addingTimeInterval(tokens.expiresIn))
            try SecretStore.save(Registration(clientID: clientID, subject: subject), key: "chat-registration")
            try link.session.updateApplicationContext([CompanionLink.credentialKey: JSONEncoder().encode(session)])
            status = "Вход выполнен. Открой WristChat на Apple Watch."
        } catch { status = error.localizedDescription }
    }

    private func acknowledge(_ context: [String: Any]) {
        guard let ack = context[CompanionLink.acknowledgmentKey] as? String,
              let pending = link.session.applicationContext[CompanionLink.credentialKey] as? Data,
              let session = try? JSONDecoder().decode(ChatSession.self, from: pending),
              ack == session.id.uuidString else { return }
        do {
            try link.session.updateApplicationContext([:])
            status = "ChatGPT подключён на часах."
        } catch { status = error.localizedDescription }
    }

    private func updateWatchStatus() {
        watchReady = link.session.activationState == .activated && link.session.isPaired && link.session.isWatchAppInstalled
    }

    private func fail(_ error: Error, state: String) {
        guard attempt?.state == state else { return }
        cancelAttempt()
        status = error.localizedDescription
    }

    private func cancelAttempt() {
        closeBrowser()
        busy = false
    }

    private func closeBrowser() {
        attempt = nil
        listener?.stop()
        listener = nil
        browser?.cancel()
        browser = nil
    }
}

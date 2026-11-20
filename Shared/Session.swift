import Foundation
import Security
import WatchConnectivity

struct ChatSession: Codable {
    let id: UUID
    let clientID: String
    let subject: String
    var accessToken: String
    var refreshToken: String
    var expiration: Date
}

enum WristError: LocalizedError {
    case invalidResponse, invalidIdentity, permissionDenied, noModels, callbackUnavailable
    case keychain(OSStatus)
    case service(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "OpenAI не прислал полный ответ. Попробуй ещё раз."
        case .invalidIdentity: "Не удалось подтвердить аккаунт ChatGPT. Войди заново."
        case .permissionDenied: "Аккаунт не дал разрешение использовать подписку ChatGPT."
        case .noModels: "Для этого аккаунта нет доступных моделей ChatGPT."
        case .callbackUnavailable: "Не удалось открыть локальный вход. Попробуй ещё раз."
        case .keychain: "Не удалось сохранить подключение в Связке ключей."
        case .service(401): "Подключение истекло. Войди в WristChat на iPhone ещё раз."
        case .service(403): "OpenAI не разрешил запрос для этого аккаунта или региона."
        case .service(429): "Достигнут лимит запросов. Попробуй позже."
        case let .service(status): "OpenAI вернул ошибку (\(status)). Попробуй ещё раз."
        }
    }
}

enum SecretStore {
    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Bundle.main.bundleIdentifier ?? "WristChat",
         kSecAttrAccount as String: account]
    }

    static func load<T: Decodable>(_ type: T.Type, key: String) throws -> T? {
        var request = query(key)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw WristError.keychain(status)
        }
        return try JSONDecoder().decode(type, from: data)
    }

    static func save<T: Encodable>(_ value: T, key: String) throws {
        var request = query(key)
        let data = try JSONEncoder().encode(value)
        let change = [kSecValueData as String: data] as CFDictionary
        let updated = SecItemUpdate(request as CFDictionary, change)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw WristError.keychain(updated) }
        request[kSecValueData as String] = data
        request[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(request as CFDictionary, nil)
        guard added == errSecSuccess else { throw WristError.keychain(added) }
    }
}

// Credentials travel only over the system connection between paired devices.
final class CompanionLink: NSObject, WCSessionDelegate {
    static let credentialKey = "chat-session"
    static let acknowledgmentKey = "chat-session-received"

    let session = WCSession.default
    var onContext: (([String: Any]) -> Void)?
    var onActivation: (() -> Void)?

    func start() {
        session.delegate = self
        session.activate()
    }

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async {
            self.onActivation?()
            if state == .activated { self.onContext?(session.receivedApplicationContext) }
        }
    }

    func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        DispatchQueue.main.async { self.onContext?(context) }
    }

    #if os(iOS)
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    func sessionWatchStateDidChange(_ session: WCSession) {
        DispatchQueue.main.async { self.onActivation?() }
    }
    #endif
}

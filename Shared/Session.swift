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
    case invalidResponse, invalidIdentity, permissionDenied, noModels, callbackUnavailable, unreadablePhoto
    case reasoningUnavailable, photoUnavailable
    case keychain(OSStatus)
    case service(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "OpenAI не прислал полный ответ. Попробуй ещё раз."
        case .invalidIdentity: "Не удалось подтвердить аккаунт ChatGPT. Войди заново."
        case .permissionDenied: "Аккаунт не дал разрешение использовать подписку ChatGPT."
        case .noModels: "Для этого аккаунта нет доступных моделей ChatGPT."
        case .callbackUnavailable: "Не удалось открыть локальный вход. Попробуй ещё раз."
        case .unreadablePhoto: "Не удалось загрузить фото на часах. Выбери другое."
        case .reasoningUnavailable: "Текущая модель не поддерживает этот режим. Выбери «Авто»."
        case .photoUnavailable: "Текущая модель не приняла фото. Попробуй другой снимок или отправь текст."
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
    private static let historyKey = "wristchat-history"
    private static let reasoningKey = "wristchat-reasoning"

    let session = WCSession.default
    var onContext: (([String: Any]) -> Void)?
    var onActivation: (() -> Void)?
    var onHistory: ((Data) -> Void)?
    var onHistorySent: ((Error?) -> Void)?
    var onReasoningChange: ((Data) -> Void)?

    func start() {
        session.delegate = self
        session.activate()
    }

    func sendHistory(_ snapshot: HistorySnapshot) throws -> Bool {
        guard session.activationState == .activated else { return false }
        #if os(watchOS)
        guard session.isCompanionAppInstalled else { return false }
        #endif
        guard !session.outstandingFileTransfers.contains(where: { $0.file.metadata?[Self.historyKey] as? Bool == true }) else {
            return false
        }
        let url = FileManager.default.temporaryDirectory.appending(path: "wristchat-\(UUID().uuidString).json")
        try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
        session.transferFile(url, metadata: [Self.historyKey: true])
        return true
    }

    func sendReasoningChange(_ change: ReasoningChange) throws {
        guard session.activationState == .activated else { return }
        session.transferUserInfo([Self.reasoningKey: try JSONEncoder().encode(change)])
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        guard let data = userInfo[Self.reasoningKey] as? Data else { return }
        DispatchQueue.main.async { self.onReasoningChange?(data) }
    }

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        guard file.metadata?[Self.historyKey] as? Bool == true,
              let data = try? Data(contentsOf: file.fileURL) else { return }
        DispatchQueue.main.async { self.onHistory?(data) }
    }

    func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        let file = fileTransfer.file
        guard file.metadata?[Self.historyKey] as? Bool == true else { return }
        try? FileManager.default.removeItem(at: file.fileURL)
        DispatchQueue.main.async { self.onHistorySent?(error) }
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

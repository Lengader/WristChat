import CryptoKit
import Foundation
import Network
import Security

enum OAuthRandom {
    static func make() throws -> String {
        var data = Data(count: 32)
        let count = data.count
        let status = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        guard status == errSecSuccess else { throw WristError.callbackUnavailable }
        return base64URL(data)
    }

    static func challenge(_ verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

final class OAuthLoopback {
    struct Callback {
        let code: String?
        let clientID: String?
        let denied: Bool
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "WristChat.OAuthLoopback")
    private let state: String
    private let deliver: (Callback, UInt16) -> Void
    private var accepted = false

    static let returnScheme = "wristchat-auth"
    static func redirectURI(_ port: UInt16) -> String { "http://127.0.0.1:\(port)/auth/callback" }

    init(state: String, ready: @escaping (UInt16) -> Void, callback: @escaping (Callback, UInt16) -> Void,
         failed: @escaping () -> Void) throws {
        self.state = state
        deliver = callback
        let settings = NWParameters.tcp
        settings.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: settings)
        listener.stateUpdateHandler = { [weak self] status in
            switch status {
            case .ready: if let port = self?.listener.port?.rawValue { ready(port) } else { failed() }
            case .failed: failed()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            connection.start(queue: self.queue)
            self.queue.asyncAfter(deadline: .now() + 10) { [weak connection] in connection?.cancel() }
            self.receive(connection, accumulated: Data())
        }
    }

    func start() { listener.start(queue: queue) }
    func stop() { listener.cancel() }

    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { [weak self] data, _, complete, error in
            guard let self, error == nil else { connection.cancel(); return }
            var buffer = accumulated
            buffer.append(data ?? Data())
            guard buffer.count <= 16_384 else { connection.cancel(); return }
            if let head = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let request = String(decoding: buffer[..<head.lowerBound], as: UTF8.self)
                self.handle(request, connection: connection)
            } else if !complete {
                self.receive(connection, accumulated: buffer)
            } else {
                connection.cancel()
            }
        }
    }

    private func handle(_ request: String, connection: NWConnection) {
        let parts = request.prefix(while: { !$0.isNewline }).split(separator: " ")
        guard !accepted, parts.count == 3, parts[0] == "GET", parts[1].hasPrefix("/auth/callback?"),
              let query = URLComponents(string: "http://127.0.0.1" + parts[1])?.queryItems,
              let port = listener.port?.rawValue else {
            reply("404 Not Found", text: "Not found", on: connection)
            return
        }
        func field(_ name: String) -> String? { query.first(where: { $0.name == name })?.value }
        guard field("state") == state else {
            reply("400 Bad Request", text: "Open WristChat and start sign-in again.", on: connection)
            return
        }
        accepted = true
        let callback = Callback(code: field("code"), clientID: field("client_id"), denied: field("error") != nil)
        reply("303 See Other", text: "Return to WristChat.", on: connection,
              location: Self.returnScheme + "://complete") { [weak self] in
            self?.deliver(callback, port)
        }
    }

    private func reply(_ status: String, text: String, on connection: NWConnection, location: String? = nil,
                       done: (() -> Void)? = nil) {
        let redirect = location.map { "Location: \($0)\r\n" } ?? ""
        let head = "HTTP/1.1 \(status)\r\n\(redirect)Content-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nContent-Length: \(text.utf8.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data((head + text).utf8), completion: .contentProcessed { _ in
            connection.cancel()
            done?()
        })
    }
}

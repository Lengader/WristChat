import Foundation

enum OpenAI {
    static let issuer = "https://auth.openai.com"
    static let resource = "https://api.openai.com/v1"
    static let planScope = "chatgpt.tokens.use.direct"
    static let initialClient = "dynamic_agent_client"

    struct TokenResponse: Decodable {
        let accessToken: String
        let refreshToken: String?
        let idToken: String?
        let expiresIn: TimeInterval
        let scope: String?

        private enum CodingKeys: String, CodingKey {
            case accessToken = "access_token", refreshToken = "refresh_token"
            case idToken = "id_token", expiresIn = "expires_in", scope
        }
    }

    static func check(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else { throw WristError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else { throw WristError.service(response.statusCode) }
    }

    static func token(_ fields: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: URL(string: issuer + "/api/accounts/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let form = fields.merging(["resource": resource]) { current, _ in current }
        request.httpBody = Data(form.sorted { $0.key < $1.key }.map { key, value in
            key + "=" + (value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
        }.joined(separator: "&").utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response)
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    static func authorized(_ path: String, token: String) -> URLRequest {
        var request = URLRequest(url: URL(string: resource + path)!)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        return request
    }
}

import Foundation
import Security

enum TokenIdentity {
    private struct Header: Decodable { let alg: String; let kid: String }
    private struct Keys: Decodable {
        struct Key: Decodable {
            let kid: String
            let kty: String
            let alg: String?
            let n: String?
            let e: String?
        }
        let keys: [Key]
    }
    private struct Claims: Decodable {
        let iss: String
        let sub: String
        let aud: [String]
        let exp: TimeInterval
        let nonce: String
        let azp: String?

        private enum CodingKeys: String, CodingKey { case iss, sub, aud, exp, nonce, azp }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            iss = try values.decode(String.self, forKey: .iss)
            sub = try values.decode(String.self, forKey: .sub)
            if let audience = try? values.decode(String.self, forKey: .aud) {
                aud = [audience]
            } else {
                aud = try values.decode([String].self, forKey: .aud)
            }
            exp = try values.decode(TimeInterval.self, forKey: .exp)
            nonce = try values.decode(String.self, forKey: .nonce)
            azp = try values.decodeIfPresent(String.self, forKey: .azp)
        }
    }

    static func validate(_ token: String, clientID: String, nonce: String) async throws -> String {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let header = decodeBase64(parts[0]), let payload = decodeBase64(parts[1]),
              let signature = decodeBase64(parts[2]),
              let metadata = try? JSONDecoder().decode(Header.self, from: header), metadata.alg == "RS256"
        else { throw WristError.invalidIdentity }

        let jwksURL = URL(string: OpenAI.issuer + "/.well-known/jwks.json")!
        let (data, response) = try await URLSession.shared.data(from: jwksURL)
        try OpenAI.check(response)
        let keys = try JSONDecoder().decode(Keys.self, from: data)
        guard let key = keys.keys.first(where: { $0.kid == metadata.kid && $0.kty == "RSA" && ($0.alg == nil || $0.alg == metadata.alg) }),
              let modulus = key.n.flatMap({ decodeBase64($0[...]) }),
              let exponent = key.e.flatMap({ decodeBase64($0[...]) }),
              let publicKey = makeRSAKey(modulus: modulus, exponent: exponent),
              SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256,
                                    Data((parts[0] + "." + parts[1]).utf8) as CFData, signature as CFData, nil),
              let claims = try? JSONDecoder().decode(Claims.self, from: payload),
              claims.iss == OpenAI.issuer, !claims.sub.isEmpty, claims.aud.contains(clientID),
              (claims.aud.count == 1 && claims.azp == nil) || claims.azp == clientID,
              claims.exp > Date().timeIntervalSince1970, claims.nonce == nonce
        else { throw WristError.invalidIdentity }
        return claims.sub
    }

    private static func decodeBase64(_ part: Substring) -> Data? {
        var base64 = part.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.utf8.count % 4) % 4)
        return Data(base64Encoded: base64)
    }

    private static func makeRSAKey(modulus: Data, exponent: Data) -> SecKey? {
        guard (256...1024).contains(modulus.count), (1...8).contains(exponent.count) else { return nil }
        let sequence = der(0x30, data: integer(modulus) + integer(exponent))
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
        ]
        return SecKeyCreateWithData(sequence as CFData, attributes as CFDictionary, nil)
    }

    private static func integer(_ data: Data) -> Data {
        var bytes = Data(data.drop(while: { $0 == 0 }))
        if bytes.isEmpty || (bytes[0] & 0x80) != 0 { bytes.insert(0, at: 0) }
        return der(0x02, data: bytes)
    }

    private static func der(_ tag: UInt8, data: Data) -> Data {
        let count = data.count
        if count < 128 { return Data([tag, UInt8(count)]) + data }
        if count < 256 { return Data([tag, 0x81, UInt8(count)]) + data }
        return Data([tag, 0x82, UInt8(count >> 8), UInt8(count & 0xff)]) + data
    }
}

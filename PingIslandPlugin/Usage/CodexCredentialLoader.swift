import Foundation

/// Reads Codex OAuth credentials from ~/.codex/auth.json
struct CodexCredentials {
    let accessToken: String
    let refreshToken: String?
    let accountId: String?
    let email: String?
    let lastRefresh: String?
    let hasOAuthTokens: Bool
}

final class CodexCredentialLoader {

    private let authFilePath: String

    init(authFilePath: String? = nil) {
        self.authFilePath = authFilePath ?? Self.defaultAuthPath()
    }

    func loadCredentials() -> CodexCredentials? {
        guard FileManager.default.fileExists(atPath: authFilePath) else { return nil }

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: authFilePath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        // Check for OAuth tokens
        if let tokens = json["tokens"] as? [String: Any],
           let accessToken = tokens["access_token"] as? String,
           !accessToken.isEmpty {
            let refreshToken = tokens["refresh_token"] as? String
            let accountId = tokens["account_id"] as? String
            let lastRefresh = json["last_refresh"] as? String

            // Try to extract email and account_id from JWT
            let jwtInfo = Self.parseJWT(accessToken)
            let resolvedAccountId = accountId ?? jwtInfo.accountId
            let resolvedEmail = jwtInfo.email

            return CodexCredentials(
                accessToken: accessToken,
                refreshToken: refreshToken,
                accountId: resolvedAccountId,
                email: resolvedEmail,
                lastRefresh: lastRefresh,
                hasOAuthTokens: true
            )
        }

        // Has API key but no OAuth tokens
        if let apiKey = json["OPENAI_API_KEY"] as? String, !apiKey.isEmpty {
            return CodexCredentials(
                accessToken: apiKey,
                refreshToken: nil,
                accountId: nil,
                email: nil,
                lastRefresh: nil,
                hasOAuthTokens: false
            )
        }

        return nil
    }

    func saveUpdatedTokens(accessToken: String, refreshToken: String?, idToken: String?) {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: authFilePath)),
              var json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) else {
            return
        }

        var tokens = json["tokens"] as? [String: Any] ?? [:]
        tokens["access_token"] = accessToken
        if let refreshToken { tokens["refresh_token"] = refreshToken }
        if let idToken { tokens["id_token"] = idToken }
        json["tokens"] = tokens
        json["last_refresh"] = ISO8601DateFormatter().string(from: Date())

        if let updated = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]) {
            try? updated.write(to: URL(fileURLWithPath: authFilePath), options: .atomic)
        }
    }

    func needsRefresh(lastRefresh: String?) -> Bool {
        guard let lastRefresh else { return true }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: lastRefresh) else {
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = formatter.date(from: lastRefresh) else { return true }
            return Date().timeIntervalSince(date) > 8 * 86400
        }
        return Date().timeIntervalSince(date) > 8 * 86400
    }

    // MARK: - JWT Parsing (minimal, no dependencies)

    private struct JWTInfo {
        let email: String?
        let accountId: String?
    }

    private static func parseJWT(_ jwt: String) -> JWTInfo {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2,
              let payloadData = base64URLDecode(String(parts[1])) else {
            return JWTInfo(email: nil, accountId: nil)
        }
        guard let claims = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            return JWTInfo(email: nil, accountId: nil)
        }

        // OpenAI JWT structure: https://api.openai.com/auth contains chatgpt_account_id
        let auth = claims["https://api.openai.com/auth"] as? [String: Any]
        let profile = claims["https://api.openai.com/profile"] as? [String: Any]
        let email = claims["email"] as? String ?? profile?["email"] as? String
        let accountId = auth?["chatgpt_account_id"] as? String

        return JWTInfo(email: email, accountId: accountId)
    }

    private static func base64URLDecode(_ value: String) -> Data? {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let paddingLength = (4 - base64.count % 4) % 4
        if paddingLength > 0 {
            base64.append(String(repeating: "=", count: paddingLength))
        }
        return Data(base64Encoded: base64, options: [.ignoreUnknownCharacters])
    }

    private static func defaultAuthPath() -> String {
        "\(NSHomeDirectory())/.codex/auth.json"
    }
}

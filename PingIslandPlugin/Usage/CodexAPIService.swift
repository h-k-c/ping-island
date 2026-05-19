import Foundation

/// OpenAI Codex usage API service — fetches rate limit / quota data
/// Uses OAuth tokens from ~/.codex/auth.json
final class CodexAPIService {

    // MARK: - Published state

    private(set) var usageData: CodexUsageData?
    private(set) var isLoading = false
    private(set) var needsLogin = false
    private(set) var errorMessage: String?

    var onUsageUpdated: ((CodexUsageData) -> Void)?
    var onNeedsLogin: (() -> Void)?
    var onError: ((String) -> Void)?
    var onLoadingChanged: ((Bool) -> Void)?

    // MARK: - Config

    private static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    private static let refreshURL = URL(string: "https://auth.openai.com/oauth/token")!
    private static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"

    private let urlSession: URLSession
    private let credentialLoader: CodexCredentialLoader
    private let timeout: TimeInterval = 15

    // MARK: - Init

    init(credentialLoader: CodexCredentialLoader = CodexCredentialLoader()) {
        let config = URLSessionConfiguration.default
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        self.urlSession = URLSession(configuration: config)
        self.credentialLoader = credentialLoader
    }

    // MARK: - Public API

    func refresh() {
        guard !isLoading else { return }

        guard let credentials = credentialLoader.loadCredentials() else {
            DispatchQueue.main.async {
                self.needsLogin = true
                self.onNeedsLogin?()
            }
            return
        }

        // API key only — no OAuth tokens
        guard credentials.hasOAuthTokens else {
            DispatchQueue.main.async {
                self.needsLogin = true
                self.errorMessage = "需要 ChatGPT 账号登录 Codex"
                self.onNeedsLogin?()
                self.onError?("需要 ChatGPT 账号登录 Codex")
            }
            return
        }

        isLoading = true
        DispatchQueue.main.async { self.onLoadingChanged?(true) }

        // Check if token needs proactive refresh
        if credentialLoader.needsRefresh(lastRefresh: credentials.lastRefresh) {
            refreshToken(credentials) { [weak self] refreshed in
                guard let self else { return }
                let creds = refreshed ?? credentials
                self.fetchUsage(credentials: creds)
            }
        } else {
            fetchUsage(credentials: credentials)
        }
    }

    // MARK: - Usage Fetch

    private func fetchUsage(credentials: CodexCredentials) {
        var request = URLRequest(url: Self.usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("OpenUsage", forHTTPHeaderField: "User-Agent")
        if let accountId = credentials.accountId {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        request.timeoutInterval = timeout

        urlSession.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            let http = response as? HTTPURLResponse

            // 401 → try refresh once
            if http?.statusCode == 401 || http?.statusCode == 403 {
                self.refreshToken(credentials) { [weak self] refreshed in
                    guard let self, let refreshed else {
                        self?.handleAuthError()
                        return
                    }
                    self.fetchUsage(credentials: refreshed)
                }
                return
            }

            DispatchQueue.main.async {
                self.isLoading = false
                self.onLoadingChanged?(false)
            }

            guard let data, error == nil, http?.statusCode == 200 else {
                let msg = error?.localizedDescription ?? "HTTP \(http?.statusCode ?? 0)"
                DispatchQueue.main.async {
                    self.errorMessage = msg
                    self.onError?(msg)
                }
                return
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                DispatchQueue.main.async {
                    self.errorMessage = "API 响应无效"
                    self.onError?("API 响应无效")
                }
                return
            }

            guard let parsed = CodexUsageData.parse(from: json, email: credentials.email) else {
                DispatchQueue.main.async {
                    self.errorMessage = "解析失败"
                    self.onError?("解析失败")
                }
                return
            }

            DispatchQueue.main.async {
                self.usageData = parsed
                self.errorMessage = nil
                self.needsLogin = false
                self.onUsageUpdated?(parsed)
            }
        }.resume()
    }

    // MARK: - Token Refresh

    private func refreshToken(_ credentials: CodexCredentials, completion: @escaping (CodexCredentials?) -> Void) {
        guard let refreshToken = credentials.refreshToken else {
            completion(nil)
            return
        }

        var request = URLRequest(url: Self.refreshURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout

        let body = "grant_type=refresh_token"
            + "&client_id=\(Self.clientID)"
            + "&refresh_token=\(refreshToken.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? refreshToken)"
        request.httpBody = body.data(using: .utf8)

        urlSession.dataTask(with: request) { [weak self] data, response, _ in
            guard let self, let data,
                  let http = response as? HTTPURLResponse,
                  http.statusCode >= 200, http.statusCode < 300,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let newAccessToken = json["access_token"] as? String,
                  !newAccessToken.isEmpty else {
                completion(nil)
                return
            }

            let newRefreshToken = json["refresh_token"] as? String
            let newIdToken = json["id_token"] as? String

            // Save updated tokens
            self.credentialLoader.saveUpdatedTokens(
                accessToken: newAccessToken,
                refreshToken: newRefreshToken ?? credentials.refreshToken,
                idToken: newIdToken
            )

            let updated = CodexCredentials(
                accessToken: newAccessToken,
                refreshToken: newRefreshToken ?? credentials.refreshToken,
                accountId: credentials.accountId,
                email: credentials.email,
                lastRefresh: ISO8601DateFormatter().string(from: Date()),
                hasOAuthTokens: true
            )
            completion(updated)
        }.resume()
    }

    private func handleAuthError() {
        DispatchQueue.main.async {
            self.isLoading = false
            self.needsLogin = true
            self.onLoadingChanged?(false)
            self.onNeedsLogin?()
            self.onError?("Codex 登录已过期，请在终端运行 codex 重新登录")
        }
    }
}

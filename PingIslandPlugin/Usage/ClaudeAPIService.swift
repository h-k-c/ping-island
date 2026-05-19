import Foundation

/// Claude.ai API service — fetches real-time usage data using sessionKey cookie auth
/// Adapted from Claude-Usage-Monitor with protocol-based architecture
final class ClaudeAPIService {

    // MARK: - Published state

    private(set) var usageData: UsageData?
    private(set) var isLoading = false
    private(set) var needsLogin = false
    private(set) var errorMessage: String?

    var onUsageUpdated: ((UsageData) -> Void)?
    var onNeedsLogin: (() -> Void)?
    var onError: ((String) -> Void)?
    var onLoadingChanged: ((Bool) -> Void)?

    // MARK: - Config

    private let baseURL = "https://claude.ai/api"
    private let urlSession: URLSession

    // MARK: - Persisted credentials (Keychain-backed)

    var sessionKey: String? {
        get { KeychainHelper.read(key: "claudeSessionKey") }
        set {
            if let v = newValue, !v.isEmpty {
                try? KeychainHelper.save(key: "claudeSessionKey", value: v)
            } else {
                try? KeychainHelper.delete(key: "claudeSessionKey")
            }
        }
    }

    private var orgId: String? {
        get { KeychainHelper.read(key: "claudeOrgId") }
        set {
            if let v = newValue, !v.isEmpty {
                try? KeychainHelper.save(key: "claudeOrgId", value: v)
            } else {
                try? KeychainHelper.delete(key: "claudeOrgId")
            }
        }
    }

    // MARK: - Init

    init() {
        let config = URLSessionConfiguration.default
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        self.urlSession = URLSession(configuration: config)
    }

    // MARK: - Public API

    func refresh() {
        guard !isLoading else { return }
        guard let key = sessionKey, !key.isEmpty else {
            DispatchQueue.main.async {
                self.needsLogin = true
                self.onNeedsLogin?()
            }
            return
        }
        isLoading = true
        DispatchQueue.main.async { self.onLoadingChanged?(true) }

        if let existingOrgId = orgId {
            fetchUsage(sessionKey: key, orgId: existingOrgId)
        } else {
            fetchOrgId(sessionKey: key) { [weak self] resolvedOrgId in
                guard let self else { return }
                if let id = resolvedOrgId {
                    self.orgId = id
                    self.fetchUsage(sessionKey: key, orgId: id)
                } else {
                    DispatchQueue.main.async {
                        self.isLoading = false
                        self.errorMessage = "无法获取组织 ID"
                        self.onLoadingChanged?(false)
                        self.onError?("无法获取组织 ID，请检查 sessionKey 是否正确")
                    }
                }
            }
        }
    }

    func logout() {
        sessionKey = nil
        orgId = nil
        usageData = nil
        needsLogin = true
    }


    // MARK: - Request builder

    private func makeRequest(path: String, sessionKey: String) -> URLRequest {
        var req = URLRequest(url: URL(string: "\(baseURL)\(path)")!)
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        req.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        req.setValue("https://claude.ai/settings/usage", forHTTPHeaderField: "Referer")
        req.setValue("https://claude.ai", forHTTPHeaderField: "Origin")
        req.setValue("empty", forHTTPHeaderField: "Sec-Fetch-Dest")
        req.setValue("cors", forHTTPHeaderField: "Sec-Fetch-Mode")
        req.setValue("same-origin", forHTTPHeaderField: "Sec-Fetch-Site")
        req.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        return req
    }

    // MARK: - Network calls

    private func fetchOrgId(sessionKey: String, completion: @escaping (String?) -> Void) {
        let req = makeRequest(path: "/organizations", sessionKey: sessionKey)
        urlSession.dataTask(with: req) { [weak self] data, response, _ in
            guard let self else { return }
            let http = response as? HTTPURLResponse
            if http?.statusCode == 401 || http?.statusCode == 403 {
                DispatchQueue.main.async {
                    self.orgId = nil
                    self.isLoading = false
                    self.needsLogin = true
                    self.onLoadingChanged?(false)
                    self.onNeedsLogin?()
                    self.onError?("Session 已过期，请重新获取 sessionKey")
                }
                completion(nil)
                return
            }
            guard let data,
                  http?.statusCode == 200,
                  let orgs = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  let first = orgs.first,
                  let uuid = (first["uuid"] as? String) ?? (first["id"] as? String)
            else {
                completion(nil)
                return
            }
            completion(uuid)
        }.resume()
    }

    private func fetchUsage(sessionKey: String, orgId: String) {
        let req = makeRequest(path: "/organizations/\(orgId)/usage", sessionKey: sessionKey)
        urlSession.dataTask(with: req) { [weak self] data, response, error in
            guard let self else { return }
            DispatchQueue.main.async {
                self.isLoading = false
                let http = response as? HTTPURLResponse
                if http?.statusCode == 401 || http?.statusCode == 403 {
                    self.orgId = nil
                    self.needsLogin = true
                    self.onNeedsLogin?()
                    self.onError?("Session 已过期，请重新获取 sessionKey")
                    return
                }
                guard let data, error == nil else {
                    self.errorMessage = error?.localizedDescription ?? "网络错误"
                    return
                }
                guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    self.errorMessage = "API 响应无效"
                    return
                }
                let parsed = APIResponseParser.parse(body)
                self.usageData = parsed
                self.errorMessage = nil
                self.needsLogin = false
                self.onUsageUpdated?(parsed)
                self.fetchRoutineBudget(sessionKey: sessionKey, orgId: orgId)
            }
        }.resume()
    }

    private func fetchRoutineBudget(sessionKey: String, orgId: String) {
        var req = URLRequest(url: URL(string: "https://claude.ai/v1/code/routines/run-budget")!)
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        req.setValue("https://claude.ai/settings/usage", forHTTPHeaderField: "Referer")
        req.setValue("https://claude.ai", forHTTPHeaderField: "Origin")
        req.setValue("empty", forHTTPHeaderField: "Sec-Fetch-Dest")
        req.setValue("cors", forHTTPHeaderField: "Sec-Fetch-Mode")
        req.setValue("same-origin", forHTTPHeaderField: "Sec-Fetch-Site")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("ccr-triggers-2026-01-30", forHTTPHeaderField: "anthropic-beta")
        req.setValue(orgId, forHTTPHeaderField: "x-organization-uuid")
        req.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        urlSession.dataTask(with: req) { [weak self] data, response, _ in
            guard let self else { return }
            let http = response as? HTTPURLResponse
            guard let data, http?.statusCode == 200,
                  let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            let used = Int(body["used"] as? String ?? "") ?? (body["used"] as? Int ?? 0)
            let limit = Int(body["limit"] as? String ?? "") ?? (body["limit"] as? Int ?? 0)
            DispatchQueue.main.async {
                self.usageData?.routineRunsUsed = used
                self.usageData?.routineRunsLimit = limit
                if let data = self.usageData {
                    self.onUsageUpdated?(data)
                }
            }
        }.resume()
    }
}

// MARK: - Response parser

private enum APIResponseParser {

    static func parse(_ body: [String: Any]) -> UsageData {
        let fiveHour = body["five_hour"] as? [String: Any]
        let sevenDay = body["seven_day"] as? [String: Any]
        let extraUsage = body["extra_usage"] as? [String: Any]

        let sonnet: [String: Any]? = (body["seven_day_sonnet"] as? [String: Any])
            ?? (body["sonnet"] as? [String: Any])
            ?? (body["sonnet_only"] as? [String: Any])
            ?? (body["seven_day_sonnet_only"] as? [String: Any])

        let claudeDesign: [String: Any]? = (body["seven_day_omelette"] as? [String: Any])
            ?? (body["omelette_promotional"] as? [String: Any])

        let tierRaw = body["rate_limit_tier"] as? String ?? ""

        let sessionPct = utilization(fiveHour)
        let weeklyPct = utilization(sevenDay)
        let sonnetPct = utilization(sonnet)
        let claudeDesignPct = utilization(claudeDesign)

        let resetDate = isoDate(fiveHour?["resets_at"])
        let weeklyResetDate = isoDate(sevenDay?["resets_at"])
        let sonnetResetDate = isoDate(sonnet?["resets_at"])
        let claudeDesignResetDate = isoDate(claudeDesign?["resets_at"])

        let sessionUsed = Int((sessionPct * 100).rounded())
        let sessionLimit = fiveHour != nil ? 100 : 0
        let msgUsed = Int((weeklyPct * 100).rounded())
        let msgLimit = sevenDay != nil ? 100 : 0

        var weeklyResetText = ""
        if let wd = weeklyResetDate {
            let f = DateFormatter()
            f.dateFormat = "EEE h:mm a"
            weeklyResetText = f.string(from: wd)
        }

        var data = UsageData(
            planType: planType(from: tierRaw),
            sessionUsed: sessionUsed,
            sessionLimit: sessionLimit,
            messagesUsed: msgUsed,
            messagesLimit: msgLimit,
            resetDate: resetDate,
            weeklyResetDate: weeklyResetDate,
            weeklyResetText: weeklyResetText,
            sonnetPercentage: sonnetPct,
            sonnetResetDate: sonnetResetDate,
            claudeDesignPercentage: claudeDesignPct,
            claudeDesignResetDate: claudeDesignResetDate,
            lastUpdated: Date()
        )

        if extraUsage?["is_enabled"] as? Bool == true ||
            extraUsage?["is_enabled"] as? Int == 1 {
            data.extraUsageSpent = doubleValue(extraUsage?["used_credits"])
            data.extraUsageLimit = doubleValue(extraUsage?["monthly_limit"])
        }

        return data
    }

    private static func doubleValue(_ v: Any?) -> Double {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        return 0
    }

    private static func utilization(_ window: [String: Any]?) -> Double {
        guard let v = window?["utilization"] else { return 0 }
        if let d = v as? Double { return min(1.0, d / 100.0) }
        if let i = v as? Int { return min(1.0, Double(i) / 100.0) }
        return 0
    }

    private static func isoDate(_ v: Any?) -> Date? {
        guard let s = v as? String, !s.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: s)
    }

    private static func planType(from tier: String) -> String {
        let t = tier.lowercased()
        if t.contains("max") { return "Max" }
        if t.contains("pro") { return "Pro" }
        if t.contains("team") { return "Team" }
        if t.contains("free") { return "Free" }
        return tier.isEmpty ? "Unknown" : tier
    }
}

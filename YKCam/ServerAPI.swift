import Foundation
import Security

/// 和自建 ykcam 服务器通信。配对后服务器发一个 cookie（ykcam=...），存在钥匙串里，之后每个请求都带上。
/// 这个 cookie 只有「摄像头」身份：能上传和传实时画面，看不了历史记录和他人画面。
enum ServerAPI {
    private static let serverURLKey = "serverURL"

    static var defaultServerURL: String {
        (Bundle.main.object(forInfoDictionaryKey: "YKCAMServerURL") as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static var configuredServerString: String {
        get {
            let saved = (UserDefaults.standard.string(forKey: serverURLKey) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return saved.isEmpty ? defaultServerURL : saved
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                UserDefaults.standard.removeObject(forKey: serverURLKey)
            } else {
                UserDefaults.standard.set(trimmed, forKey: serverURLKey)
            }
        }
    }

    static func normalizeBaseURL(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.contains("://") { s = "https://\(s)" }
        while s.hasSuffix("/") { s.removeLast() }
        guard let comps = URLComponents(string: s),
              let scheme = comps.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = comps.host, !host.isEmpty else {
            return nil
        }
        return comps.url
    }

    static func webSocketURL(from base: URL) -> URL? {
        guard var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        comps.scheme = comps.scheme?.lowercased() == "http" ? "ws" : "wss"
        let basePath = comps.path == "/" ? "" : comps.path.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        comps.path = basePath + "/ws/agent"
        return comps.url
    }

    static var base: URL? { normalizeBaseURL(configuredServerString) }
    static var socketURL: URL? { base.flatMap(webSocketURL(from:)) }
    static var hostLabel: String { base?.host ?? "" }
    static var isPaired: Bool { base != nil && cookie != nil }

    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieAcceptPolicy = .never
        c.httpShouldSetCookies = false
        c.timeoutIntervalForRequest = 20
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    static let quickSession: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieAcceptPolicy = .never
        c.httpShouldSetCookies = false
        c.timeoutIntervalForRequest = 8
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    enum APIError: LocalizedError {
        case server(String)
        case invalidURL
        case notPaired
        var errorDescription: String? {
            switch self {
            case .server(let m): return m
            case .invalidURL: return "服务器地址格式不对，例如 https://example.com"
            case .notPaired: return "这台手机还没配对服务器"
            }
        }
    }

    // MARK: 登录 cookie

    static var cookie: String? {
        get { Keychain.read("session") }
        set { if let v = newValue { Keychain.write("session", v) } else { Keychain.delete("session") } }
    }

    static func clearPairing() {
        cookie = nil
        UserDefaults.standard.removeObject(forKey: "camName")
    }

    static func request(_ path: String, method: String = "GET", query: [String: String] = [:], baseURL: URL? = nil) throws -> URLRequest {
        guard let root = baseURL ?? base else { throw APIError.invalidURL }
        var comps = URLComponents(url: root.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        if let c = cookie { req.setValue("ykcam=\(c)", forHTTPHeaderField: "Cookie") }
        return req
    }

    private static func errorText(_ data: Data, _ status: Int) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let e = obj["error"] as? String { return e }
        return "服务器返回 \(status)"
    }

    // MARK: 配对

    /// 用主力手机「设置」→「添加摄像头手机」生成的 6 位码配对，返回服务器记下的名字
    static func pair(server: String, code: String, name: String) async throws -> String {
        guard let target = normalizeBaseURL(server) else { throw APIError.invalidURL }
        var req = try request("api/camera/pair", method: "POST", baseURL: target)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["code": code, "name": name])
        let (data, resp) = try await session.data(for: req)
        let http = resp as! HTTPURLResponse
        guard http.statusCode == 200 else { throw APIError.server(errorText(data, http.statusCode)) }
        let setCookie = http.value(forHTTPHeaderField: "Set-Cookie") ?? ""
        guard let m = setCookie.range(of: #"ykcam=([a-f0-9]{64})"#, options: .regularExpression) else {
            throw APIError.server("服务器没有给登录凭证")
        }
        configuredServerString = target.absoluteString
        cookie = String(setCookie[m].dropFirst("ykcam=".count))
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return obj?["name"] as? String ?? name
    }

    /// 已配对就返回名字；没配对或被主力手机移除返回 nil；连不上服务器抛错
    static func me() async throws -> String? {
        guard cookie != nil, base != nil else { return nil }
        let req = try request("api/camera/me")
        let (data, resp) = try await quickSession.data(for: req)
        let status = (resp as! HTTPURLResponse).statusCode
        if status == 401 { return nil }
        guard status == 200 else { throw APIError.server(errorText(data, status)) }
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return obj?["name"] as? String
    }

    // MARK: 上传

    /// 返回 true 表示这一项处理完了（成功，或服务器明确拒绝、重试也没用），可以删掉本地这份
    static func upload(_ path: String, query: [String: String], body: Data, contentType: String) async -> Bool? {
        guard isPaired, var req = try? request(path, method: "POST", query: query) else { return nil }
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        do {
            let (_, resp) = try await session.upload(for: req, from: body)
            let status = (resp as! HTTPURLResponse).statusCode
            if status == 200 || (400..<500).contains(status) { return true }
            return false
        } catch {
            return nil   // 连不上，稍后再试
        }
    }

    static func post(_ path: String, body: Data = Data(), contentType: String = "application/octet-stream") async {
        guard isPaired, var req = try? request(path, method: "POST") else { return }
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        _ = try? await session.upload(for: req, from: body)
    }
}

/// 极简钥匙串：只存这台手机的登录凭证
enum Keychain {
    private static let service = "com.rookiei1.ykcam"

    static func read(_ key: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: key, kSecReturnData as String: true]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func write(_ key: String, _ value: String) {
        delete(key)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: key, kSecValueData as String: Data(value.utf8),
                                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        SecItemAdd(q as CFDictionary, nil)
    }

    static func delete(_ key: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: key]
        SecItemDelete(q as CFDictionary)
    }
}

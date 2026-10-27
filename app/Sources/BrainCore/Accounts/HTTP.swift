import Foundation

/// Sends one request and returns the body and the HTTP response. Injectable so providers can be tested with fixtures.
public typealias HTTPTransport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

/// Small URLSession helpers shared by the OAuth client and the Microsoft Graph / Google providers (CONTRACT §12.3).
public enum HTTP {
    /// No disk cache, no cookies: mail never lands in a URL cache on disk.
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpAdditionalHeaders = ["User-Agent": "SecondBrain-mac"]
        return URLSession(configuration: config)
    }()

    /// The real network. URL errors become `AccountError.network`; a cancelled task stays `CancellationError`.
    public static let urlSession: HTTPTransport = { request in
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw AccountError.network("no HTTP response") }
            return (data, http)
        } catch let error as URLError {
            if error.code == .cancelled || Task.isCancelled { throw CancellationError() }
            throw AccountError.network(error.localizedDescription)
        }
    }

    // MARK: Encoding

    /// RFC 3986 unreserved characters plus a few that Graph/Google expect literally in query strings (`$top`, `:`, `'`).
    private static let queryAllowed: CharacterSet = {
        var set = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        set.insert(charactersIn: "$:'/,")
        return set
    }()
    /// Strict form encoding (`application/x-www-form-urlencoded` bodies): only unreserved characters stay as they are.
    private static let formAllowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")

    static func encodeQuery(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: queryAllowed) ?? s }
    static func encodeForm(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: formAllowed) ?? s }

    /// `base` + `?a=b&c=d`, every name and value percent-encoded (spaces as %20, `+` as %2B).
    public static func url(_ base: String, query: [(String, String)] = []) -> URL {
        guard !query.isEmpty else { return URL(string: base)! }
        let q = query.map { "\(encodeQuery($0.0))=\(encodeQuery($0.1))" }.joined(separator: "&")
        return URL(string: base + (base.contains("?") ? "&" : "?") + q)!
    }

    public static func formBody(_ fields: [(String, String)]) -> Data {
        Data(fields.map { "\(encodeForm($0.0))=\(encodeForm($0.1))" }.joined(separator: "&").utf8)
    }

    static func formRequest(_ url: URL, _ fields: [(String, String)]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = formBody(fields)
        return request
    }

    /// Base64url (RFC 4648 §5) without padding, as PKCE and Gmail use it.
    public static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Decodes base64url with or without padding (also accepts plain base64).
    public static func base64urlDecode(_ s: String) -> Data? {
        var b = s.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        b = b.replacingOccurrences(of: "=", with: "")
        let rem = b.count % 4
        if rem == 1 { return nil }
        if rem > 0 { b += String(repeating: "=", count: 4 - rem) }
        return Data(base64Encoded: b, options: .ignoreUnknownCharacters)
    }

    /// Text of a body in an unknown charset: UTF-8 first, then Windows-1252 (never fails).
    static func text(_ data: Data) -> String {
        String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) ?? String(decoding: data, as: UTF8.self)
    }

    // MARK: Errors

    /// 2xx passes; anything else becomes an `AccountError` (401 → `.unauthorized`, organization blocks →
    /// `.consentRequired`, throttling and server errors → `.network`).
    static func check(_ data: Data, _ response: HTTPURLResponse, provider: AccountProvider) throws {
        guard !(200..<300).contains(response.statusCode) else { return }
        throw AccountErrorMapper.map(provider: provider, status: response.statusCode, body: data)
    }

    // MARK: Text helpers

    /// `&amp;` `&#39;` `&#x27;` … → characters (Gmail snippets and Google Calendar descriptions come HTML-escaped).
    public static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        let named = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " "]
        var out = ""
        var rest = Substring(s)
        while let amp = rest.firstIndex(of: "&") {
            out += rest[..<amp]
            let after = rest[rest.index(after: amp)...]
            if let semi = after.prefix(10).firstIndex(of: ";") {
                let name = String(after[..<semi])
                var replacement: String?
                if name.hasPrefix("#x") || name.hasPrefix("#X"), let v = UInt32(name.dropFirst(2), radix: 16) {
                    replacement = Unicode.Scalar(v).map { String(Character($0)) }
                } else if name.hasPrefix("#"), let v = UInt32(name.dropFirst()) {
                    replacement = Unicode.Scalar(v).map { String(Character($0)) }
                } else {
                    replacement = named[name.lowercased()]
                }
                if let replacement {
                    out += replacement
                    rest = after[after.index(after: semi)...]
                    continue
                }
            }
            out += "&"
            rest = after
        }
        return out + rest
    }
}

/// Authorized GETs for one account: bearer token from `TokenManager`, one refresh + retry on 401, errors mapped to
/// `AccountError`.
public struct APIClient: Sendable {
    public let provider: AccountProvider
    public let tokens: TokenManager
    public let transport: HTTPTransport

    public init(provider: AccountProvider, tokens: TokenManager, transport: @escaping HTTPTransport = HTTP.urlSession) {
        self.provider = provider; self.tokens = tokens; self.transport = transport
    }

    public func get(_ url: URL, headers: [String: String] = [:]) async throws -> Data {
        try Task.checkCancellation()
        var token = try await tokens.accessToken()
        var (data, response) = try await send(url, token: token, headers: headers)
        if response.statusCode == 401 {
            token = try await tokens.forceRefresh()
            (data, response) = try await send(url, token: token, headers: headers)
        }
        try HTTP.check(data, response, provider: provider)
        return data
    }

    private func send(_ url: URL, token: String, headers: [String: String]) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        return try await transport(request)
    }
}

/// Title for calendar events without one.
var untitledEvent: String { OAuthClient.lang.t("(sin título)", "(no title)") }

/// Decodes a provider's JSON or says the answer was unexpected.
func decodeJSON<T: Decodable>(_ type: T.Type, _ data: Data, provider: AccountProvider) throws -> T {
    do { return try JSONDecoder().decode(T.self, from: data) } catch {
        throw AccountError.failed("Unexpected \(provider.displayName) response (\(error.localizedDescription))")
    }
}

/// Turns OAuth and API error codes into `AccountError` (CONTRACT §12.3: organization blocks → `.consentRequired`).
public enum AccountErrorMapper {
    /// Codes meaning "your organization has to approve SecondBrain".
    public static let consentMarkers = [
        "AADSTS65001", "AADSTS650052", "AADSTS90094", "AADSTS7000112", "consent_required", "admin_consent",
        "access_denied", "org_internal", "admin_policy_enforced", "disallowed_useragent",
    ]

    /// An OAuth `error` / `error_description` pair (redirect query or token endpoint).
    public static func map(provider: AccountProvider, error: String?, description: String?) -> AccountError {
        let code = error ?? ""
        let detail = description ?? ""
        let combined = "\(code) \(detail)"
        // Microsoft "the user declined to consent" (AADSTS65004) is a plain cancel, not an organization block.
        if combined.contains("AADSTS65004") { return .cancelled }
        if consentMarkers.contains(where: { combined.range(of: $0, options: .caseInsensitive) != nil }) {
            return .consentRequired(provider, detail: detail.isEmpty ? code : detail)
        }
        if code == "invalid_grant" || code == "invalid_token" || code == "interaction_required" { return .unauthorized }
        let message = [code, detail].filter { !$0.isEmpty }.joined(separator: ": ")
        return .failed(message.isEmpty ? "OAuth error" : message)
    }

    /// An HTTP error from the token endpoint, Microsoft Graph or a Google API.
    public static func map(provider: AccountProvider, status: Int, body: Data) -> AccountError {
        let (code, message) = errorFields(body)
        if code != nil || message != nil {
            let mapped = map(provider: provider, error: code, description: message)
            switch mapped {
            case .consentRequired, .cancelled: return mapped
            case .unauthorized where status == 400 || status == 401: return mapped
            default: break
            }
        }
        switch status {
        case 401: return .unauthorized
        case 429, 500...599:
            return .network(message ?? HTTPURLResponse.localizedString(forStatusCode: status))
        default:
            let text = [code, message].compactMap { $0 }.joined(separator: ": ")
            return .failed(text.isEmpty ? "HTTP \(status)" : text)
        }
    }

    /// `{"error":"x","error_description":"y"}` (OAuth), `{"error":{"code":"x","message":"y"}}` (Graph) or
    /// `{"error":{"code":403,"status":"PERMISSION_DENIED","message":"y","errors":[{"reason":"x"}]}}` (Google).
    static func errorFields(_ body: Data) -> (code: String?, message: String?) {
        guard let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            let text = HTTP.text(body).trimmingCharacters(in: .whitespacesAndNewlines)
            return (nil, text.isEmpty ? nil : String(text.prefix(300)))
        }
        if let code = obj["error"] as? String { return (code, obj["error_description"] as? String) }
        guard let err = obj["error"] as? [String: Any] else { return (nil, nil) }
        let reasons = (err["errors"] as? [[String: Any]])?.compactMap { $0["reason"] as? String } ?? []
        let code = (err["code"] as? String) ?? reasons.first ?? (err["status"] as? String)
        var message = err["message"] as? String
        // Keep the Google reasons visible to the mapper (e.g. "access_denied" hidden in a 403's reasons).
        if !reasons.isEmpty, let m = message, !reasons.allSatisfy({ m.contains($0) }) { message = m + " (" + reasons.joined(separator: ", ") + ")" }
        return (code, message)
    }
}

/// Finds a Teams / Meet / Zoom / Webex join link in event text (location, notes, URL field).
public enum JoinLink {
    private static let patterns = [
        #"https://teams\.microsoft\.com/l/meetup-join/[^\s<>"')\]]+"#,
        #"https://teams\.live\.com/meet/[^\s<>"')\]]+"#,
        #"https://meet\.google\.com/[a-z]{3}-[a-z]{4}-[a-z]{3}(\?[^\s<>"')\]]*)?"#,
        #"https://([a-z0-9-]+\.)?zoom\.us/(j|my|w|s)/[^\s<>"')\]]+"#,
        #"https://([a-z0-9-]+\.)?zoomgov\.com/(j|my|w|s)/[^\s<>"')\]]+"#,
        #"https://[a-z0-9-]+\.webex\.com/[^\s<>"')\]]+"#,
        #"https://whereby\.com/[^\s<>"')\]]+"#,
    ]
    private static let regexes = patterns.compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    /// The first video-call link found in `texts` (in order), or nil.
    public static func find(in texts: [String?]) -> URL? {
        for text in texts.compactMap({ $0 }) where !text.isEmpty {
            let ns = text as NSString
            var best: (location: Int, url: String)?
            for re in regexes {
                if let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
                   best == nil || m.range.location < best!.location {
                    best = (m.range.location, ns.substring(with: m.range))
                }
            }
            if let best {
                let trimmed = best.url.trimmingCharacters(in: CharacterSet(charactersIn: ".,;>"))
                if let url = URL(string: trimmed) { return url }
            }
        }
        return nil
    }

    /// Whether `url` itself is a video-call link: an https URL that is the whole match, never a link merely containing
    /// one (`smb://host/x#https://zoom.us/j/1`, a custom app scheme…).
    public static func isJoinLink(_ url: URL?) -> Bool {
        guard let url, isSafe(url) else { return false }
        return find(in: [url.absoluteString])?.absoluteString == url.absoluteString
    }

    /// Only https links are ever opened from a calendar invite (an invite is untrusted input).
    public static func isSafe(_ url: URL) -> Bool { url.scheme?.lowercased() == "https" && url.host?.isEmpty == false }

    /// A provider's join URL string, kept only when it is https.
    public static func https(_ string: String?) -> URL? {
        guard let s = string?.trimmingCharacters(in: .whitespacesAndNewlines), let url = URL(string: s), isSafe(url) else { return nil }
        return url
    }
}

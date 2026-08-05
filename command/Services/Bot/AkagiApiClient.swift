//
//  AkagiApiClient.swift
//  Naki
//
//  Akagi 推論伺服器（`/v3/*`）的 HTTP client。協定參考
//  `docs/reference/akagi-inference-api.md`（2026-08-04 以 v3 原始碼重驗）。
//
//  範圍（2026-08-04 定案）：只做 `/v3/react`、`/healthz`、`/v3/models`。
//  `/v3/redeem` 與購買流程不做（key 由使用者自行取得貼上）；`/v3/key` 額度
//  查詢 v1 不做。proxy 不做——少一整類「錯誤訊息回顯 proxy 密碼」的風險面。
//
//  逾時：react 2 秒（雀魂回合計時器 ~5s，立直要兩次呼叫，兩次都要擠進同一
//  回合——Akagi 生產環境的推導，沿用）；管理端點 8 秒（不在對局關鍵路徑）。
//
//  安全不變式：key 只進 `Authorization` header，**永不**進 URL、log 或錯誤訊息。
//

import Foundation

// MARK: - Response 型別

/// `POST /v3/react` 的回應。三個欄位都可缺（空物件也要能解析）。
struct CloudReactResponse {
    /// 要打的動作（標準 mjai 事件）。伺服器認為該座位無合法動作時為 nil。
    let reaction: [String: Any]?
    /// top-k 粗標籤（`dahai:5p` / `reach` / `pon` / `chi_low` …），
    /// `candidates[0]` 對應 `reaction`。
    let candidates: [CloudCandidate]
    /// 實際服務這次請求的模型 id。
    let model: String?
}

/// top-k 的一列。
struct CloudCandidate: Equatable {
    let action: String
    let prob: Double
}

/// `GET /v3/models` 的一列。
struct CloudModelInfo: Equatable {
    let id: String
    let game: String
    let desc: String
}

/// `GET /healthz` 的回應。
struct CloudHealth {
    let status: String
    let models: [String]
}

// MARK: - 錯誤

enum CloudAPIError: Error, LocalizedError {
    /// base URL 解析不出來（設定錯誤，重試無益——呼叫端記 tombstone）
    case invalidURL
    /// 非 2xx。`message` 是伺服器 `{"error": "..."}` 或 body 前 200 字。
    case http(code: Int, message: String, retryAfter: String?)
    /// 傳輸層失敗（逾時、連不上、DNS…）
    case transport(String)
    /// 2xx 但 body 解析不出 JSON 物件
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "伺服器 URL 無法解析"
        case .http(let code, let message, let retryAfter):
            let hint = retryAfter.map { "（retry after \($0)s）" } ?? ""
            return "HTTP \(code) — \(message)\(hint)"
        case .transport(let message):
            return "連線失敗：\(message)"
        case .invalidResponse:
            return "回應不是合法 JSON"
        }
    }
}

// MARK: - Client

/// 綁定一組（伺服器、key）的 client。
///
/// **hold 一份重用**：URLSession 帶著連線池，每次重建都要重付 TCP+TLS 握手。
/// 呼叫端（`NativeBotController`）只在 URL 或 key 變更時重建（Akagi 同款規則）。
final class AkagiApiClient {

    /// react 在對局關鍵路徑上：掛掉的伺服器要**立刻**退回本地模型，
    /// 不能讓 bot 錯過回合。
    static let reactTimeout: TimeInterval = 2.0
    /// 管理端點（models / health）從 UI 呼叫，等得起慢伺服器。
    static let requestTimeout: TimeInterval = 8.0

    let base: String
    /// log 顯示用的主機名（不含 key、不含 path）。
    let host: String
    private let key: String
    private let session: URLSession

    /// 去頭尾空白與尾端斜線（`https://host/` 貼進來也能用）。
    static func normalize(baseURL: String) -> String {
        var trimmed = baseURL.trimmingCharacters(in: .whitespaces)
        while trimmed.hasSuffix("/") { trimmed = String(trimmed.dropLast()) }
        return trimmed
    }

    /// URL 解析不出（或 scheme 不是 http/https）回 nil——設定錯誤重試無益，
    /// 呼叫端應記 tombstone 只警告一次。
    /// `configuration` 供測試注入 `URLProtocol` stub；正式路徑用 ephemeral
    /// （不落 cache/cookie——上傳的是牌局資料，不留在磁碟上）。
    init?(baseURL: String, key: String,
          configuration: URLSessionConfiguration = .ephemeral) {
        let base = Self.normalize(baseURL: baseURL)
        guard let url = URL(string: base),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host else {
            return nil
        }
        self.base = base
        self.host = host
        self.key = key.trimmingCharacters(in: .whitespaces)
        self.session = URLSession(configuration: configuration)
    }

    /// `@MainActor` class 在 NakiTests host 釋放會 SIGABRT（見 CLAUDE.md「專案結構的坑」）
    nonisolated deinit {}

    // MARK: - 端點

    /// `POST /v3/react` — `events` 最後一個元素是決策點。
    /// `model` 空/nil ⇒ 不送欄位、伺服器用該遊戲預設。
    func react(model: String?, playerId: Int,
               events: [[String: Any]]) async throws -> CloudReactResponse {
        var body: [String: Any] = [
            "player_id": playerId,
            "events": events,
        ]
        if let model, !model.isEmpty {
            body["model"] = model
        }
        let object = try await post(path: "/v3/react", body: body,
                                    timeout: Self.reactTimeout, what: "react")
        return CloudReactResponse(
            reaction: object["reaction"] as? [String: Any],
            candidates: Self.candidates(from: object["candidates"]),
            model: object["model"] as? String)
    }

    /// `GET /v3/models` — 這把 key 可用的模型（回應包一層 `{"models": [...]}`）。
    func models() async throws -> [CloudModelInfo] {
        let object = try await get(path: "/v3/models", authorized: true,
                                   timeout: Self.requestTimeout, what: "models")
        let rows = object["models"] as? [[String: Any]] ?? []
        return rows.compactMap { row in
            guard let id = row["id"] as? String else { return nil }
            return CloudModelInfo(id: id,
                                  game: row["game"] as? String ?? "",
                                  desc: row["desc"] as? String ?? "")
        }
    }

    /// `GET /healthz`（無認證）— 對局開始前就能告訴使用者伺服器活不活，
    /// 不必等到第一手才發現。key 完全不經手，也就不會多送（無認證端點
    /// 收到 Authorization 是無謂洩漏）。
    static func health(baseURL: String,
                       configuration: URLSessionConfiguration = .ephemeral)
        async throws -> CloudHealth {
        guard let client = AkagiApiClient(baseURL: baseURL, key: "",
                                          configuration: configuration) else {
            throw CloudAPIError.invalidURL
        }
        let object = try await client.get(path: "/healthz", authorized: false,
                                          timeout: requestTimeout, what: "health")
        return CloudHealth(status: object["status"] as? String ?? "",
                           models: object["models"] as? [String] ?? [])
    }

    // MARK: - 傳輸

    private func post(path: String, body: [String: Any],
                      timeout: TimeInterval, what: String) async throws -> [String: Any] {
        guard let url = URL(string: base + path) else { throw CloudAPIError.invalidURL }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(request, what: what)
    }

    private func get(path: String, authorized: Bool,
                     timeout: TimeInterval, what: String) async throws -> [String: Any] {
        guard let url = URL(string: base + path) else { throw CloudAPIError.invalidURL }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        if authorized {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        return try await send(request, what: what)
    }

    private func send(_ request: URLRequest, what: String) async throws -> [String: Any] {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            // localizedDescription 不含我們放進 header 的 key；URL 主機名
            // 是使用者自己輸入的，出現在錯誤裡有診斷價值、無洩漏問題。
            throw CloudAPIError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw CloudAPIError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            // 伺服器約定：body 是 `{"error": "..."}`；解不出就取前 200 字。
            let message: String
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = object["error"] as? String {
                message = error
            } else {
                message = String(decoding: data.prefix(200), as: UTF8.self)
            }
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After")
            throw CloudAPIError.http(code: http.statusCode, message: message,
                                     retryAfter: retryAfter)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CloudAPIError.invalidResponse
        }
        // 原始回應落 log（debug 通道，非 event log）：伺服器給的數值細節
        // （top-k prob、served model…）只有這裡查得到——摘要行只有前 6 列。
        // 上限 2000 字防淹；回應不含 key，落 log 安全。
        botLog("[Cloud] \(what) ← \(String(decoding: data.prefix(2000), as: UTF8.self))")
        return object
    }

    private static func candidates(from value: Any?) -> [CloudCandidate] {
        guard let rows = value as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let action = row["action"] as? String else { return nil }
            return CloudCandidate(action: action,
                                  prob: row["prob"] as? Double ?? 0)
        }
    }
}

//
//  MajsoulRequestBuilder.swift
//  Naki
//
//  雀魂頁面主文件請求的組裝與 header 檢查。
//
//  WebKit 只讓 `URLRequest` 的自訂 header 作用於**主文件請求**；子資源與
//  WebSocket 握手不帶。唯一會套用到全部請求（含 WebSocket 握手）的是 User-Agent
//  （`customUserAgent`）。

import Foundation

enum MajsoulRequestBuilder {

    enum HeaderIssue: Equatable, Sendable {
        case invalidName
        case reservedName
        case invalidValue
    }

    /// URL 載入系統自己處理的 header（Apple 文件列的保留清單，加上 Content-Length／Cookie／
    /// Transfer-Encoding）。User-Agent 另有專用欄位，不允許在這裡重複設定。
    nonisolated static let reservedNames: Set<String> = [
        "authorization", "connection", "content-length", "cookie", "host",
        "proxy-authenticate", "proxy-authorization", "transfer-encoding",
        "upgrade", "user-agent", "www-authenticate",
    ]

    private nonisolated static let tokenCharacters = CharacterSet(
        charactersIn: "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")

    /// 名稱須為 RFC 9110 token（因此不含空白、冒號、換行）；值去頭尾空白後不得為空或含換行。
    nonisolated static func issue(name: String, value: String) -> HeaderIssue? {
        guard !name.isEmpty,
              name.unicodeScalars.allSatisfy(tokenCharacters.contains) else { return .invalidName }
        guard !reservedNames.contains(name.lowercased()) else { return .reservedName }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isNewline) else { return .invalidValue }
        return nil
    }

    /// 去頭尾空白後為空＝不覆寫，用 WebKit 預設。
    nonisolated static func userAgent(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 非法或保留的 header 直接略過；同名（不分大小寫）以排序在後者為準。
    nonisolated static func request(url: URL, extraHeaders: [String: String]) -> URLRequest {
        var request = URLRequest(url: url)
        for name in extraHeaders.keys.sorted() {
            let value = extraHeaders[name] ?? ""
            guard issue(name: name, value: value) == nil else { continue }
            request.setValue(value.trimmingCharacters(in: .whitespacesAndNewlines),
                             forHTTPHeaderField: name)
        }
        return request
    }
}

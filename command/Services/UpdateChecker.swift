//
//  UpdateChecker.swift
//  Naki
//
//  只檢查、不安裝：問 GitHub Releases 最新一版是什麼，由使用者自己去下載。
//  安裝包未簽章，原地替換等於在沒有驗簽下執行下載來的程式，所以不做。
//

import Foundation

nonisolated struct ReleaseInfo: Sendable, Equatable {
    /// 已去掉 `v` 前綴
    let version: String
    let url: URL
}

nonisolated enum UpdateChecker {

    static let latestReleaseURL =
        URL(string: "https://api.github.com/repos/Sunalamye/Naki/releases/latest")!

    private struct Payload: Decodable {
        let tag_name: String
        let html_url: URL
        let draft: Bool
        let prerelease: Bool
    }

    /// 匿名 GET，不帶任何識別。draft／prerelease 回 nil（`/latest` 本來就不會回，這裡只是防線）。
    static func fetchLatest(session: URLSession = .shared) async throws -> ReleaseInfo? {
        var request = URLRequest(url: latestReleaseURL, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let release = try JSONDecoder().decode(Payload.self, from: data)
        guard !release.draft, !release.prerelease else { return nil }
        return ReleaseInfo(version: normalize(tag: release.tag_name), url: release.html_url)
    }

    static func normalize(tag: String) -> String {
        tag.hasPrefix("v") || tag.hasPrefix("V") ? String(tag.dropFirst()) : tag
    }

    /// 數字段逐段比（`2.9.0 < 2.13.0`），字串比會判反。
    static func isNewer(_ remote: String, than local: String) -> Bool {
        remote.compare(local, options: .numeric) == .orderedDescending
    }

    /// 自動檢查：開關開著、且距上次成功檢查滿 24 小時。
    static func shouldAutoCheck(enabled: Bool, last: Date?, now: Date) -> Bool {
        enabled && (last.map { now.timeIntervalSince($0) >= 24 * 3600 } ?? true)
    }

    /// 有新版才提示；自動檢查時使用者略過的那一版不再提示，手動檢查不受略過影響。
    static func shouldSurface(_ info: ReleaseInfo, local: String,
                                          skipped: String?, manual: Bool) -> Bool {
        isNewer(info.version, than: local) && (manual || info.version != skipped)
    }
}

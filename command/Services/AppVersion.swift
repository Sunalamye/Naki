//
//  AppVersion.swift
//  Naki
//
//  App 版本的單一來源
//

import Foundation

/// App 版本一律讀 `Info.plist`（由 Xcode 的 `MARKETING_VERSION`／`CURRENT_PROJECT_VERSION` 產生）。
///
/// 任何地方（MCP `serverInfo.version`、`get_status.appVersion`、Debug 首頁）都不可以
/// 另外寫死版本字串：沒有任何機制會在改版時提醒去同步它，外部工具拿它判斷「跑的是哪一版
/// Naki」就會得到錯的答案。讀 bundle 的話，升版只要改 build setting。
enum NakiAppVersion {

    /// `CFBundleShortVersionString`（`MARKETING_VERSION`）
    nonisolated static var short: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }

    /// `CFBundleVersion`（build number）
    nonisolated static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    }

    /// `<short> (<build>)`——給人看的完整版本
    nonisolated static var full: String {
        "\(short) (\(build))"
    }
}

//
//  AppVersion.swift
//  Naki
//
//  App 版本的單一來源
//

import Foundation

/// App 版本一律讀 `Info.plist`（由 Xcode 的 `MARKETING_VERSION`／`CURRENT_PROJECT_VERSION` 產生）。
///
/// 先前 MCP `initialize` 的 `serverInfo.version` 寫死 `2.1.0`，而 App 已經是 `2.6.0`：
/// 外部工具拿 serverInfo 判斷「跑的是哪一版 Naki」會得到錯的答案，而且沒有任何機制
/// 會在改版時提醒去同步那個字串。改成讀 bundle 之後，升版只要改 build setting。
enum NakiAppVersion {

    /// `CFBundleShortVersionString`，例如 `2.6.0`
    nonisolated static var short: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }

    /// `CFBundleVersion`（build number）
    nonisolated static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    }

    /// `2.6.0 (1)`——給人看的完整版本
    nonisolated static var full: String {
        "\(short) (\(build))"
    }
}

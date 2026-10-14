//
//  GameHighlightScript.swift
//  Naki
//
//  §12（2026-08-11）起牌面自動高亮移交插件：`WebSession.syncHighlight` 只發布
//  `__nakiRecommendations`，不再注入 `__nakiHighlight.set()`。此檔只剩關閉顯示時用的 `clear`。
//

import Foundation

nonisolated enum GameHighlightScript {

    /// 清空所有標記
    static let clear = "window.__nakiHighlight?.clear();"
}

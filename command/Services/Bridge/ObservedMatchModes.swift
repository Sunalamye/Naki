//
//  ObservedMatchModes.swift
//  Naki
//
//  從遊戲自己的流量學 match_mode，不再靠寫死的對照表。
//

import Foundation

/// 觀察到的段位場 `match_mode` 值
///
/// 為什麼不用寫死的表：
///
/// `lobby_match_modes` 原本回一張 Laya 時代觀察來的對照表，**整組偏移一格**——
/// 銅之間四人東實際是 2，表上寫 1。送表上的值伺服器回 error 1306，而且
/// `liqi.json` 幫不上忙：`match_mode` 是 uint32，沒有對應的 enum 定義。
///
/// 真值其實一直在眼前：玩家點進任何一個場次畫面時，客戶端會持續送
/// `.lq.Lobby.fetchCurrentMatchInfo`，`mode_list` 就是那個畫面上所有入口的
/// match_mode。2026-08-01 在銅之間畫面攔到 `[2, 3, 17, 18]`，正好對應
/// 四人東／四人南／三人東／三人南。
///
/// **這裡只記錄觀察到什麼，不宣稱每個值對應哪個房間。** 房間名要靠使用者
/// 當下在哪個畫面來對應——猜錯房間比不知道更糟（會把人送進錯的段位場）。
@MainActor
final class ObservedMatchModes {

    /// `@MainActor` 隔離的 class 在 NakiTests host 釋放會 SIGABRT（見 CLAUDE.md
    /// 「專案結構的坑」）。目前測試都透過 `.shared` 碰它所以沒炸過，但哪天有人
    /// 直接建構一個，那一整批測試會從報告上**消失**而不是變紅。
    nonisolated deinit { }

    static let shared = ObservedMatchModes()

    /// 一次觀察：某個時間點客戶端輪詢了哪些 mode
    struct Observation {
        let modes: [Int]
        let seenAt: Date
        /// 看到幾次（同一組會累加而不是重複記錄）
        var count: Int
    }

    private(set) var observations: [Observation] = []

    private init() {}

    /// 清空（測試用）
    func reset() { observations.removeAll() }

    /// 記錄一次 `fetchCurrentMatchInfo` 的 mode_list
    func record(modes: [Int]) {
        guard !modes.isEmpty else { return }
        let sorted = modes.sorted()
        if let index = observations.firstIndex(where: { $0.modes == sorted }) {
            observations[index].count += 1
            return
        }
        observations.append(Observation(modes: sorted, seenAt: Date(), count: 1))
        systemLog("[match_mode] 觀察到新的一組: \(sorted)")
        // 只留最近 20 組，避免長時間執行後無限成長
        if observations.count > 20 { observations.removeFirst() }
    }

    /// 目前觀察到的所有 mode（去重排序）
    var knownModes: [Int] {
        Array(Set(observations.flatMap(\.modes))).sorted()
    }

    var dictionary: [String: Any] {
        [
            "observed": observations.map {
                ["modes": $0.modes,
                 "seenAt": ISO8601DateFormatter().string(from: $0.seenAt),
                 "count": $0.count]
            },
            "knownModes": knownModes,
            "note": observations.isEmpty
                ? "還沒觀察到。在遊戲裡點進段位場的任一場次畫面，客戶端就會開始輪詢 "
                  + "fetchCurrentMatchInfo，這裡才會有資料。"
                : "每一組是「某個場次畫面上的所有入口」。順序通常是 "
                  + "四人東／四人南／三人東／三人南，但 Naki 不宣稱這個對應——"
                  + "要確定哪個值對應哪個入口，請在該畫面觀察並自行核對。"
        ]
    }
}

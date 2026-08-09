//
//  ObservedMatchSids.swift
//  Naki
//
//  從遊戲自己的流量學 match_sid，因為 liqi.json 裡沒有任何訊息會產生它。
//

import Foundation

/// 觀察到的統一匹配 `match_sid` 值
///
/// 為什麼需要這個：
///
/// 雀魂的段位場入口已經從 `.lq.Lobby.matchGame`（`ReqJoinMatchQueue`：
/// `match_mode` 是 uint32）換成 `.lq.Lobby.startUnifiedMatch`
/// （`ReqStartUnifiedMatch`：`match_sid` 是 **string**）。2026-08-09 實測，
/// 對 `matchGame` 送 match_mode 1／2／3 一律回 error 1306，而同一個帳號在
/// 同一分鐘內由客戶端送出的 `startUnifiedMatch` 開局成功。
///
/// `match_sid` 拿不到靜態表：`docs/protocol/liqi.json` 只宣告
/// `ReqStartUnifiedMatch.match_sid`／`ReqCancelUnifiedMatch.match_sid` 兩處，
/// **沒有任何 response 或 config 訊息會產生這個字串**（那份 descriptor 是 Laya
/// 時代的遺留檔，見 CLAUDE.md）。而 `fetchCurrentMatchInfo` 的 `mode_list`
/// （`ObservedMatchModes` 記的那組 `[2, 3, 17, 18]`）是 **request** 欄位、是舊的
/// uint32 mode 命名空間，跟 `match_sid` 不是同一組東西——不能拿來當 sid。
///
/// 真值一樣在眼前：玩家自己點段位場入口時，客戶端就會送一次
/// `startUnifiedMatch`，`match_sid` 就在 field 1。這裡把它記下來，之後
/// `lobby_start_unified_match` 才有東西可送。
///
/// **這裡只記錄觀察到什麼，不宣稱哪個 sid 對應哪個場次。** 要對應房間名，
/// 得靠使用者當下點的是哪個入口——猜錯比不知道更糟（會把人送進錯的段位場）。
@MainActor
final class ObservedMatchSids {

    /// `@MainActor` 隔離的 class 在 NakiTests host 釋放會 SIGABRT
    /// （見 CLAUDE.md「專案結構的坑」），比照 `ObservedMatchModes` 補上。
    nonisolated deinit { }

    static let shared = ObservedMatchSids()

    /// 一次觀察：客戶端送出過的一組 `startUnifiedMatch` 參數
    ///
    /// `Codable` 是為了跨啟動保留：這份資料**只能靠使用者自己點一次段位場**取得，
    /// 不持久化的話每次重開 App 全自動都要先手動點一次才能用（2026-08-09 實測）。
    /// 內容是 sid 與版本字串，不含帳號或 token。
    struct Observation: Codable {
        let sid: String
        /// 同一次 request 的 `client_version_string`（field 2），可能是空字串
        let clientVersionString: String
        let seenAt: Date
        /// 看到幾次（同一組會累加而不是重複記錄）
        var count: Int
        /// 這個 sid 開出來的是不是三麻。`nil` = 還不知道（尚未打過）。
        ///
        /// **實證而不是查表**：`match_sid` 裡雖然有 mode id，但把「哪些 id 是三麻」
        /// 寫死成對照表正是 `ObservedMatchModes` 踩過的坑（舊表整組偏移一格）。
        /// 這裡改成送出後看**實際開出來的對局**是什麼（`start_game` 的 `is3P`），
        /// 打過一次就確定，沒打過就誠實地是 `nil`。
        var is3P: Bool?
    }

    private(set) var observations: [Observation] = []

    /// 剛送出、還在等 `start_game` 回填類型的 sid
    private var awaitingGameKind: String?

    /// 持久化 key。`awaitingGameKind` 刻意不存：它是「這次啟動剛送出、還沒開局」的
    /// 短暫狀態，跨啟動保留只會把下一局的人數標到上次那個 sid 上。
    nonisolated static let storageKey = "naki.observedMatchSids"

    private let defaults: UserDefaults

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        observations = Self.load(from: defaults)
    }

    #if DEBUG
        /// 測試用：不碰 `.standard`
        static func makeForTesting(defaults: UserDefaults) -> ObservedMatchSids {
            ObservedMatchSids(defaults: defaults)
        }
    #endif

    /// 清空（測試用）
    func reset() {
        observations.removeAll()
        awaitingGameKind = nil
        defaults.removeObject(forKey: Self.storageKey)
    }

    // MARK: - 持久化

    private static func load(from defaults: UserDefaults) -> [Observation] {
        guard let data = defaults.data(forKey: storageKey) else { return [] }
        // 解不開就當沒有：舊格式或壞掉的資料不該讓 App 帶著錯的 sid 去排隊
        return (try? JSONDecoder().decode([Observation].self, from: data)) ?? []
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(observations) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    /// 記錄一次 `startUnifiedMatch` 的參數
    func record(sid: String, clientVersionString: String) {
        guard !sid.isEmpty else { return }
        // 不論是新的還是看過的，都要等這次開出來的對局來確認類型
        awaitingGameKind = sid

        if let index = observations.firstIndex(where: {
            $0.sid == sid && $0.clientVersionString == clientVersionString
        }) {
            observations[index].count += 1
            save()
            return
        }
        observations.append(Observation(sid: sid,
                                        clientVersionString: clientVersionString,
                                        seenAt: Date(),
                                        count: 1,
                                        is3P: nil))
        systemLog("[match_sid] 觀察到新的一組: sid=\(sid) ver=\(clientVersionString)")
        // 只留最近 20 組，避免長時間執行後無限成長
        if observations.count > 20 { observations.removeFirst() }
        save()
    }

    /// 對局開始：把類型回填到剛送出的那個 sid。
    ///
    /// 只回填「上一次 `startUnifiedMatch` 之後的第一個 `start_game`」——友人房、
    /// 重連 replay 也會發 `start_game`，沒有待回填的 sid 時直接忽略，
    /// 免得把友人房的三麻標記到某個段位場 sid 上。
    func gameDidStart(is3P: Bool) {
        guard let sid = awaitingGameKind else { return }
        awaitingGameKind = nil

        var changed = false
        for index in observations.indices where observations[index].sid == sid {
            if observations[index].is3P != is3P {
                observations[index].is3P = is3P
                changed = true
            }
        }
        if changed {
            systemLog("[match_sid] sid=\(sid) 確認為\(is3P ? "三麻" : "四麻")")
            save()
        }
    }

    /// 目前觀察到的所有 sid（去重排序）
    var knownSids: [String] {
        Array(Set(observations.map(\.sid))).sorted()
    }

    /// 最近一次觀察到的組合，供「重開上一種場次」直接取用
    var latest: Observation? {
        observations.max(by: { $0.seenAt < $1.seenAt })
    }

    /// 最近一次「已確認是這個人數」的組合。
    ///
    /// `is3P == nil` 的不算：那是還沒打過、類型未知的 sid，拿它去續局等於猜。
    /// 全自動選了三麻卻排進四麻（或反過來）比不排隊更糟。
    func latest(sanma: Bool) -> Observation? {
        observations
            .filter { $0.is3P == sanma }
            .max(by: { $0.seenAt < $1.seenAt })
    }

    var dictionary: [String: Any] {
        var result: [String: Any] = [
            "observed": observations.map {
                var entry: [String: Any] = [
                    "match_sid": $0.sid,
                    "client_version_string": $0.clientVersionString,
                    "seenAt": ISO8601DateFormatter().string(from: $0.seenAt),
                    "count": $0.count]
                // nil 就不放這個 key：`false` 會被讀成「已確認是四麻」
                if let is3P = $0.is3P { entry["is3P"] = is3P }
                return entry
            },
            "knownSids": knownSids,
            "source": "遊戲自己送的 .lq.Lobby.startUnifiedMatch（match_sid=1, client_version_string=2）",
            "note": observations.isEmpty
                ? "還沒觀察到。在遊戲裡自己點一次段位場的場次入口，客戶端就會送 "
                  + "startUnifiedMatch，這裡才會有資料。match_sid 沒有靜態表可查——"
                  + "liqi.json 裡沒有任何訊息會產生它。"
                : "每一組是使用者實際點過的一個場次入口。Naki 不宣稱 sid 對應哪個房間，"
                  + "要對應請回想當下點的是哪個入口。"
        ]
        if let latest {
            result["latest"] = ["match_sid": latest.sid,
                                "client_version_string": latest.clientVersionString,
                                "seenAt": ISO8601DateFormatter().string(from: latest.seenAt)]
        }
        return result
    }
}

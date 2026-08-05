//
//  KyokuStreamAccumulator.swift
//  Naki
//
//  雲端推論的「每局視窗」事件流。
//
//  Akagi `/v3/react` 是 stateless：每個決策點上傳「本局至今」的 mjai 事件批次，
//  決策點是最後一個元素。伺服器有 512 事件上限，所以視窗以局為界——
//  `start_kyoku` 清掉上一局的尾巴，但**保留開頭的 `start_game` 當 `events[0]`**
//  （API 硬性要求）。API 關閉時也持續累積，局中途開啟才能立刻上傳本局至今。
//
//  Naki 的 MJAI 事件天生已 censor（bridge 只填自家 tehais、別家 tsumo 為 "?"、
//  reach 本來就是裸的），這裡只負責視窗、內部欄位剝除與三麻補位。
//

import Foundation

/// 雲端推論請求用的 per-kyoku 事件視窗。
///
/// 值型別、無副作用：`accumulate` 只維護視窗，`apiEvents` 才做 API 塑形。
/// 塑形是純函數（`static`），可直接單測而不必組出整個 controller。
struct KyokuStreamAccumulator {

    /// 本局視窗（原始 Naki 事件，含內部欄位；塑形延後到 `apiEvents`）
    private(set) var events: [[String: Any]] = []

    /// 依事件維護視窗：`start_game` 整個重來；`start_kyoku` 清掉上一局
    /// 但保留開頭的 `start_game`；其餘照序附加。
    mutating func accumulate(_ event: [String: Any]) {
        switch event["type"] as? String {
        case "start_game":
            events = [event]
        case "start_kyoku":
            let startGame = events.first.flatMap {
                ($0["type"] as? String) == "start_game" ? $0 : nil
            }
            events = startGame.map { [$0] } ?? []
            events.append(event)
        default:
            events.append(event)
        }
    }

    mutating func reset() {
        events = []
    }

    /// 是否已具備最低可上傳形狀（`start_game` 開頭＋至少一個 `start_kyoku`）。
    /// 局中途才開啟 App（沒收到 start_game）時寧可不打 API，也不上傳殘缺流。
    var hasUploadableWindow: Bool {
        guard (events.first?["type"] as? String) == "start_game" else { return false }
        return events.dropFirst().contains { ($0["type"] as? String) == "start_kyoku" }
    }

    /// 把視窗塑形成 API 期待的事件批次。
    func apiEvents(is3P: Bool) -> [[String: Any]] {
        events.map { Self.apiEvent($0, is3P: is3P) }
    }

    /// 單一事件的 API 塑形：
    /// - 剝掉 Naki 內部欄位（oplist provenance、`start_game` 的 `id`/`is3P`）
    /// - `start_game` 只留 `type` + `names`（與 Akagi `to_api_event` 一致）
    /// - `reach` 防禦性只留 `type` + `actor`（伺服器要裸 reach）
    /// - 三麻把 `names`/`scores`/`tehais` 補到長度 4（幽靈第四家：空名、0 分、13 張 "?"）
    static func apiEvent(_ event: [String: Any], is3P: Bool) -> [String: Any] {
        switch event["type"] as? String {
        case "start_game":
            var names = event["names"] as? [String] ?? []
            if is3P {
                while names.count < 4 { names.append("") }
            }
            return ["type": "start_game", "names": names]

        case "start_kyoku":
            var shaped = event
            shaped.removeValue(forKey: MJAIEventKey.oplistSequence)
            if is3P {
                if var scores = shaped["scores"] as? [Int] {
                    while scores.count < 4 { scores.append(0) }
                    shaped["scores"] = scores
                }
                if var tehais = shaped["tehais"] as? [[String]] {
                    while tehais.count < 4 {
                        tehais.append([String](repeating: "?", count: 13))
                    }
                    shaped["tehais"] = tehais
                }
            }
            return shaped

        case "reach":
            var shaped: [String: Any] = ["type": "reach"]
            if let actor = event["actor"] { shaped["actor"] = actor }
            return shaped

        case "nukidora":
            // 拔北：Naki bridge 的事件名是 `nukidora`（`MajsoulBridge` ActionBaBei），
            // 伺服器的 mjai schema 是 `kita`——不轉譯的話三麻事件流會 desync
            var shaped: [String: Any] = ["type": "kita", "pai": "N"]
            if let actor = event["actor"] { shaped["actor"] = actor }
            return shaped

        default:
            var shaped = event
            shaped.removeValue(forKey: MJAIEventKey.oplistSequence)
            return shaped
        }
    }
}

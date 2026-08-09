//
//  CloudBot.swift
//  Naki
//
//  雲端推論裝飾器（docs/cloud-inference-plan.md）。
//
//  雲端不是平行引擎，是包在本地引擎外面的一層：本地引擎照餵每一個事件，
//  同時扮演合法動作閘門（本地回 nil ＝ 非決策點，連 API 都不打——省
//  round-trip 也省額度）、失敗 fallback 與立直捨牌後備。與 Akagi v3
//  `native.rs` 的 `remote_decision` 同構，但站在 `MahjongBot` 抽象上：
//  `local` 是 `any MahjongBot`，單測可以用 stub 引擎驗整條 overlay 流程。
//
//  必守語意（出處見 docs/reference/akagi-inference-api.md）：
//  - 每個決策點重讀設定並 reconcile（修 key、換模型局中即生效，變更 reset 斷路器）
//  - 斷路器 5s→120s：掛掉的伺服器一個視窗只付一次慢回合
//  - 立直兩段式：伺服器回裸 reach，附上 reach 再問一次拿捨牌；
//    第二段失敗＝整個決策退回本地（不做半雲半本地拼裝，見 decisions D3）。
//    第二段 429＝burst rate-limit（兩段是毫秒內連發）：短暫等待重試一次、
//    不開斷路器——rate limit 的伺服器是可達的（Akagi #227）
//  - 強制手（完整合法集單元素，最常見＝立直後摸切）本地回答、不打 API、
//    不動斷路器——伺服器只可能回同一手（Akagi #227/#228）
//  - null reaction＝事件流不同步：打本地決策並 warn，絕不默默 pass 掉真回合
//  - 重連重放歷史事件期間抑制雲端呼叫（`suppressCloud(forNextEvents:)`）——
//    歷史決策早就做完了，重放時打 API 是純浪費（N 個決策 × 2s 逾時預算＋額度）
//

import Foundation

/// 把 `local` 引擎的決策點代理給 Akagi 推論伺服器的裝飾器。
@MainActor
final class CloudBot: MahjongBot {

    /// 本地引擎：閘門＋fallback，永遠先於雲端收到每一個事件。
    ///
    /// **三麻時為 nil**（2026-08-05 使用者定案：本地只有四麻模型，推三麻
    /// 結構上無效——連啟動都不啟動）。nil 時決策點改由**伺服器 oplist 驅動**
    /// （事件上的 `MJAIEventKey.oplistSequence` 標記，每批授權恰問一次雲端），
    /// 雲端失敗＝這一手沒有推薦（誠實留空），不會有本地的無效輸出頂上。
    private let local: (any MahjongBot)?

    private let playerId: UInt8
    private let is3P: Bool

    /// 每個決策點重讀一次設定（由 `NakiRuntime` 注入 `SettingsStore.cloudConfig`）
    private let configProvider: () -> CloudInferenceConfig?

    /// 伺服器當下是否有待處理的授權（oplist）。
    ///
    /// 雲端-only 模式（三麻，`local == nil`）的決策點守門：事件帶了
    /// oplistSequence 但授權已被消化（autopass 競態）時不再問雲端。
    /// 預設 `{ true }`＝不過濾（測試／4p 用不到）。
    private let serverAuthorization: () -> Bool

    /// 供測試注入 `URLProtocol` stub；正式路徑 ephemeral（牌局資料不落磁碟 cache）
    private let clientConfiguration: URLSessionConfiguration

    /// 本局的 per-kyoku 事件視窗（API 關著也累積，局中開啟能立刻上傳）
    private var kyokuStream = KyokuStreamAccumulator()

    /// 雲端 client（hold 一份重用；只在 URL/key 變更時重建）
    private var client: AkagiApiClient?

    /// client 目前對應的設定快照（變更偵測）
    private var appliedConfig: CloudInferenceConfig?

    /// 建不出 client 的設定 tombstone：同組壞設定只警告一次
    private var tombstone: CloudInferenceConfig?

    /// 指數退避斷路器（5s→120s）
    private var breaker = CloudBreaker()

    /// 還剩幾個「重放中」的歷史事件要跳過雲端呼叫
    private var suppressRemaining = 0

    /// 雲端-only 模式：已問過雲端的 oplist sequence（每批授權恰問一次，
    /// 避免同一授權 pending 期間每個事件都觸發一次 API）
    private var lastConsultedOplistSequence: UInt64?

    /// 雲端啟用期間連續以非雲端來源結束的決策數（fallback 可視化）
    private(set) var fallbackStreak = 0

    init(local: (any MahjongBot)?, playerId: UInt8, is3P: Bool,
         configProvider: @escaping () -> CloudInferenceConfig?,
         serverAuthorization: @escaping () -> Bool = { true },
         clientConfiguration: URLSessionConfiguration = .ephemeral) {
        self.local = local
        self.playerId = playerId
        self.is3P = is3P
        self.configProvider = configProvider
        self.serverAuthorization = serverAuthorization
        self.clientConfiguration = clientConfiguration
    }

    /// `@MainActor` class 在 NakiTests host 釋放會 SIGABRT（見 CLAUDE.md「專案結構的坑」）
    nonisolated deinit {}

    var identity: BotIdentity {
        let base = local?.identity
            ?? BotIdentity(name: "cloud-only", displayName: "雲端推論",
                           supports3P: false, isLocal: false)
        guard let cfg = appliedConfig else { return base }
        return BotIdentity(
            name: local == nil ? "cloud-only" : "cloud+\(base.name)",
            displayName: local == nil ? "雲端推論" : "\(base.displayName) ＋ 雲端",
            // 雲端只有在「啟用＋選了 3p 模型」時才如實支援三麻
            supports3P: !cfg.model3P.trimmingCharacters(in: .whitespaces).isEmpty,
            isLocal: false)
    }

    var cloudHost: String? { client?.host }

    /// 雲端已設定但斷路器不健康或退避中——決策正在 rollback
    var cloudDegraded: Bool {
        client != nil && (!breaker.healthy || !breaker.allows(now: Date()))
    }

    var cloudFallbackStreak: Int { fallbackStreak }

    /// 重連重放歷史事件前呼叫：接下來 `count` 個事件只走本地，不打 API。
    func suppressCloud(forNextEvents count: Int) {
        guard count > 0 else { return }
        suppressRemaining += count
        eventLog("[Bot] ☁️ 重連重放 \(count) 個歷史事件期間暫停雲端呼叫"
               + "（歷史決策不重問伺服器）")
    }

    func reset() {
        kyokuStream.reset()
        suppressRemaining = 0
        lastConsultedOplistSequence = nil
        fallbackStreak = 0
        local?.reset()
    }

    // MARK: - React

    func react(events: [[String: Any]]) async throws -> BotReaction? {
        // 視窗累積在本地推論之前：塑形延後到上傳時
        for event in events {
            kyokuStream.accumulate(event)
        }

        // 本地引擎照餵（nil＝三麻雲端-only，見 `local` 註解）
        let localReaction = try await local?.react(events: events)

        // 重放抑制：照餵本地（重建狀態），跳過雲端
        if suppressRemaining > 0 {
            suppressRemaining = max(0, suppressRemaining - events.count)
            return localReaction
        }

        guard local != nil else {
            // ── 雲端-only（三麻）：決策點由伺服器授權驅動 ──
            // 事件帶 oplistSequence ＝ 這個事件伴隨一批新授權抵達；
            // 每批恰問一次（同授權 pending 期間的後續事件不重複觸發）。
            guard let seq = events.compactMap({ $0[MJAIEventKey.oplistSequence] as? UInt64 }).last,
                  seq != lastConsultedOplistSequence,
                  serverAuthorization() else {
                return nil
            }
            lastConsultedOplistSequence = seq
            // 雲端失敗／null reaction：這一手誠實地沒有推薦——沒有本地的
            // 無效輸出頂上（三麻閘門本來也不會送非雲端決策），畫面保持現狀
            if let cloud = await cloudOverride() {
                fallbackStreak = 0
                return cloud
            }
            fallbackStreak += 1
            return nil
        }

        // ── 4p：本地閘門——不是決策點連 API 都不打 ──
        guard let localReaction else { return nil }

        // 強制手：答案完全確定，伺服器只可能回同一手。本地回答、不花額度；
        // 斷路器與 fallbackStreak 都不動——這不是 fallback（Akagi #227/#228）
        if localReaction.forced { return localReaction }

        if let cloud = await cloudOverride() {
            fallbackStreak = 0
            return cloud
        }
        // 雲端有設定卻沒能服務這一手（失敗/退避/null）＝ rollback 中；
        // 未設定（client nil）不算 fallback，維持 0
        if client != nil { fallbackStreak += 1 }
        return localReaction
    }

    // MARK: - 雲端代理

    /// 決策點的雲端代理。成功回覆蓋用的 `BotReaction`；任何失敗回 nil
    /// （呼叫端沿用本地決策——對局永不停擺）。
    private func cloudOverride() async -> BotReaction? {
        reconcileSession()
        guard let client, let cfg = appliedConfig else { return nil }
        guard breaker.allows(now: Date()) else { return nil }
        // 局中途才啟動（視窗缺 start_game/start_kyoku）寧可不上傳殘缺流
        guard kyokuStream.hasUploadableWindow else { return nil }

        let events = kyokuStream.apiEvents(is3P: is3P)
        let model = cfg.model(is3P: is3P)

        let response: CloudReactResponse
        do {
            response = try await client.react(model: model.isEmpty ? nil : model,
                                              playerId: Int(playerId), events: events)
        } catch {
            let backoff = breaker.recordFailure(now: Date())
            recordHealth(ok: false, detail: error.localizedDescription)
            eventLog("[Bot] ☁️ 雲端推論失敗（\(error.localizedDescription)），"
                   + "\(local == nil ? "本手無推薦（三麻不用本地）" : "改用本地模型")，"
                   + "\(Int(backoff))s 內不再嘗試")
            return nil
        }
        breaker.recordSuccess()
        recordHealth(ok: true, detail: nil)

        guard let reaction = response.reaction else {
            // 伺服器認為無合法動作、本地卻有決策 ⇒ 事件流不同步。打本地決策，
            // 絕不默默 pass 掉真回合。（HTTP 有來回＝伺服器可達，不算斷路器失敗。）
            // 上傳尾巴一起落 log：真脫節時這是定位「哪種事件讓伺服器分岔」
            // 的直接證據（2026-08-05 加，幻覺窗口已被上面過濾，剩下的 null
            // 每一筆都值得查）。
            let tail = events.suffix(6).map { event in
                let type = event["type"] as? String ?? "?"
                let actor = (event["actor"] as? Int).map { "@\($0)" } ?? ""
                return type + actor
            }.joined(separator: " ")
            eventLog("[Bot] ☁️ 雲端回 null reaction 但本地有決策（事件流可能不同步），"
                   + "改用本地；上傳尾巴: \(tail)")
            return nil
        }

        // 立直兩段式：伺服器回裸 reach（捨牌是第二個決策），附上 reach 再問一次。
        // 第二段失敗＝伺服器不穩：整個決策退回本地（decisions D3）。
        var reachDiscard: String?
        if (reaction["type"] as? String) == "reach" {
            reachDiscard = await resolveReachDiscard(client: client, model: model,
                                                     events: events)
            guard reachDiscard != nil else {
                eventLog("[Bot] ☁️ 立直第二段呼叫失敗，放棄雲端反應，改用本地決策")
                return nil
            }
        }

        guard let recommendations = CloudDecisionMapper.recommendations(
            reaction: reaction, candidates: response.candidates,
            reachDiscard: reachDiscard), !recommendations.isEmpty else {
            eventLog("[Bot] ☁️ 無法映射雲端反應"
                   + "（type=\((reaction["type"] as? String) ?? "?")），改用本地")
            return nil
        }

        let source = "cloud:\(response.model ?? (model.isEmpty ? "default" : model))"
        let summary = recommendations.prefix(6)
            .map { "\($0.actionType.rawValue):\($0.displayTile)@\($0.percentageString)" }
            .joined(separator: " ")
        eventLog("[Bot] ☁️ 雲端決策生效（\(source)）: "
               + "\(recommendations.count) items [\(summary)]")

        // 防禦性把 actor 蓋成自家座位（伺服器應已設對）
        var action = reaction
        if action["actor"] != nil || (action["type"] as? String) != "none" {
            action["actor"] = Int(playerId)
        }
        return BotReaction(action: action, recommendations: recommendations,
                           source: source)
    }

    /// 立直第二段：把裸 reach 附到視窗尾再問一次，取回捨牌。
    ///
    /// 兩段是毫秒內連發，第二段吃到 429 是 burst rate-limit 而非伺服器掛
    ///（Akagi #227）：短暫等待重試一次；再 429 仍不開斷路器——rate limit 的
    /// 伺服器是可達的，開 5s→120s 退避會把接下來幾手一起賠進去
    ///（三麻雲端-only 時＝接下來幾手全部無推薦）。
    private func resolveReachDiscard(client: AkagiApiClient, model: String,
                                     events: [[String: Any]]) async -> String? {
        var followUp = events
        followUp.append(["type": "reach", "actor": Int(playerId)])
        var retriedAfterRateLimit = false
        while true {
            do {
                let response = try await client.react(model: model.isEmpty ? nil : model,
                                                      playerId: Int(playerId), events: followUp)
                if let reaction = response.reaction,
                   (reaction["type"] as? String) == "dahai",
                   let pai = reaction["pai"] as? String {
                    return pai
                }
                return nil
            } catch CloudAPIError.http(429, _, let retryAfter) {
                // 二連 429：這一手退回本地（D3 不變），但斷路器不開
                guard !retriedAfterRateLimit else { return nil }
                retriedAfterRateLimit = true
                // Retry-After 解不出（缺席或 HTTP-date 格式）用 0.4s；
                // 上限 1s——決策逾時預算才 2s，等更久不如退回本地
                let seconds = min(retryAfter.flatMap(Double.init) ?? 0.4, 1.0)
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            } catch {
                // 宣告那次成功、跟進失敗＝伺服器不穩：開斷路器，下個決策不再付一次逾時
                breaker.recordFailure(now: Date())
                return nil
            }
        }
    }

    /// 每決策 reconcile 設定與 client：URL/key 變更重建、關閉即拆除，
    /// 任何變更 reset 斷路器（使用者改設定＝明確的「現在再試一次」）。
    private func reconcileSession() {
        let current = configProvider()
        guard let cfg = current, cfg.isActive else {
            if client != nil {
                client = nil
                appliedConfig = nil
                tombstone = nil
                breaker.reset()
                eventLog("[Bot] ☁️ 雲端推論關閉，使用內建本地模型")
            }
            return
        }
        if cfg == appliedConfig { return }
        if cfg == tombstone { return }   // 同組壞設定只警告一次

        guard let built = AkagiApiClient(baseURL: cfg.baseURL, key: cfg.apiKey,
                                         configuration: clientConfiguration) else {
            client = nil
            appliedConfig = nil
            tombstone = cfg
            breaker.reset()
            eventLog("[Bot] ⚠️ 雲端推論設定無效（URL 無法解析），維持本地模型")
            return
        }
        let wasOff = client == nil
        client = built
        appliedConfig = cfg
        tombstone = nil
        breaker.reset()
        let model = cfg.model(is3P: is3P)
        eventLog("[Bot] ☁️ 雲端推論\(wasOff ? "已啟用" : "設定已更新")："
               + "伺服器 \(built.host)，模型 \(model.isEmpty ? "伺服器預設" : model)，"
               + "key •••\(cfg.keyLast4)")
    }

    /// 只在健康狀態**轉變**時記 log：持續掛著的伺服器不會每一手都刷一行。
    private func recordHealth(ok: Bool, detail: String?) {
        guard ok != breaker.healthy else { return }
        breaker.healthy = ok
        if ok {
            eventLog("[Bot] ☁️ 雲端推論恢復，已回到線上模型")
        } else {
            eventLog("[Bot] ⚠️ 雲端推論不可用，退回內建本地模型"
                   + (detail.map { "（\($0)）" } ?? ""))
        }
    }
}

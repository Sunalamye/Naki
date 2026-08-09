//
//  AutoRematchEngine.swift
//  Naki
//
//  「全自動」模式的最後一段：對局結束後自動排下一場。
//
//  責任邊界：這裡**只管重新排隊**。局內怎麼打是 `AutoPlayEngine`，
//  局間怎麼進下一局是它的 `confirmNewRound`；本型別處理的是整場結束之後。
//
//      end_game ──▶ 等結算畫面 ──▶ lobby 探針 ──▶ startUnifiedMatch ──▶ 下一場
//
//  為什麼是獨立型別而不是塞進 `AutoPlayEngine`：後者是一個 tick 迴圈驅動的狀態機，
//  它的每一拍都在回答「這一手要不要送」。續局是一次性的、跨對局的事件，混進去會讓
//  那個迴圈多出一種與 oplist 無關的狀態。
//

import Foundation

/// 對局結束後自動重新排隊（`AutoPlayMode.fullAuto`）
@MainActor
final class AutoRematchEngine {

    /// `@MainActor` class 在 NakiTests host 釋放會 SIGABRT（見 CLAUDE.md「專案結構的坑」）
    nonisolated deinit {}

    /// 每次判斷都重取的執行環境（模式可能在等待期間被使用者改掉）
    nonisolated struct Context {
        let mode: AutoPlayMode
        /// 頁面／送出通道是否就緒
        let isReady: Bool
        /// 全自動要排三麻還是四麻（使用者在切到全自動時選的；預設四麻）
        let prefersSanma: Bool
        /// 雲端推論是否啟用。三麻**只有**雲端路徑（見 CLAUDE.md），
        /// 沒有雲端就不該自動排三麻——排得進去但一手都不會打。
        let cloudInferenceActive: Bool
        /// 段位允許的房間裡要挑最低還是最高
        let roomPreference: RoomPreference
        /// 東風戰（true）還是半莊。預設東風：一場快得多，續局的意義才明顯。
        let prefersEast: Bool

        init(mode: AutoPlayMode,
             isReady: Bool,
             prefersSanma: Bool = false,
             cloudInferenceActive: Bool = false,
             roomPreference: RoomPreference = .lowest,
             prefersEast: Bool = true) {
            self.mode = mode
            self.isReady = isReady
            self.prefersSanma = prefersSanma
            self.cloudInferenceActive = cloudInferenceActive
            self.roomPreference = roomPreference
            self.prefersEast = prefersEast
        }
    }

    /// 一次排隊嘗試的結論（測試斷言看得到中間發生什麼，不能只有「有沒有送」）
    nonisolated enum Outcome: Equatable {
        /// 模式不是全自動
        case notFullAuto
        /// 還沒有「已確認是這個人數」的 match_sid——**不猜**，見 `ObservedMatchSids`
        case noObservedSid(sanma: Bool)
        /// 選了三麻但雲端推論沒開：排得進去卻一手都不會打
        case sanmaWithoutCloud
        /// 頁面／送出通道沒就緒
        case notReady
        /// 大廳 session 探針一直不通
        case lobbyNotReady
        /// 等待期間模式被改掉或被取消
        case cancelled
        /// 伺服器接受了排隊請求
        case queued(sid: String, attempts: Int)
        /// 送了但伺服器都不接受
        case rejected(attempts: Int)
    }

    // MARK: - 依賴（全部可注入，讓 run() 可以直接單測）

    private let context: () -> Context
    /// 目前所有觀察到的 sid（決策交給 `RematchTargetResolver`）
    private let observations: () -> [ObservedMatchSids.Observation]
    /// 帳號段位 id（`sanma` = 要三麻的那個段位）；取不到回 nil
    private let accountLevel: (Bool) async -> Int?
    /// 送出 startUnifiedMatch；回傳 `serverAccepted`
    private let startMatch: (String, String) async -> Bool
    /// 大廳 session 探針（剛回大廳時 socket 可能還沒完成登入）
    private let lobbyProbe: () async -> Bool
    private let log: (String) -> Void

    // MARK: - 時間常數

    /// 結算畫面 → 回到大廳的緩衝。段位場結算會自己跑完，不需要點確認。
    private let settleDelay: Duration
    private let probeInterval: Duration
    private let maxProbes: Int
    private let retryInterval: Duration
    private let maxAttempts: Int

    private var task: Task<Void, Never>?

    init(context: @escaping () -> Context,
         observations: @escaping () -> [ObservedMatchSids.Observation],
         accountLevel: @escaping (Bool) async -> Int?,
         startMatch: @escaping (String, String) async -> Bool,
         lobbyProbe: @escaping () async -> Bool,
         log: @escaping (String) -> Void,
         settleDelay: Duration = .seconds(45),
         probeInterval: Duration = .seconds(3),
         maxProbes: Int = 20,
         retryInterval: Duration = .seconds(10),
         maxAttempts: Int = 3) {
        self.context = context
        self.observations = observations
        self.accountLevel = accountLevel
        self.startMatch = startMatch
        self.lobbyProbe = lobbyProbe
        self.log = log
        self.settleDelay = settleDelay
        self.probeInterval = probeInterval
        self.maxProbes = maxProbes
        self.retryInterval = retryInterval
        self.maxAttempts = maxAttempts
    }

    // MARK: - 生命週期

    /// 整場對局結束（`end_game`）。全自動模式下排一次續局。
    func gameDidEnd() {
        guard context().mode.autoRematch else { return }
        task?.cancel()
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.run()
        }
    }

    /// 立刻排一場，不等結算緩衝。
    ///
    /// 在**大廳**切到全自動時沒有 `end_game` 可等——只靠 `gameDidEnd` 的話，
    /// 使用者按下「開始」會什麼都不發生，得先自己手動開一局才進得了循環。
    ///
    /// 對局中呼叫也安全：不自己判斷「在不在對局中」（`GameStore.inGame` 對局結束後
    /// 不會歸位，AUDIT §16.4，拿它判斷會卡死），交給伺服器拒絕，
    /// 而這一局的 `end_game` 仍會照常觸發續局。
    func startNow() {
        guard context().mode.autoRematch else { return }
        task?.cancel()
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.run(skipSettle: true)
        }
    }

    /// 模式被改掉、頁面重載或 App 收攤時取消待排的續局。
    ///
    /// 不取消的話，使用者切回「推薦」之後 45 秒，帳號還是會被排進隊列。
    func cancel() {
        guard task != nil else { return }
        task?.cancel()
        task = nil
    }

    // MARK: - 主流程

    /// 完整的續局流程。回傳結論供測試斷言。
    ///
    /// - Parameter skipSettle: 跳過結算緩衝。只有 `startNow()`（在大廳按下「開始」）
    ///   會用——那時畫面本來就在大廳，沒有結算動畫要等。
    @discardableResult
    func run(skipSettle: Bool = false) async -> Outcome {
        guard context().mode.autoRematch else { return .notFullAuto }

        if skipSettle {
            log("[自動續局] 立刻排一場")
        } else {
            log("[自動續局] 對局結束，\(settleDelay.wholeSeconds) 秒後排下一場")
            try? await Task.sleep(for: settleDelay)
            if Task.isCancelled { return .cancelled }
        }

        // 等待期間使用者可能改了模式——每一步都重新確認，不靠進來時那一次判斷
        guard context().mode.autoRematch else {
            log("[自動續局] 模式已變更，取消續局")
            return .cancelled
        }
        guard context().isReady else {
            log("[自動續局] 送出通道未就緒，放棄續局")
            return .notReady
        }

        let sanma = context().prefersSanma
        let kind = sanma ? "三麻" : "四麻"

        // 三麻只有雲端路徑（bundled 模型的 obs 1012×34 對三麻結構性無效）。
        // 沒有雲端還自動排三麻＝把帳號送進一場自己不會出手的對局。
        if sanma && !context().cloudInferenceActive {
            log("[自動續局] 選了三麻但雲端推論未啟用，不排隊——"
                + "三麻只有雲端路徑，排進去也不會出手。")
            return .sanmaWithoutCloud
        }

        // 段位決定能進哪些房間；取不到就讓 resolver 退回「沿用上次那個房間」
        let level = await accountLevel(sanma)

        // fail-closed：一次都沒觀察過就什麼都不送——沒有 group 可用，sid 猜不出來
        //（見 ObservedMatchSids），亂送的後果是排進錯的場次。
        guard let target = RematchTargetResolver.resolve(
            level: level,
            sanma: sanma,
            east: context().prefersEast,
            preference: context().roomPreference,
            observations: observations()) else {
            log("[自動續局] 還沒有可用的\(kind) match_sid，不排隊。"
                + "請先自己點一次\(kind)的場次入口打一場，Naki 會記下來。")
            return .noObservedSid(sanma: sanma)
        }

        // 推導出來的候選要講明白，不要讓推論看起來像事實
        let room: String = target.entry?.displayName ?? target.sid
        let levelText: String = level.map(String.init) ?? "未知"
        let prefText: String = context().roomPreference.label
        let verifyNote: String = target.verified ? "" : "（由表推導，尚未驗證）"
        log("[自動續局] 目標：\(room)（段位 \(levelText)，偏好\(prefText)）"
            + " sid=\(target.sid)\(verifyNote)")
        let observed = target

        var lobbyReady = false
        for _ in 0..<maxProbes {
            if Task.isCancelled { return .cancelled }
            if await lobbyProbe() { lobbyReady = true; break }
            try? await Task.sleep(for: probeInterval)
        }
        guard lobbyReady else {
            log("[自動續局] 大廳連線探針一直不通，放棄續局")
            return .lobbyNotReady
        }

        for attempt in 1...maxAttempts {
            if Task.isCancelled { return .cancelled }
            guard context().mode.autoRematch else {
                log("[自動續局] 模式已變更，取消續局")
                return .cancelled
            }

            if await startMatch(observed.sid, observed.clientVersionString) {
                log("[自動續局] ✅ 已排入\(kind) match_sid=\(observed.sid)（第 \(attempt) 次嘗試）")
                return .queued(sid: observed.sid, attempts: attempt)
            }
            log("[自動續局] 第 \(attempt)/\(maxAttempts) 次送出未被伺服器接受")
            if attempt < maxAttempts {
                try? await Task.sleep(for: retryInterval)
            }
        }

        // 不無限重試：連續被拒通常代表 sid 過期或帳號狀態不對，
        // 一直送只會把錯誤重複到看不見。停手並留下 log。
        log("[自動續局] ❌ \(maxAttempts) 次都未被接受，停止續局")
        return .rejected(attempts: maxAttempts)
    }
}

private extension Duration {
    /// 只給 log 用的秒數
    var wholeSeconds: Int { Int(components.seconds) }
}

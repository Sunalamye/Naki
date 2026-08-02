//
//  AutoPlayEngine.swift
//  Naki
//
//  自動打牌的狀態機：「什麼時候動、等多久、送幾次」全部收在這一個型別裡。
//
//  由來（p3-2）：這段邏輯原本約 260 行散在 `WebViewModel`，混用四種併發原語——
//
//      Timer.scheduledTimer(1.0)          1 秒輪詢
//      DispatchQueue.main.asyncAfter      動作延遲
//      Task { @MainActor }                跳回主執行緒
//      async 遞迴（深度 15）               重試
//
//  三個實際後果：
//
//  1. **不變量只靠註解維繫。** `currentExecutionId` 是一個裸 `UUID?`，
//     「每一條結束路徑都要記得呼叫 `clearExecutionIfCurrent`」寫在註解裡；
//     漏掉任何一條，殘留的 id 會讓 1 秒輪詢（以 `currentExecutionId == nil` 為前提）
//     **永久停用**，自動打牌黏著卡死。原檔有 8 個呼叫點，全靠人工檢查。
//  2. **TOCTOU。** 閘門在 T0 讀一次 `store.pending` 做決策，重試框架在 T1
//     （延遲 1–3 秒之後）**重新讀一次**再交給 resolver。中間換批的話，
//     「因為 A 批而觸發」的動作會落在 B 批上；resolver 的 `isStillValid` 補救不到，
//     因為它比對的是自己剛讀的那一份。
//  3. **兩個觸發源（1 秒輪詢／推薦更新）共用去抖狀態**，時序耦合、無從單測。
//
//  現在的形狀：
//
//      單一 Task 迴圈 ── tick ──▶ AutoPlayGate ──▶（延遲）──▶ resolver ──▶ executor
//            ▲                      同一份 snapshot 一路往下傳
//            └── wake()：推薦更新／模式切換／手動觸發提早叫醒
//
//  - `Task.sleep` 同時擔任輪詢間隔、動作延遲與重試間隔，沒有 Timer 也沒有 asyncAfter。
//  - 重試是 `while` 迴圈，不是遞迴。
//  - 執行狀態是 enum（`idle`／`waiting`／`executing`），而且只能經由 `occupy(...)`
//    這個**作用域**進出：`defer { state = .idle }` 讓「一定歸零」變成語言保證，
//    不再是註解要求（`clearExecutionIfCurrent` 因此不存在）。
//  - 迴圈本身就是互斥：同一時間只有一輪在跑，所以閘門的 `hasActionInFlight`
//    在正常情況下恆為 false（仍然照傳，讓輸入保持完整）。
//
//  可單測是設計條件而不是副產品：`WebViewModel` 要有 WebPage／DebugServer／Timer，
//  測試裡建不出來。這裡把 oplist 儲存體、送出器、上下文、兩條 log 通道與所有時間常數
//  都做成參數，`runCycle()` 是一個可以直接呼叫並回傳完整軌跡的單位——
//  p0-5 的 fail-safe fixture 因此測得到**產品程式碼**，不再是 harness 自己的語意。
//

import Foundation

// MARK: - 一輪的結果

/// 一輪自動打牌的結論
///
/// 刻意 `nonisolated`：app target 開了 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`，
/// 不標的話合成的 `==` 會是 MainActor 隔離的，測試端（沒開那個設定）拿它去做
/// `XCTAssertEqual` 就會冒出 isolation 告警。
nonisolated enum AutoPlayCycleOutcome: Equatable {
    /// 閘門擋下，附原因
    case skipped(AutoPlayGate.Reason)
    /// 真的送出去了；`action`／`tile` 是 **resolver 裁決後**的，不是 AI 推薦的
    case sent(action: Recommendation.ActionType, tile: String, attempts: Int)
    /// 有值得做的動作，但模式不允許自動送出
    case surfaced(Recommendation.ActionType)
    /// 沒送：閘門之外的原因（resolver 判斷、oplist 已換批、去抖、尚未就緒）
    case notSent(reason: String)
    /// 送了但沒成功；此時 **oplist 必須仍然 pending**
    case sendFailed(action: Recommendation.ActionType, attempts: Int)
    /// 走「主動送過」那條路（實際送出由 `AutoPassDispatcher` 負責）；
    /// `handled` 就是「有沒有消化 oplist」，失敗時必須是 false
    case passed(attempts: Int, handled: Bool)
    /// 「過」一次都沒送：執行被取消，或這批 oplist 已經換掉
    case passSuperseded
}

/// 一輪的完整軌跡（斷言要看得到中間發生什麼，不能只有結果）
nonisolated struct AutoPlayCycle {
    /// 閘門的結論；nil 代表這一輪沒經過閘門（手動觸發）
    let gate: AutoPlayGate.Decision?
    let outcome: AutoPlayCycleOutcome
    /// 這一輪的診斷輸出（包含送進 log／event 通道的每一行，外加送出結果那一行）
    let log: [String]
    /// resolver 覆蓋 AI 推薦時的紀錄；nil 代表沒有覆蓋
    let overrode: (requested: Recommendation.ActionType,
                   resolved: Recommendation.ActionType)?
}

/// 執行位的狀態。
///
/// 取代原本的裸 `UUID?`：「有沒有動作在跑」與「跑到哪一階段」現在是同一個值，
/// 而且只有 `occupy(...)` 能改它。
nonisolated enum AutoPlayExecutionState: Equatable {
    /// 沒有動作在跑，閘門可以放行
    case idle
    /// 已經決定要動，正在等模擬人類的送出延遲
    case waiting(id: UUID, delay: TimeInterval)
    /// 正在跑決策／送出／重試
    case executing(id: UUID)
}

/// 局間確認一輪的結論（p2-5）
///
/// `nonisolated`：與 `AutoPlayCycleOutcome` 同理，測試端（沒開 MainActor 預設隔離）
/// 拿它做 `XCTAssertEqual` 不該冒 isolation 告警。
nonisolated enum AutoConfirmCycleResult: Equatable {
    /// 這一輪沒有待確認的局間結算
    case noPending
    /// WebView 尚未就緒（保留 pending）
    case notReady
    /// 閘門擋下（`.off`/`.recommend` 非自動、或三麻 fail-closed）；pending 保留
    case skipped(AutoPlayGate.Reason)
    /// 真的走了送出流程，附 dispatcher 的結論
    case dispatched(AutoConfirmOutcome)
    /// 已被伺服器受理（第 2 層），正在等權威 `ActionNewRound`（第 3 層）；這一輪不重送（p5 #3）
    case awaitingRound
    /// watchdog 重送用完仍等不到 `ActionNewRound`，放掉待確認避免自動打牌餓死（p5 #3）
    case abandoned
}

// MARK: - Engine

@MainActor
final class AutoPlayEngine {

    // MARK: - 上下文

    /// 引擎每次要決策時，向外面問到的當下狀態。
    ///
    /// 做成「一次取一份」而不是持有 `WebViewModel`：引擎不該知道 UI 的存在，
    /// 而且每次重試都要拿**最新**的推薦（延遲期間模型可能已經重算）。
    struct Context {
        var mode: AutoPlayMode = .auto
        var recommendations: [Recommendation] = []
        /// 自家座位（`WebViewModelProtocol.autoPlaySeat`，兩條 path 同一份定義）
        var seat: Int = 0
        var isSanma: Bool = false
        /// 這一巡摸到的牌，用來判斷 moqie
        var tsumoTile: String?
        /// WebView 是否已就緒（正式路徑 `webPage != nil`）
        var isReady: Bool = true
        /// 使用者的延遲基準係數（`SettingsStore.actionDelayScale`）。
        ///
        /// 每輪從 context 重取，所以 stepper 一調就在下一手生效，不必重啟引擎。
        /// 1.0＝現行行為；乘進 `ActionDelayModel.delay(for:scale:)`。做進 context 而不是
        /// 讓引擎持有 settings：引擎不認得 UI／設定物件，這是它能被單測的前提。
        var actionDelayScale: Double = 1.0
        /// `recommendations` 是針對哪一批 oplist 算的（`GameStore.recommendationsOplistSequence`）。
        /// `.proceed` 用它確認推薦與當前決策機會同源；nil 代表推薦不綁任何 oplist（p5 #1）。
        var recommendationsOplistSequence: UInt64?
    }

    /// 所有時間常數與次數上限。
    ///
    /// 集中在這裡的理由是**測試要能把它們歸零**：fixture 不該真的等 1.8 秒的
    /// 送出延遲或 0.2 秒的重試間隔。正式路徑用 `.live`。
    ///
    /// `nonisolated`：它是 `init` 的預設引數，而預設引數的運算式在 nonisolated
    /// 環境下檢查——不標的話 `.live` 會冒出 actor-isolation 告警。
    nonisolated struct Timing {
        /// 輪詢間隔（原本的 `Timer.scheduledTimer(withTimeInterval: 1.0)`）
        var poll: TimeInterval = 1.0
        /// 副露機會在多久之後才允許「因為沒推薦而自動送過」
        ///
        /// 只要比「oplist 到達 → 推論完成 → 推薦同步」的總延遲長就夠。
        /// 實測該延遲在 100ms 量級，2 秒有 20 倍餘裕；伺服器等 300 秒，多等 2 秒沒有代價。
        var callPassGrace: TimeInterval = 2.0
        /// 和牌送出失敗的重試間隔（漏和不可逆，間隔短一點）
        var horaRetry: TimeInterval = 0.2
        /// 「過」送出失敗的重試間隔
        var passRetry: TimeInterval = 0.5
        /// 其餘動作送出失敗的重試間隔
        var retry: TimeInterval = 0.1
        /// 一輪之內最多送幾次
        ///
        /// 從 50（5 秒）降到 15（1.5 秒）：觸發點已經確認過 oplist 存在，
        /// 這裡要處理的只是短暫空窗，等 5 秒不會讓它比較可能消失。
        var maxAttempts: Int = 15
        /// 「過」最多送幾次（伺服器逾時會代打，不必跟和牌一樣拚）
        var passAttempts: Int = 5
        /// 閘門判定「模型判斷不做副露」時的送出策略；nil＝`AutoPassDispatcher` 的預設
        /// （型別本身是 MainActor 隔離的，所以這裡存 optional，用到時才取預設值）
        var passPolicy: AutoPassDispatcher.RetryPolicy?
        /// 送出前的模擬人類延遲；nil＝用 `ActionDelayModel`（正式路徑）。
        ///
        /// 第二個參數是使用者的延遲係數（`Context.actionDelayScale`）：seam 帶著它，
        /// 測試才驗得到「引擎真的把 stepper 的值讀出來並往下傳」，而不是像 p1-3 那批
        /// 假控制一樣寫進去沒人讀。正式路徑（nil）走 `ActionDelayModel.delay(for:scale:)`。
        var actionDelay: ((Recommendation.ActionType?, Double) -> TimeInterval)?

        // MARK: 局間確認（confirmNewRound）

        /// 局結束到送出 confirmNewRound 之間的等待。
        ///
        /// 給終局一個緩衝：最後一局的 `end_kyoku` 之後緊接著會來 `NotifyGameEndResult`
        /// （終局，不是進下一局）。等這段時間，若終局訊號先到並清掉 pending，這一輪的
        /// dispatcher 開頭 `isSuperseded` 就會停手，不會對終局誤送 confirmNewRound。
        /// 結算窗口有數十秒，多等這一下沒有代價。
        var confirmGrace: TimeInterval = 0.8
        /// confirmNewRound 被伺服器受理（RESPONSE 無 error，第 2 層）之後，等權威
        /// `ActionNewRound`（第 3 層）到達的上限。逾時仍沒進下一局，就重送 confirmNewRound
        /// ——RESPONSE 可能假成功、或 hook 漏了那個 frame，沒有這道 watchdog 會整局卡在
        /// 結算畫面、不重試也不 resync（p5 #3）。結算窗口有數十秒，這個上限給得寬。
        var confirmAckWatchdog: TimeInterval = 6.0
        /// watchdog 重送的次數上限（p5 #3 Codex 復核）。用完仍等不到 `ActionNewRound`
        /// 就放掉 `confirmPending`——若瀏覽器其實已進下一局（我們漏收了 frame），繼續無限
        /// 重送會讓正常自動打牌被 confirm 永久餓死；放掉後自動打牌能對「實際正在進行的那局」
        /// 恢復。若真的卡在結算，退回 p2-5 之前的基準（使用者自己點），不會更糟。
        var confirmMaxWatchdogResends: Int = 3
        /// 時鐘 seam（p5 #3 Codex 復核）：watchdog 的起算與比對都用它，測試可注入可控時鐘。
        /// 用它而不是 runConfirmCycle 的入口時間——ack 實際發生在 grace + 送出 + 等 RESPONSE
        /// 之後，用入口時間當起算點會讓後段 attempt 成功時 watchdog 立刻誤判逾時。
        var clock: () -> Date = Date.init
        /// confirmNewRound 的送出策略；nil＝`AutoConfirmDispatcher` 的預設
        /// （型別在 app target 是 MainActor 隔離的，所以存 optional，用到時才取預設值）
        var confirmPolicy: AutoConfirmDispatcher.RetryPolicy?
        /// 送 confirmNewRound 並判斷伺服器是否受理；nil＝正式路徑
        /// （`sender.sendAwaitingResponse(confirmNewRound)`）。做成 seam 是為了讓
        /// 「成功清 pending／失敗保留」在單測裡不必碰 `LiqiResponseStore` 單例。
        var confirmSend: (() async -> LiqiToolSendOutcome)?

        static let live = Timing()
    }

    // MARK: - 依賴

    private let store: LiqiOperationStore
    private let sender: LiqiActionSender
    private let context: () -> Context
    /// 逐步細節（正式路徑接 `DebugServer.addLog`）
    private let log: (String) -> Void
    /// 「為什麼這樣打／為什麼沒打」——必須進 events.log
    private let event: (String) -> Void
    private let timing: Timing

    // MARK: - 狀態

    /// 執行位。只有 `occupy(...)` 能改。
    private(set) var state: AutoPlayExecutionState = .idle

    /// 去抖：兩個觸發源（輪詢／推薦更新）現在是同一條路，共用同一份狀態不再是耦合
    private var debounce = Debounce()

    /// 單一 Task 迴圈（取代 Timer）
    private var loop: Task<Void, Never>?
    /// 輪詢間隔的睡眠；`wake()` 靠取消它提早叫醒迴圈
    private var nap: Task<Void, Never>?
    private var wakeRequested = false

    /// 待處理的手動觸發（MCP `bot_trigger` / 模式切到自動）
    private var pendingManual: TimeInterval?

    /// 有一個局間結算等著送 confirmNewRound（`end_kyoku` 設、`ActionNewRound`／終局清）。
    ///
    /// 用一個 flag 而不是把確認塞進 oplist 路徑：局間結算沒有 oplist，它是「進下一局」
    /// 的流程訊號，不是牌桌上的可用操作。
    private(set) var confirmPending = false

    /// confirmNewRound 已被伺服器受理（第 2 層）的時間；`ActionNewRound`（第 3 層）到達或
    /// 逾時前一直保留。nil＝尚未送出成功或已進下一局。`confirmPending && confirmAckedAt != nil`
    /// 代表「已確認、等下一局」——這一段先前不存在，confirmed 就直接清 pending（p5 #3）。
    private(set) var confirmAckedAt: Date?

    /// 已 watchdog 重送幾次（p5 #3 Codex 復核）。到上限就放掉 pending，避免自動打牌餓死。
    private var confirmWatchdogResends = 0

    /// 本輪的診斷軌跡（每輪開頭清空）
    private var trace: [String] = []
    private var overrode: (requested: Recommendation.ActionType,
                           resolved: Recommendation.ActionType)?

    // MARK: - 建立

    init(store: LiqiOperationStore,
         sender: LiqiActionSender,
         timing: Timing = .live,
         context: @escaping () -> Context,
         log: @escaping (String) -> Void = { _ in },
         event: @escaping (String) -> Void = { _ in }) {
        self.store = store
        self.sender = sender
        self.timing = timing
        self.context = context
        self.log = log
        self.event = event
    }

    /// `@MainActor` class 在 NakiTests host 釋放會 SIGABRT（見 CLAUDE.md「專案結構的坑」）
    nonisolated deinit {}

    // MARK: - 迴圈

    /// 啟動輪詢迴圈。重複呼叫無效果。
    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.tick()
                guard !Task.isCancelled else { return }
                await self.sleepUntilNextTick()
            }
        }
    }

    /// 停止迴圈（App 收掉、或測試結束）
    func stop() {
        loop?.cancel()
        loop = nil
        nap?.cancel()
        nap = nil
        state = .idle
        confirmPending = false
        confirmAckedAt = nil
        confirmWatchdogResends = 0
    }

    /// 提早結束這次輪詢間隔。
    ///
    /// 事件驅動的觸發（推薦更新／模式切換／手動觸發）不必等下一拍——
    /// 這是原本「推薦更新直接呼叫 triggerAutoPlayIfNeeded」那條路的替代品，
    /// 差別是它現在走**同一個**閘門與同一份去抖狀態。
    func wake() {
        wakeRequested = true
        nap?.cancel()
    }

    /// 模型給了新推薦
    func recommendationsDidChange() {
        wake()
    }

    /// 使用者改了模式。
    ///
    /// 重設去抖：切模式是明確的使用者意圖，不該被「剛才才觸發過同一個推薦」擋住。
    func modeDidChange() {
        debounce.reset()
        wake()
    }

    /// 手動觸發（MCP `bot_trigger`、模式切到自動時的立即送出）
    func requestManualTrigger(delay: TimeInterval) {
        pendingManual = delay
        wake()
    }

    // MARK: - 局間確認生命週期（p2-5）

    /// 一局結束（`ActionHule` / `ActionNoTile` / `ActionLiuJu` → `end_kyoku`）。
    ///
    /// 只設 flag；要不要真的送 confirmNewRound 由 `runConfirmCycle` 的閘門決定。
    /// 不 `wake()`：讓確認等到下一拍輪詢再處理，配合 `confirmGrace` 給終局訊號一個
    /// 先到並取消的窗口（避免對最後一局誤送 confirmNewRound）。
    func roundDidEnd() {
        confirmPending = true
        confirmAckedAt = nil   // 新一局結束，重新開始「送出 → 受理 → 等下一局」
        confirmWatchdogResends = 0
    }

    /// 下一局開始（`ActionNewRound` → `start_kyoku`）——權威推進（第 3 層），確認已生效。
    func roundDidBegin() {
        confirmPending = false
        confirmAckedAt = nil
        confirmWatchdogResends = 0
    }

    /// 對局結束（`NotifyGameEndResult` / `NotifyGameTerminate` → `end_game`）。
    ///
    /// 終局不進下一局：清掉待確認，避免對終局送 confirmNewRound。
    /// 終局本身客戶端還會做什麼（協定層動作）需 live 觀察，未實作。
    func gameDidEnd() {
        confirmPending = false
        confirmAckedAt = nil
        confirmWatchdogResends = 0
    }

    private func tick() async {
        if let delay = pendingManual {
            pendingManual = nil
            await runManualCycle(delay: delay)
            return
        }
        if confirmPending {
            await runConfirmCycle()
            return
        }
        await runCycle()
    }

    private func sleepUntilNextTick() async {
        if wakeRequested {
            wakeRequested = false
            return
        }
        let interval = timing.poll
        // `_ =` 不能省：`try? await` 的結果是 `()?`，直接當 closure 尾端運算式
        // 會讓 Task 的成功型別變成 `()?` 而對不上 `Task<Void, Never>`。
        let nap = Task { _ = try? await Task.sleep(nanoseconds: Self.nanoseconds(interval)) }
        self.nap = nap
        await nap.value
        self.nap = nil
        wakeRequested = false
    }

    // MARK: - 一輪

    /// 輪詢／事件路徑的一輪：閘門 →（延遲）→ resolver → 送出。
    ///
    /// - Parameter now: 注入時間，讓「副露寬限期內／已過」可以在測試裡擺出來。
    @discardableResult
    func runCycle(now: Date = Date()) async -> AutoPlayCycle {
        beginCycle()

        let ctx = context()
        guard ctx.isReady else {
            return finish(gate: nil, outcome: .notSent(reason: "web_view_not_ready"))
        }

        // 這一份 snapshot 會一路傳到 resolver 與 executor。
        // 舊實作在這裡讀一次、延遲之後再讀一次，兩份可以不是同一批（TOCTOU）。
        let snapshot = store.pending

        let gate = AutoPlayGate.evaluate(.init(
            isAutoMode: ctx.mode == .auto,
            isSanma: ctx.isSanma,
            hasActionInFlight: state != .idle,
            snapshot: snapshot,
            recommendations: ctx.recommendations,
            now: now,
            callPassGrace: timing.callPassGrace))

        switch gate {
        case .skip(let reason):
            // 刻意不記 log：這條路一秒跑一次，記下來會把 log 淹掉。
            // 要看被哪一關擋住時，改用 /bot/deep（回傳同一組輸入）重新判一次。
            return finish(gate: gate, outcome: .skipped(reason))

        case .forceHora:
            guard let snapshot else {
                return finish(gate: gate, outcome: .notSent(reason: "no_oplist"))
            }
            note("🎯 oplist 有和牌但模型無推薦 → 交給 resolver (ops=\(snapshot.rawTypes))", to: .event)
            return await perform(requested: .hora,
                                 requestedTile: snapshot.contextTile ?? "",
                                 snapshot: snapshot,
                                 delay: 0,
                                 gate: gate)

        case .sendPass:
            guard let snapshot,
                  let callOp = snapshot.operations.compactMap({ $0.type })
                    .first(where: { $0.isCallOpportunity })
            else {
                return finish(gate: gate, outcome: .notSent(reason: "no_call_operation"))
            }
            // pass 要送 inputChiPengGang 還是 inputOperation，取決於這批機會的類型
            // （吃/碰/大明槓走前者，榮和等走後者），故從快照裡實際的機會操作取通道。
            note("⏰ 副露機會無推薦(Mortal 判斷不做) → 自動送出過 (ops=\(snapshot.rawTypes))",
                 to: .event)
            return await sendPass(snapshot: snapshot, channel: callOp.channel, gate: gate)

        case .proceed:
            guard let snapshot, let top = ctx.recommendations.first else {
                return finish(gate: gate, outcome: .notSent(reason: "no_recommendation"))
            }
            // 推薦必須是針對「這一批 oplist」算出來的。推論是 async 的：新的決策機會
            // （新 snapshot）可能在舊推薦還沒被新推論取代前就到達，此時用舊推薦回應新
            // 機會會送出不可逆的錯誤動作（p5 #1）。
            //
            // provenance（`recommendationsOplistSequence`）由 controller 在推薦真的刷新時綁定。
            // **只在有正面證據時才擋**：provenance 已知且比當前機會**舊**（更小的 sequence）＝
            // 這份推薦是為更早的機會算的，明確 stale → 不送。provenance 未知（nil）或已對上
            // 當前機會就放行——寧可偶爾送一次舊推薦（罕見競態），也不要因為 provenance 判不準
            // 就整局不自動打（strict 等號會這樣，實測會 0 觸發）。
            // `.forceHora`／`.sendPass` 是不看推薦內容的 server-authoritative 防護，不受此限。
            if let recSeq = ctx.recommendationsOplistSequence, recSeq < snapshot.sequence {
                return finish(gate: gate, outcome: .notSent(reason: "recommendations_stale"))
            }
            let delay = actionDelay(for: top.actionType, scale: ctx.actionDelayScale)
            guard debounce.allows(key: "\(top.actionType.rawValue)-\(top.displayTile)",
                                  isPass: top.actionType == .none,
                                  window: delay + 0.5,
                                  now: now)
            else {
                return finish(gate: gate, outcome: .notSent(reason: "debounced"))
            }
            note("觸發: \(top.actionType.rawValue) - \(top.displayTile) (延遲: \(delay)秒)", to: .log)
            return await perform(requested: top.actionType,
                                 requestedTile: top.displayTile,
                                 snapshot: snapshot,
                                 delay: delay,
                                 gate: gate)
        }
    }

    /// 手動觸發的一輪：**不經閘門**（閘門掛在輪詢／事件路徑上），
    /// 但三麻 fail-closed、無推薦、無 oplist 三道自己擋。
    @discardableResult
    func runManualCycle(delay: TimeInterval = 0, now: Date = Date()) async -> AutoPlayCycle {
        beginCycle()

        let ctx = context()
        guard ctx.isReady else {
            note("無法觸發: WebView 尚未就緒", to: .log)
            return finish(gate: nil, outcome: .notSent(reason: "web_view_not_ready"))
        }

        // 三麻 fail-closed（與 `AutoPlayGate` / `AutoPlayDecisionResolver` 同一條規則）。
        // 手動觸發不經閘門，所以要自己擋一次：內建模型只有四麻一份。
        guard !ctx.isSanma else {
            note("⏭️ 三麻對局：自動送出已停用（僅支援四麻）", to: .log)
            return finish(gate: nil, outcome: .notSent(reason: "sanma_unsupported"))
        }

        guard let top = ctx.recommendations.first else {
            note("無法觸發: 無推薦", to: .log)
            return finish(gate: nil, outcome: .notSent(reason: "no_recommendation"))
        }

        // 沒有 oplist 就別排這次觸發：伺服器還沒授權，等下一批到達時輪詢會自己接手。
        guard let snapshot = store.pending else {
            note("略過觸發: 尚無 oplist（\(top.actionType.rawValue) \(top.displayTile)）", to: .log)
            return finish(gate: nil, outcome: .notSent(reason: "no_oplist"))
        }

        note("觸發: \(top.actionType.rawValue) - \(top.displayTile) (延遲: \(delay)秒)", to: .log)
        return await perform(requested: top.actionType,
                             requestedTile: top.displayTile,
                             snapshot: snapshot,
                             delay: delay,
                             gate: nil)
    }

    /// 局間確認的一輪：閘門（mode + 三麻）→（`confirmGrace`）→ 送 confirmNewRound。
    ///
    /// 只在 `confirmPending` 為 true 時做事。閘門用 `AutoPlayGate.allowsConfirm`
    /// （與打牌同一組 Reason，收斂在 gate 一處）；送出與三層成功判準在
    /// `AutoConfirmDispatcher`。
    ///
    /// 三層成功判準的第 3 層（權威 `ActionNewRound`）在這裡才收尾：dispatcher 回
    /// `.confirmed`（第 2 層 RESPONSE 無 error）**不**清 pending，而是記 `confirmAckedAt`
    /// 進入「等下一局」狀態；`roundDidBegin` 到才真的清。若 `confirmAckWatchdog` 內
    /// `ActionNewRound` 仍沒到，重送 confirmNewRound（RESPONSE 可能假成功、或漏了 frame）——
    /// 沒有這道 watchdog 會整局卡在結算畫面（p5 #3）。
    @discardableResult
    func runConfirmCycle() async -> AutoConfirmCycleResult {
        guard confirmPending else { return .noPending }

        beginCycle()

        // 已受理、正在等 ActionNewRound：watchdog 內就安靜等，逾時才重送。
        if let ackedAt = confirmAckedAt {
            if timing.clock().timeIntervalSince(ackedAt) < timing.confirmAckWatchdog {
                return .awaitingRound
            }
            // 逾時：ActionNewRound 沒到。有上限的重送——用完仍沒進下一局就放掉 pending，
            // 避免「瀏覽器其實已進下一局、我們漏收 frame」時 confirm 無限重送把自動打牌餓死
            // （p5 #3 Codex 復核）。
            confirmWatchdogResends += 1
            if confirmWatchdogResends > timing.confirmMaxWatchdogResends {
                note("⚠️ confirmNewRound 重送 \(timing.confirmMaxWatchdogResends) 次仍等不到 "
                     + "ActionNewRound → 放掉待確認，讓自動打牌對實際進行中的那局恢復", to: .event)
                confirmPending = false
                confirmAckedAt = nil
                confirmWatchdogResends = 0
                return .abandoned
            }
            note("⏱️ confirmNewRound 已受理但 ActionNewRound 逾時未到 → 重送 "
                 + "(\(confirmWatchdogResends)/\(timing.confirmMaxWatchdogResends))", to: .event)
            confirmAckedAt = nil
        }

        let ctx = context()
        guard ctx.isReady else {
            // 保留 pending：頁面就緒後的下一輪會接手
            return .notReady
        }

        switch AutoPlayGate.allowsConfirm(isAutoMode: ctx.mode == .auto, isSanma: ctx.isSanma) {
        case .skip(let reason):
            // 不記 log：這條路一秒判一次（pending 期間），記下來會淹掉 log。
            // 使用者在 `.off`/`.recommend`/三麻自己確認，ActionNewRound 到達會清 pending。
            return .skipped(reason)

        case .proceed, .forceHora, .sendPass:
            // allowsConfirm 只會回 .proceed 或 .skip；其餘 case 不可能，但 switch 要窮舉。
            let policy = timing.confirmPolicy ?? .default
            note("🏁 局間結算：送出 confirmNewRound (\(policy.maxAttempts) 次上限)", to: .event)

            let outcome = await occupy(delay: timing.confirmGrace) {
                await AutoConfirmDispatcher.send(
                    policy: policy,
                    // 下一局已開始（roundDidBegin 清 pending）或迴圈被停掉 → 停手
                    isSuperseded: { !self.confirmPending || Task.isCancelled },
                    log: { self.note($0, to: .event) },
                    send: self.confirmSend(awaitResponseMs: policy.awaitResponseMs))
            }

            switch outcome {
            case .confirmed:
                // 第 2 層達成，但還沒進下一局：保留 pending、記**實際 ack 時間**（clock() 在
                // occupy/grace/送出/等 RESPONSE 之後才讀，不是 cycle 入口時間），交給 watchdog
                // 等第 3 層。用入口時間當起算點會讓後段 attempt 成功時 watchdog 立刻誤判逾時。
                confirmAckedAt = timing.clock()
            case .superseded:
                confirmPending = false
                confirmAckedAt = nil
            case .failed:
                break   // 保留 pending，下一輪重試
            }
            return .dispatched(outcome)
        }
    }

    /// 送 confirmNewRound 的實際通道。正式路徑走 `sender.sendAwaitingResponse`
    /// （送出 + 等同 msgId RESPONSE）；測試可用 `Timing.confirmSend` 注入。
    private func confirmSend(awaitResponseMs: Int) -> () async -> LiqiToolSendOutcome {
        if let injected = timing.confirmSend { return injected }
        return {
            await self.sender.sendAwaitingResponse(
                LiqiRequestBuilder.confirmNewRound(), awaitResponseMs: awaitResponseMs)
        }
    }

    // MARK: - 佔住執行位

    /// 佔住執行位，離開時**一定**歸還。
    ///
    /// 舊實作是一個裸 `UUID?` 加一個 `clearExecutionIfCurrent(_:)`，要求 8 條 return
    /// 路徑各自記得歸零；漏一條就是「1 秒輪詢永久停用」。`defer` 讓它變成語言保證。
    private func occupy<T>(delay: TimeInterval, _ body: () async -> T) async -> T {
        let id = UUID()
        state = .waiting(id: id, delay: delay)
        defer { state = .idle }
        await sleep(delay)
        state = .executing(id: id)
        return await body()
    }

    // MARK: - 決策 ＋ 送出

    private func perform(requested: Recommendation.ActionType,
                         requestedTile: String,
                         snapshot: LiqiOperationSnapshot,
                         delay: TimeInterval,
                         gate: AutoPlayGate.Decision?) async -> AutoPlayCycle {
        await occupy(delay: delay) {
            await self.deliver(requested: requested,
                               requestedTile: requestedTile,
                               snapshot: snapshot,
                               gate: gate)
        }
    }

    /// 送出（含重試）。舊實作是 `executeAutoPlayActionWithRetry` ⇄ `checkAndRetryIfNeeded`
    /// 兩個 async 函式互相遞迴（深度 15）；這裡是一個 while 迴圈。
    private func deliver(requested initialAction: Recommendation.ActionType,
                         requestedTile initialTile: String,
                         snapshot: LiqiOperationSnapshot,
                         gate: AutoPlayGate.Decision?) async -> AutoPlayCycle {

        var requested = initialAction
        var requestedTile = initialTile
        var attempt = 0

        while attempt < timing.maxAttempts {
            attempt += 1

            // ① 這批 oplist 還是閘門看到的那一批嗎？
            //
            // 決策的權威來源綁在 `snapshot` 上，所以「已經換批」只能是放棄，
            // 不能拿舊觸發去操作新機會（舊實作會重新讀一批再送，等於替下一個決策做主）。
            guard AutoPlayDecisionResolver.isStillValid(
                decidedOn: snapshot, current: store.pending)
            else {
                note("⏭️ oplist 已更新，捨棄過期決策 (seq=\(snapshot.sequence))", to: .event)
                return finish(gate: gate, outcome: .notSent(reason: "stale_oplist"))
            }

            // 每次重試都重新取上下文：延遲／重試期間模型可能已經重算推薦。
            let ctx = context()

            // ② 送出前的唯一決策點：終局保護（伺服器提供和牌就一定和，凌駕 AI）、
            //    模式閘門、以及確認該動作真的在這批 oplist 裡。
            let decision = AutoPlayDecisionResolver.resolve(
                snapshot: snapshot,
                recommendations: ctx.recommendations,
                mode: ctx.mode,
                seat: ctx.seat,
                isSanma: ctx.isSanma)

            let action: Recommendation.ActionType
            let tile: String
            switch decision {
            case .send(let resolvedAction, let resolvedTile):
                action = resolvedAction
                tile = resolvedTile.isEmpty ? requestedTile : resolvedTile
            case .surfaceOnly(let resolvedAction, _):
                note("模式非自動，僅顯示不送出: \(resolvedAction.rawValue)", to: .log)
                return finish(gate: gate, outcome: .surfaced(resolvedAction))
            case .none(let reason):
                note("⏭️ 不送出: \(reason)", to: .log)
                return finish(gate: gate, outcome: .notSent(reason: reason))
            }

            if action != requested {
                overrode = (requested: requested, resolved: action)
                note("⚠️ 決策覆蓋: AI 建議 \(requested.rawValue) → 實際送出 \(action.rawValue)",
                     to: .event)
            }

            note("第 \(attempt) 次嘗試: ops=\(snapshot.rawTypes) → \(action.rawValue)", to: .event)

            // ③ 實際送出：7-case switch 與「成功才 markHandled」都在 executor（p2-1）
            let result = await AutoPlayActionExecutor.execute(
                action: action,
                tile: tile,
                snapshot: snapshot,
                recommendations: ctx.recommendations,
                tsumoTile: ctx.tsumoTile,
                sender: sender,
                store: store,
                log: { self.note($0, to: .log) },
                event: { self.note($0, to: .event) })

            // 送出結果只進軌跡：正式路徑已經由 `LiqiActionSender.logHandler` 記過一次，
            // 這裡再送一次 log 通道就會在 /logs 出現兩行。
            note(result?.logLine ?? "❌ 未送出（組不出 request）: \(action.rawValue)", to: .traceOnly)

            if result?.success == true {
                if action == .hora { note("✅ 已宣告和牌", to: .event) }
                return finish(gate: gate,
                              outcome: .sent(action: action, tile: tile, attempts: attempt))
            }

            // 失敗：下一輪用 resolver 裁決後的動作（舊實作的遞迴也是這樣傳）
            requested = action
            requestedTile = tile

            let limit = retryLimit(for: action)
            guard attempt < limit else {
                switch action {
                case .hora:
                    // 和牌不可逆：放棄一定要留下原因，而且 oplist 保留給下一輪
                    note("❌ 和牌送出失敗 \(attempt) 次, 放棄 (\(result?.logLine ?? "no result"))",
                         to: .event)
                case .none:
                    note("✅ Pass 已發送 (第 \(attempt) 次)", to: .log)
                default:
                    note("❌ 已達最大重試次數 (\(attempt)), ops=\(snapshot.rawTypes)", to: .log)
                }
                return finish(gate: gate,
                              outcome: .sendFailed(action: action, attempts: attempt))
            }

            note("⚠️ \(action.rawValue) 送出失敗, 重試 \(attempt + 1)/\(limit)", to: .event)
            await sleep(retryDelay(for: action))
        }

        return finish(gate: gate,
                      outcome: .sendFailed(action: requested, attempts: attempt))
    }

    /// 「模型判斷不做副露 → 主動送過」。
    ///
    /// 送出與收工策略在 `AutoPassDispatcher`（p0-1）：**只有送出成功之後**才消化 oplist。
    private func sendPass(snapshot: LiqiOperationSnapshot,
                          channel: LiqiActionChannel,
                          gate: AutoPlayGate.Decision?) async -> AutoPlayCycle {
        await occupy(delay: 0) {
            let outcome = await AutoPassDispatcher.send(
                sequence: snapshot.sequence,
                store: self.store,
                policy: self.timing.passPolicy ?? .default,
                // 迴圈被停掉（App 收掉／模式切換造成 stop）就別再送
                isCurrent: { !Task.isCancelled },
                log: { self.note($0, to: .event) },
                send: { await self.sender.pass(channel: channel) })

            switch outcome {
            case .handled(let attempts):
                return self.finish(gate: gate, outcome: .passed(attempts: attempts, handled: true))
            case .failed(let attempts):
                return self.finish(gate: gate, outcome: .passed(attempts: attempts, handled: false))
            case .superseded:
                return self.finish(gate: gate, outcome: .passSuperseded)
            }
        }
    }

    // MARK: - 參數

    private func actionDelay(for action: Recommendation.ActionType?,
                             scale: Double) -> TimeInterval {
        // 固定時序是指紋：正式路徑一律由 `ActionDelayModel` 依動作類型抽樣，
        // `scale` 只縮放分布不取代它。使用者的基準秒數係數走 `Context.actionDelayScale`。
        timing.actionDelay?(action, scale) ?? ActionDelayModel.delay(for: action, scale: scale)
    }

    private func retryLimit(for action: Recommendation.ActionType) -> Int {
        // 「過」不必跟和牌一樣拚：伺服器逾時會代打，而和牌漏掉就沒了。
        action == .none ? min(timing.passAttempts, timing.maxAttempts) : timing.maxAttempts
    }

    private func retryDelay(for action: Recommendation.ActionType) -> TimeInterval {
        switch action {
        case .hora: return timing.horaRetry
        case .none: return timing.passRetry
        default: return timing.retry
        }
    }

    // MARK: - 軌跡

    private enum Sink {
        case log
        case event
        /// 只留在本輪軌跡（正式路徑已經由別人記過）
        case traceOnly
    }

    private func note(_ message: String, to sink: Sink) {
        trace.append(message)
        switch sink {
        case .log: log(message)
        case .event: event(message)
        case .traceOnly: break
        }
    }

    private func beginCycle() {
        trace.removeAll()
        overrode = nil
    }

    private func finish(gate: AutoPlayGate.Decision?,
                        outcome: AutoPlayCycleOutcome) -> AutoPlayCycle {
        AutoPlayCycle(gate: gate, outcome: outcome, log: trace, overrode: overrode)
    }

    // MARK: - 睡眠

    private func sleep(_ seconds: TimeInterval) async {
        guard seconds > 0 else { return }
        try? await Task.sleep(nanoseconds: Self.nanoseconds(seconds))
    }

    private static func nanoseconds(_ seconds: TimeInterval) -> UInt64 {
        UInt64(max(0, seconds) * 1_000_000_000)
    }

    // MARK: - 去抖

    /// 同一個推薦短時間內只觸發一次。
    ///
    /// 「過」不去抖：每一次新的副露機會都必須回應，而它們的 key 會一樣。
    private struct Debounce {
        private var key: String?
        private var time: Date?

        mutating func allows(key candidate: String,
                             isPass: Bool,
                             window: TimeInterval,
                             now: Date) -> Bool {
            if !isPass,
               let key, let time,
               key == candidate,
               now.timeIntervalSince(time) < window {
                return false
            }
            key = candidate
            time = now
            return true
        }

        mutating func reset() {
            key = nil
            time = nil
        }
    }
}

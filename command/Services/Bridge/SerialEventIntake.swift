//
//  SerialEventIntake.swift
//  Naki
//
//  兩條 WebView path 共用的「事件序列化入口」。
//
//  問題：`WebSocketMessageHandler.onMJAIEvent` 是同步回調，而處理一則 MJAI 事件是
//  async 的（`start_game` 中間要 `await createBot`）。最直覺的寫法
//  `Task { @MainActor in await handle(event) }` 每則事件開一個獨立 Task，
//  而**獨立 Task 之間沒有任何順序保證**：
//
//      start_game → Task A（await createBot，暫停）
//      tsumo      → Task B（可能先跑完）
//
//  結果是事件亂序、甚至在 bot 建立完成前就被消費。
//
//  這個型別是兩條 WebView path 共用的那一份「單一 buffered AsyncStream + 單一 consumer」：
//    1. FIFO——單一 stream、單一 consumer，事件依 `yield` 順序處理；
//    2. handler 完全跑完（含內部所有 await）才取下一則事件，
//       所以 `start_game` 的 bot 建立一定早於後續事件被處理。
//
//  刻意標 `nonisolated`：`yield` 會從 WKScriptMessageHandler 的回調直接呼叫，
//  而 handler 本身要在 MainActor 上跑（它會碰 coordinator 與 `GameStore`）。
//  同時這也讓單元測試可以自由建立／釋放它——MainActor 隔離的 class 在測試裡被釋放
//  會直接 SIGABRT（見 CLAUDE.md「專案結構的坑」）。
//

import Foundation

/// 把同步回調來的事件序列化成「單一 consumer 依序 await」的入口。
nonisolated final class SerialEventIntake {

    /// 事件投遞口。`AsyncStream.Continuation` 本身是 Sendable，可從任何執行緒呼叫。
    private let continuation: AsyncStream<[String: Any]>.Continuation

    /// 唯一的 consumer。持有它是為了在釋放時取消，避免測試／重建 coordinator 後留下孤兒 task。
    private let consumer: Task<Void, Never>

    /// - Parameter handler: 逐則事件的處理器，在 MainActor 上依序執行；
    ///   一則完全處理完（含內部 await）才會取下一則。
    init(handler: @escaping @MainActor ([String: Any]) async -> Void) {
        let (stream, continuation) = AsyncStream<[String: Any]>.makeStream(
            bufferingPolicy: .unbounded)
        self.continuation = continuation
        self.consumer = Task { @MainActor in
            for await event in stream {
                await handler(event)
            }
        }
    }

    deinit {
        continuation.finish()
        consumer.cancel()
    }

    /// 投遞一則事件（不阻塞呼叫端；順序即處理順序）
    func yield(_ event: [String: Any]) {
        continuation.yield(event)
    }

}

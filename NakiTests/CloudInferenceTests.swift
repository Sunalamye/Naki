//
//  CloudInferenceTests.swift
//  NakiTests
//
//  雲端推論 overlay 的元件測試。測試清單移植自 Akagi v3 `api.rs`/`native.rs`
//  的測試（那是已在生產環境驗過的規格書）：
//  - bearer key 只進 Authorization header，永不進 URL
//  - 空物件 `{}` 也要能解析（三欄位全可缺）
//  - `model` 空/nil 時不送欄位（不是送空字串）
//  - 非 2xx 錯誤帶出伺服器 `{"error"}` 訊息與 Retry-After
//  - `/v3/models` 回應包一層 `{"models": [...]}`
//  - `/healthz` 不送 Authorization
//  - 斷路器 5s→120s 指數退避、封頂、reset
//  - 每局視窗：start_kyoku 清尾巴但保留 start_game 當 events[0]
//  - 三麻補位到長度 4；內部欄位（__nakiOplistSequence、start_game 的 id/is3P）剝除
//
//  ⚠️ 這些是元件測試：NativeBotController 的 overlay 整合（含立直兩段式的
//  live 時序）沒有 live 對局驗證，狀態記在 docs/cloud-inference-plan.md。
//

import XCTest

@testable import Naki

// MARK: - URLProtocol mock

/// 攔下 URLSession 流量的 stub：回放腳本化回應、捕獲原始 request 供斷言。
final class CloudMockURLProtocol: URLProtocol {

    /// (status, body, headers) 依呼叫順序回放；不夠用時回 500
    static var script: [(Int, String, [String: String])] = []
    /// 捕獲的 request（含讀出的 body）
    static var captured: [(request: URLRequest, body: Data)] = []

    static func reset(script: [(Int, String, [String: String])]) {
        self.script = script
        self.captured = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // URLSession 會把 httpBody 轉成 stream；要斷言 body 得從 stream 讀回來
        var body = Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            let bufferSize = 4096
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: bufferSize)
                guard read > 0 else { break }
                body.append(buffer, count: read)
            }
        } else if let data = request.httpBody {
            body = data
        }
        Self.captured.append((request, body))

        let (status, text, headers) = Self.script.isEmpty
            ? (500, #"{"error":"script exhausted"}"#, [:])
            : Self.script.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: "HTTP/1.1",
                                       headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - KyokuStreamAccumulator

@MainActor
final class KyokuStreamAccumulatorTests: XCTestCase {

    private func startGame() -> [String: Any] {
        ["type": "start_game", "id": 2, "is3P": false,
         "names": ["A", "B", "C", "D"]]
    }

    private func startKyoku(kyoku: Int) -> [String: Any] {
        ["type": "start_kyoku", "bakaze": "E", "kyoku": kyoku, "honba": 0,
         "kyotaku": 0, "oya": 0, "dora_marker": "5m",
         "scores": [25000, 25000, 25000, 25000],
         "tehais": [[String]](repeating: [String](repeating: "?", count: 13), count: 4)]
    }

    func test_startKyoku_clearsPreviousKyoku_butKeepsStartGameAsFirstEvent() {
        var accumulator = KyokuStreamAccumulator()
        accumulator.accumulate(startGame())
        accumulator.accumulate(startKyoku(kyoku: 1))
        accumulator.accumulate(["type": "tsumo", "actor": 2, "pai": "1m"])
        accumulator.accumulate(["type": "dahai", "actor": 2, "pai": "1m", "tsumogiri": true])
        accumulator.accumulate(["type": "end_kyoku"])
        accumulator.accumulate(startKyoku(kyoku: 2))

        let types = accumulator.events.map { $0["type"] as? String }
        XCTAssertEqual(types, ["start_game", "start_kyoku"],
                       "上一局的尾巴要清掉，start_game 必須留在 events[0]")
        XCTAssertEqual(accumulator.events[1]["kyoku"] as? Int, 2)
        XCTAssertTrue(accumulator.hasUploadableWindow)
    }

    func test_startGame_resetsEverything() {
        var accumulator = KyokuStreamAccumulator()
        accumulator.accumulate(startGame())
        accumulator.accumulate(startKyoku(kyoku: 1))
        accumulator.accumulate(startGame())
        XCTAssertEqual(accumulator.events.count, 1)
        XCTAssertFalse(accumulator.hasUploadableWindow,
                       "只有 start_game 還不能上傳（缺 start_kyoku）")
    }

    func test_windowWithoutStartGame_isNotUploadable() {
        var accumulator = KyokuStreamAccumulator()
        // 局中途啟動：沒收到 start_game
        accumulator.accumulate(startKyoku(kyoku: 3))
        accumulator.accumulate(["type": "tsumo", "actor": 0, "pai": "1m"])
        XCTAssertFalse(accumulator.hasUploadableWindow)
    }

    func test_apiEvent_startGame_keepsOnlyTypeAndNames() {
        let shaped = KyokuStreamAccumulator.apiEvent(startGame(), is3P: false)
        XCTAssertEqual(shaped.count, 2)
        XCTAssertEqual(shaped["type"] as? String, "start_game")
        XCTAssertEqual(shaped["names"] as? [String], ["A", "B", "C", "D"])
        XCTAssertNil(shaped["id"], "Naki 內部的座位欄位不上傳")
        XCTAssertNil(shaped["is3P"], "Naki 內部旗標不上傳")
    }

    func test_apiEvent_stripsOplistSequence() {
        let event: [String: Any] = ["type": "tsumo", "actor": 0, "pai": "1m",
                                    MJAIEventKey.oplistSequence: UInt64(7)]
        let shaped = KyokuStreamAccumulator.apiEvent(event, is3P: false)
        XCTAssertNil(shaped[MJAIEventKey.oplistSequence])
        XCTAssertEqual(shaped["pai"] as? String, "1m")
    }

    func test_apiEvent_reach_isBareTypeAndActor() {
        let event: [String: Any] = ["type": "reach", "actor": 1, "pai": "5p"]
        let shaped = KyokuStreamAccumulator.apiEvent(event, is3P: false)
        XCTAssertEqual(shaped.count, 2)
        XCTAssertEqual(shaped["actor"] as? Int, 1)
        XCTAssertNil(shaped["pai"], "伺服器要裸 reach，預測捨牌欄位要剝掉")
    }

    func test_apiEvent_nukidora_isTranslatedToKita() {
        // bridge 的拔北事件名是 nukidora，伺服器 schema 是 kita——必須轉譯，
        // 否則三麻事件流 desync
        let event: [String: Any] = ["type": "nukidora", "actor": 2, "pai": "N"]
        let shaped = KyokuStreamAccumulator.apiEvent(event, is3P: true)
        XCTAssertEqual(shaped["type"] as? String, "kita")
        XCTAssertEqual(shaped["actor"] as? Int, 2)
        XCTAssertEqual(shaped["pai"] as? String, "N")
    }

    func test_apiEvent_3p_padsNamesScoresTehaisToFour() {
        let game: [String: Any] = ["type": "start_game", "id": 0, "is3P": true,
                                   "names": ["A", "B", "C"]]
        let shapedGame = KyokuStreamAccumulator.apiEvent(game, is3P: true)
        XCTAssertEqual((shapedGame["names"] as? [String])?.count, 4)
        XCTAssertEqual((shapedGame["names"] as? [String])?.last, "")

        let kyoku: [String: Any] = [
            "type": "start_kyoku", "bakaze": "E", "kyoku": 1, "honba": 0,
            "kyotaku": 0, "oya": 0, "dora_marker": "1z",
            "scores": [35000, 35000, 35000],
            "tehais": [[String]](repeating: [String](repeating: "?", count: 13), count: 3),
        ]
        let shapedKyoku = KyokuStreamAccumulator.apiEvent(kyoku, is3P: true)
        XCTAssertEqual((shapedKyoku["scores"] as? [Int]), [35000, 35000, 35000, 0])
        let tehais = shapedKyoku["tehais"] as? [[String]]
        XCTAssertEqual(tehais?.count, 4)
        XCTAssertEqual(tehais?.last, [String](repeating: "?", count: 13),
                       "幽靈第四家：13 張 ?")
    }

    func test_apiEvent_4p_passesStartKyokuThroughUnchanged() {
        let shaped = KyokuStreamAccumulator.apiEvent(startKyoku(kyoku: 1), is3P: false)
        XCTAssertEqual((shaped["scores"] as? [Int])?.count, 4)
        XCTAssertEqual((shaped["tehais"] as? [[String]])?.count, 4)
    }
}

// MARK: - CloudBreaker

@MainActor
final class CloudBreakerTests: XCTestCase {

    func test_backoff_isExponential_andCapsAt120s() {
        var breaker = CloudBreaker()
        let start = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(breaker.recordFailure(now: start), 5)
        XCTAssertEqual(breaker.recordFailure(now: start), 10)
        XCTAssertEqual(breaker.recordFailure(now: start), 20)
        XCTAssertEqual(breaker.recordFailure(now: start), 40)
        XCTAssertEqual(breaker.recordFailure(now: start), 80)
        XCTAssertEqual(breaker.recordFailure(now: start), 120)
        XCTAssertEqual(breaker.recordFailure(now: start), 120, "封頂 120s")
    }

    func test_openWindow_suppressesCalls_untilExpiry() {
        var breaker = CloudBreaker()
        let start = Date(timeIntervalSince1970: 100)
        breaker.recordFailure(now: start)   // 視窗 5s
        XCTAssertFalse(breaker.allows(now: start.addingTimeInterval(4.9)))
        XCTAssertTrue(breaker.allows(now: start.addingTimeInterval(5.0)))
    }

    func test_success_closesBreaker_andResetsCount() {
        var breaker = CloudBreaker()
        let start = Date(timeIntervalSince1970: 0)
        breaker.recordFailure(now: start)
        breaker.recordFailure(now: start)
        breaker.recordSuccess()
        XCTAssertTrue(breaker.allows(now: start))
        XCTAssertEqual(breaker.recordFailure(now: start), 5,
                       "成功後計數歸零，下次失敗從 base 重來")
    }

    func test_reset_restoresHealthyState() {
        var breaker = CloudBreaker()
        breaker.healthy = false
        breaker.recordFailure(now: Date(timeIntervalSince1970: 0))
        breaker.reset()
        XCTAssertTrue(breaker.healthy)
        XCTAssertTrue(breaker.allows(now: Date(timeIntervalSince1970: 0)))
    }
}

// MARK: - CloudDecisionMapper

@MainActor
final class CloudDecisionMapperTests: XCTestCase {

    func test_dahaiReaction_becomesTopDiscardRow_withCandidateTail() {
        let recs = CloudDecisionMapper.recommendations(
            reaction: ["type": "dahai", "actor": 2, "pai": "5mr", "tsumogiri": false],
            candidates: [CloudCandidate(action: "dahai:5mr", prob: 0.85),
                         CloudCandidate(action: "reach", prob: 0.11),
                         CloudCandidate(action: "dahai:W", prob: 0.04)],
            reachDiscard: nil)
        XCTAssertEqual(recs?.count, 3)
        XCTAssertEqual(recs?[0].actionType, .discard)
        XCTAssertEqual(recs?[0].displayTile, "5mr")
        XCTAssertEqual(recs?[0].probability ?? 0, 0.85, accuracy: 1e-9)
        XCTAssertEqual(recs?[1].actionType, .riichi)
        XCTAssertEqual(recs?[2].displayTile, "W")
    }

    func test_reachReaction_insertsCloudDiscard_asFirstDiscardRow() {
        // executor 的立直宣言牌取清單順序第一個 discard——必須是雲端第二段解出的那張
        let recs = CloudDecisionMapper.recommendations(
            reaction: ["type": "reach", "actor": 2],
            candidates: [CloudCandidate(action: "reach", prob: 0.9),
                         CloudCandidate(action: "dahai:1s", prob: 0.08)],
            reachDiscard: "9p")
        XCTAssertEqual(recs?[0].actionType, .riichi)
        let firstDiscard = recs?.first { $0.actionType == .discard }
        XCTAssertEqual(firstDiscard?.displayTile, "9p",
                       "宣言牌必須是雲端解出的捨牌，不是 candidates 裡的其他 dahai")
    }

    func test_reachReaction_withoutResolvedDiscard_isUnmappable() {
        XCTAssertNil(CloudDecisionMapper.recommendations(
            reaction: ["type": "reach", "actor": 2],
            candidates: [], reachDiscard: nil),
            "沒有捨牌的立直會卡死自動打牌——寧可退回本地")
    }

    func test_passReaction_isARealRow() {
        // 「放棄副露也是一種選擇」（Akagi #190）——pass 是真實的一列
        let recs = CloudDecisionMapper.recommendations(
            reaction: ["type": "none"],
            candidates: [CloudCandidate(action: "none", prob: 0.87),
                         CloudCandidate(action: "pon", prob: 0.13)],
            reachDiscard: nil)
        XCTAssertEqual(recs?[0].actionType, Recommendation.ActionType.none)
        XCTAssertEqual(recs?[1].actionType, .pon)
    }

    func test_chiVariants_matchLiqiCombinationSemantics() {
        // 0＝被吃的牌最小、1＝中間、2＝最大（與 chiCombinationIndex 同一套推導）
        XCTAssertEqual(CloudDecisionMapper.chiVariant(called: "3m", consumed: ["4m", "5m"]), 0)
        XCTAssertEqual(CloudDecisionMapper.chiVariant(called: "3m", consumed: ["2m", "4m"]), 1)
        XCTAssertEqual(CloudDecisionMapper.chiVariant(called: "3m", consumed: ["1m", "2m"]), 2)
        XCTAssertEqual(CloudDecisionMapper.chiVariant(called: "5s", consumed: ["4s", "6s"]), 1)
        XCTAssertNil(CloudDecisionMapper.chiVariant(called: "E", consumed: ["1m", "2m"]),
                     "字牌不能吃")

        let recs = CloudDecisionMapper.recommendations(
            reaction: ["type": "chi", "actor": 1, "pai": "3m",
                       "consumed": ["4m", "5m"], "target": 0],
            candidates: [CloudCandidate(action: "chi_low", prob: 0.6)],
            reachDiscard: nil)
        XCTAssertEqual(recs?[0].actionType, .chi)
        XCTAssertEqual(recs?[0].displayTile, "chi_0")
    }

    func test_kanReactions_mapToKan() {
        for type in ["daiminkan", "ankan", "kakan"] {
            let recs = CloudDecisionMapper.recommendations(
                reaction: ["type": type, "actor": 0, "consumed": ["1m", "1m", "1m"]],
                candidates: [], reachDiscard: nil)
            XCTAssertEqual(recs?[0].actionType, .kan, "\(type) 應映射為 kan")
        }
    }

    func test_unknownReactionType_isUnmappable() {
        // kita 已於 2026-08-05 接上（三麻自動打鏈），改用真正未知的型別
        XCTAssertNil(CloudDecisionMapper.recommendations(
            reaction: ["type": "ryukyoku"],
            candidates: [], reachDiscard: nil),
            "未知動作不硬映射，退回本地")
    }

    func test_unknownCandidateLabels_areSkipped_notGuessed() {
        let recs = CloudDecisionMapper.recommendations(
            reaction: ["type": "dahai", "actor": 0, "pai": "1m", "tsumogiri": true],
            candidates: [CloudCandidate(action: "dahai:1m", prob: 0.7),
                         CloudCandidate(action: "ryukyoku", prob: 0.2),
                         CloudCandidate(action: "future_label", prob: 0.1)],
            reachDiscard: nil)
        XCTAssertEqual(recs?.count, 1, "ryukyoku 與未知標籤都略過")
    }

    // MARK: 拔北（三麻，2026-08-05）

    func test_kitaReaction_andNukidoraCandidate_mapToKita() {
        let recs = CloudDecisionMapper.recommendations(
            reaction: ["type": "kita", "actor": 0, "pai": "N"],
            candidates: [CloudCandidate(action: "nukidora", prob: 0.8),
                         CloudCandidate(action: "dahai:N", prob: 0.2)],
            reachDiscard: nil)
        XCTAssertEqual(recs?[0].actionType, .kita)
        XCTAssertEqual(recs?[0].probability ?? 0, 0.8, accuracy: 1e-9)
        XCTAssertEqual(recs?[1].actionType, .discard)
    }

    func test_nukidoraCandidateAlone_mapsToKitaRow() {
        let rec = CloudDecisionMapper.recommendation(fromCandidate: "nukidora", prob: 0.3)
        XCTAssertEqual(rec?.actionType, .kita)
    }

    func test_duplicateCandidateOfReaction_isDeduped() {
        let recs = CloudDecisionMapper.recommendations(
            reaction: ["type": "pon", "actor": 0, "pai": "5p",
                       "consumed": ["5p", "5p"], "target": 1],
            candidates: [CloudCandidate(action: "pon", prob: 0.55),
                         CloudCandidate(action: "none", prob: 0.45)],
            reachDiscard: nil)
        XCTAssertEqual(recs?.map(\.actionType), [.pon, Recommendation.ActionType.none])
    }
}

// MARK: - AkagiApiClient

@MainActor
final class AkagiApiClientTests: XCTestCase {

    private func makeClient(key: String = "SECRETKEY") -> AkagiApiClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CloudMockURLProtocol.self]
        return AkagiApiClient(baseURL: "http://mock.test:8080/", key: key,
                              configuration: config)!
    }

    private func header(_ request: URLRequest, _ name: String) -> String? {
        request.value(forHTTPHeaderField: name)
    }

    func test_init_rejectsGarbageAndNonHTTPSchemes() {
        XCTAssertNil(AkagiApiClient(baseURL: "", key: "k"))
        XCTAssertNil(AkagiApiClient(baseURL: "not a url", key: "k"))
        XCTAssertNil(AkagiApiClient(baseURL: "ftp://host", key: "k"))
        XCTAssertNotNil(AkagiApiClient(baseURL: "  https://host/  ", key: "k"),
                        "頭尾空白與尾斜線要被正規化")
    }

    func test_react_sendsBearerHeader_andKeyNeverAppearsInURL() async throws {
        CloudMockURLProtocol.reset(script: [
            (200, #"{"reaction":{"type":"none"},"candidates":[{"action":"none","prob":1.0}],"model":"4p-x"}"#, [:]),
        ])
        let client = makeClient()
        let response = try await client.react(model: "4p-x", playerId: 2,
                                              events: [["type": "start_game"]])
        XCTAssertEqual(response.model, "4p-x")

        let (request, body) = CloudMockURLProtocol.captured[0]
        XCTAssertEqual(request.url?.path, "/v3/react")
        XCTAssertEqual(header(request, "Authorization"), "Bearer SECRETKEY")
        XCTAssertFalse(request.url!.absoluteString.contains("SECRETKEY"),
                       "key 永不進 URL")

        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        XCTAssertEqual(json?["player_id"] as? Int, 2)
        XCTAssertEqual(json?["model"] as? String, "4p-x")
        XCTAssertEqual((json?["events"] as? [[String: Any]])?.count, 1)
    }

    func test_react_omitsModelField_whenNilOrEmpty() async throws {
        CloudMockURLProtocol.reset(script: [(200, "{}", [:]), (200, "{}", [:])])
        let client = makeClient()
        _ = try await client.react(model: nil, playerId: 0, events: [])
        _ = try await client.react(model: "", playerId: 0, events: [])
        for (_, body) in CloudMockURLProtocol.captured {
            let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            XCTAssertNil(json?["model"], "空 model 不送欄位，不是送空字串")
        }
    }

    func test_react_parsesEmptyObject_withAllFieldsDefaulted() async throws {
        CloudMockURLProtocol.reset(script: [(200, "{}", [:])])
        let response = try await makeClient().react(model: nil, playerId: 0, events: [])
        XCTAssertNil(response.reaction)
        XCTAssertTrue(response.candidates.isEmpty)
        XCTAssertNil(response.model)
    }

    func test_httpError_surfacesServerMessage_andRetryAfter() async {
        CloudMockURLProtocol.reset(script: [
            (429, #"{"error":"rate limited"}"#, ["Retry-After": "30"]),
        ])
        do {
            _ = try await makeClient().react(model: nil, playerId: 0, events: [])
            XCTFail("非 2xx 必須拋錯")
        } catch {
            let text = error.localizedDescription
            XCTAssertTrue(text.contains("429"), text)
            XCTAssertTrue(text.contains("rate limited"), text)
            XCTAssertTrue(text.contains("30"), text)
            XCTAssertFalse(text.contains("SECRETKEY"), "錯誤訊息不得含 key")
        }
    }

    func test_models_parsesWrappedList() async throws {
        CloudMockURLProtocol.reset(script: [
            (200, #"{"models":[{"id":"4p-ot2","game":"4p","desc":"d"},{"id":"3p-ot2","game":"3p","desc":"e"}]}"#, [:]),
        ])
        let models = try await makeClient().models()
        XCTAssertEqual(models.count, 2)
        XCTAssertEqual(models[0].id, "4p-ot2")
        XCTAssertEqual(models[1].game, "3p")
        let (request, _) = CloudMockURLProtocol.captured[0]
        XCTAssertEqual(header(request, "Authorization"), "Bearer SECRETKEY")
    }

    func test_health_sendsNoAuthorizationHeader() async throws {
        // health 是無認證端點——多送 key 是無謂洩漏（Akagi 同款斷言）
        CloudMockURLProtocol.reset(script: [
            (200, #"{"status":"ok","models":["4p-x"]}"#, [:]),
        ])
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CloudMockURLProtocol.self]
        let health = try await AkagiApiClient.health(baseURL: "http://mock.test",
                                                     configuration: config)
        XCTAssertEqual(health.status, "ok")
        XCTAssertEqual(health.models, ["4p-x"])

        let (request, _) = CloudMockURLProtocol.captured[0]
        XCTAssertEqual(request.url?.path, "/healthz")
        XCTAssertNil(header(request, "Authorization"),
                     "無認證端點不得送 Authorization header")
    }
}

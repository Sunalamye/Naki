//
//  NakiViewActionTests.swift
//  NakiTests
//
//  U-P2：設定頁與插件頁收進 Action 的邏輯（雲端探測分類、全自動開始、區服選擇）。
//  網路一律走 `CloudMockURLProtocol`，不連真雲端。
//

import XCTest

@testable import Naki

@MainActor
final class NakiViewActionTests: XCTestCase {

    private let defaultsKeys = [
        SettingsStore.majsoulServerKey, SettingsStore.pinMajsoulServerKey,
        SettingsStore.fullAutoPrefersSanmaKey, SettingsStore.fullAutoRoomPreferenceKey,
    ]
    private var savedDefaults: [String: Any?] = [:]

    override func setUp() {
        super.setUp()
        savedDefaults = Dictionary(uniqueKeysWithValues: defaultsKeys.map {
            ($0, UserDefaults.standard.object(forKey: $0))
        })
    }

    override func tearDown() {
        for (key, value) in savedDefaults { UserDefaults.standard.set(value, forKey: key) }
        super.tearDown()
    }

    private var mockConfig: URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CloudMockURLProtocol.self]
        return config
    }

    private let keyJSON = #"{"plan":"pro","expires_at":"2030-01-01T00:00:00Z","usage_today":3,"rpd":100,"rpm":10.0,"topk":5}"#
    private let modelsJSON = #"{"models":[{"id":"4p-x","game":"4p","desc":"d"}]}"#
    private let healthJSON = #"{"status":"ok","models":["4p-x"]}"#

    // MARK: - probeCloud

    func testProbeInvalidURLNeverTouchesNetwork() async {
        CloudMockURLProtocol.reset(script: [])
        let result = await ProbeCloudAction.live(configuration: mockConfig)(baseURL: "not a url", key: "k")
        XCTAssertEqual(result, .invalidURL)
        XCTAssertTrue(CloudMockURLProtocol.captured.isEmpty)
    }

    func testProbeReturnsStatusAndModels() async {
        CloudMockURLProtocol.reset(script: [(200, keyJSON, [:]), (200, modelsJSON, [:])])
        let result = await ProbeCloudAction.live(configuration: mockConfig)(baseURL: "http://mock.test", key: "KEY")
        guard case .ok(let status, let models) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(status.plan, "pro")
        XCTAssertEqual(models?.map(\.id), ["4p-x"])
        XCTAssertEqual(CloudMockURLProtocol.captured.map(\.request.url?.path), ["/v3/key", "/v3/models"])
    }

    func testProbeKeepsStatusWhenModelsFail() async {
        CloudMockURLProtocol.reset(script: [(200, keyJSON, [:]), (500, #"{"error":"x"}"#, [:])])
        let result = await ProbeCloudAction.live(configuration: mockConfig)(baseURL: "http://mock.test", key: "KEY")
        guard case .ok(_, let models) = result else { return XCTFail("\(result)") }
        XCTAssertNil(models, "取不到清單要回 nil，呼叫端才會保留上一份")
    }

    func testProbeBadKeyIsFailedAndSkipsModels() async {
        CloudMockURLProtocol.reset(script: [(401, #"{"error":"bad key"}"#, [:]), (200, modelsJSON, [:])])
        let result = await ProbeCloudAction.live(configuration: mockConfig)(baseURL: "http://mock.test", key: "KEY")
        guard case .failed(let reason) = result else { return XCTFail("\(result)") }
        XCTAssertTrue(reason.contains("401"))
        XCTAssertEqual(CloudMockURLProtocol.captured.count, 1)
    }

    // MARK: - testCloudConnection

    func testConnectionWithoutKeyOnlyChecksHealth() async {
        CloudMockURLProtocol.reset(script: [(200, healthJSON, [:])])
        let result = await TestCloudConnectionAction.live(configuration: mockConfig)(
            baseURL: "http://mock.test", key: "  ")
        XCTAssertEqual(result, .healthOnly(status: "ok"))
        XCTAssertEqual(CloudMockURLProtocol.captured.count, 1)
    }

    func testConnectionWithKeyReturnsModelsAndKeyStatus() async {
        CloudMockURLProtocol.reset(script: [
            (200, healthJSON, [:]), (200, modelsJSON, [:]), (200, keyJSON, [:])])
        let result = await TestCloudConnectionAction.live(configuration: mockConfig)(
            baseURL: "http://mock.test", key: "KEY")
        guard case .ok(let status, let models, let key) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(status, "ok")
        XCTAssertEqual(models.map(\.id), ["4p-x"])
        XCTAssertEqual(key?.plan, "pro")
    }

    func testConnectionKeyStatusFailureDoesNotFailTest() async {
        CloudMockURLProtocol.reset(script: [
            (200, healthJSON, [:]), (200, modelsJSON, [:]), (500, #"{"error":"x"}"#, [:])])
        let result = await TestCloudConnectionAction.live(configuration: mockConfig)(
            baseURL: "http://mock.test", key: "KEY")
        guard case .ok(_, _, let key) = result else { return XCTFail("\(result)") }
        XCTAssertNil(key)
    }

    func testConnectionHealthOrModelsFailureIsFailed() async {
        CloudMockURLProtocol.reset(script: [(503, #"{"error":"down"}"#, [:])])
        let health = await TestCloudConnectionAction.live(configuration: mockConfig)(
            baseURL: "http://mock.test", key: "KEY")
        guard case .failed = health else { return XCTFail("\(health)") }

        CloudMockURLProtocol.reset(script: [(200, healthJSON, [:]), (401, #"{"error":"bad"}"#, [:])])
        let models = await TestCloudConnectionAction.live(configuration: mockConfig)(
            baseURL: "http://mock.test", key: "KEY")
        guard case .failed(let reason) = models else { return XCTFail("\(models)") }
        XCTAssertTrue(reason.contains("401"))

        let invalid = await TestCloudConnectionAction.live(configuration: mockConfig)(
            baseURL: "not a url", key: "KEY")
        guard case .failed = invalid else { return XCTFail("\(invalid)") }
    }

    // MARK: - startFullAuto

    func testStartFullAutoWritesPreferencesBeforeModeThenStarts() {
        let settings = SettingsStore()
        settings.fullAutoPrefersSanma = false
        settings.fullAutoRoomPreference = .lowest
        var events: [String] = []
        let action = StartFullAutoAction(
            settings: settings,
            setMode: SetAutoPlayModeAction(stub: { [unowned settings] mode in
                events.append("mode:\(mode.rawValue):\(settings.fullAutoPrefersSanma):\(settings.fullAutoRoomPreference.rawValue)")
            }),
            startNow: StartFullAutoNowAction(stub: { events.append("start") }))

        action(sanma: true, room: .highest)

        XCTAssertEqual(events, ["mode:全自動:true:highest", "start"])
        XCTAssertTrue(settings.fullAutoPrefersSanma)
        XCTAssertEqual(settings.fullAutoRoomPreference, .highest)
    }

    // MARK: - chooseServer

    private func makeChoose(_ settings: SettingsStore, switched: @escaping (MajsoulServer) -> Void) -> ChooseServerAction {
        ChooseServerAction(settings: settings, switchServer: SwitchServerAction(stub: switched))
    }

    func testChooseSameServerOnlyWritesSettings() {
        let settings = SettingsStore()
        settings.majsoulServer = .cn
        settings.pinMajsoulServer = false
        var switched: [MajsoulServer] = []
        makeChoose(settings) { switched.append($0) }(.cn, pin: true)

        XCTAssertTrue(switched.isEmpty, "區服相同不重載")
        XCTAssertTrue(settings.pinMajsoulServer)
        XCTAssertEqual(settings.majsoulServer, .cn)
    }

    func testChooseDifferentServerSwitchesAndStillWritesPin() {
        let settings = SettingsStore()
        settings.majsoulServer = .cn
        settings.pinMajsoulServer = true
        var switched: [MajsoulServer] = []
        makeChoose(settings) { switched.append($0) }(.jp, pin: false)

        XCTAssertEqual(switched, [.jp])
        XCTAssertFalse(settings.pinMajsoulServer, "換服時 pin 也要寫入（含關閉）")
    }
}

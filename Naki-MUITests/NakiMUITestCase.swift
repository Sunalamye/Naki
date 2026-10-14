import XCTest

/// 所有 iOS UI 測試的共同前置。
///
/// 啟動的 App 不是 test host：AutoPlayEngine 與 DebugServer 都會跑。runner 與 App 在模擬器上是
/// 不同 container，runner 寫 suite 到不了 App，所以模式、固定伺服器與語言走 argument domain
/// （`UserDefaults(suiteName:)` 也讀得到），啟動後再經 `/bot/status` 確認模式是「關閉」。
class NakiMUITestCase: XCTestCase {

    let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launchEnvironment["NAKI_UI_TEST_DEFAULTS_SUITE"] = "naki.tests.ui"
        app.launchEnvironment["NAKI_UI_TEST_KEYCHAIN_SERVICE"] = "org.naki.cloud-inference.uitest"
        app.launchArguments += ["-naki.autoPlayMode", "關閉", "-PinMajsoulServer", "YES", "-naki.appLanguage", "zh-Hant"]
    }

    override func tearDown() {
        app.terminate()
        super.tearDown()
    }

    func launch() {
        app.launch()
        var mode: String?
        _ = eventually(30) {
            mode = ((try? json("GET", "/bot/status"))?["autoPlay"] as? [String: Any])?["mode"] as? String
            return mode != nil
        }
        if mode != "關閉" {
            app.terminate()
            XCTFail("自動打牌模式不是「關閉」（\(mode ?? "讀不到 /bot/status")），已收掉 App")
        }
    }

    @discardableResult
    func json(_ method: String, _ path: String, body: String? = nil) throws -> [String: Any] {
        var request = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1:8765\(path)")))
        request.httpMethod = method
        request.timeoutInterval = 5
        request.httpBody = body.map { Data($0.utf8) }
        let done = DispatchSemaphore(value: 0)
        var result: Result<Data, Error> = .failure(URLError(.unknown))
        URLSession.shared.dataTask(with: request) { data, _, error in
            result = error.map { .failure($0) } ?? .success(data ?? Data())
            done.signal()
        }.resume()
        done.wait()
        return try XCTUnwrap(JSONSerialization.jsonObject(with: result.get()) as? [String: Any])
    }

    func eventually(_ timeout: TimeInterval = 5, _ condition: () throws -> Bool) rethrows -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if try condition() { return true }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        return false
    }
}

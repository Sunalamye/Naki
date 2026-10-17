//
//  IsolatedDefaults.swift
//  NakiTests
//
//  `removePersistentDomain` 不刪檔，且 cfprefsd 的非同步寫入會在刪檔後把空殼補回來。
//  每個測試結束刪一次，整包測試結束再掃一次本次建過的 suite。
//

import Foundation
import XCTest

private let preferencesDirectory = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Preferences")

private func removePlist(_ name: String) {
    try? FileManager.default.removeItem(at: preferencesDirectory.appendingPathComponent("\(name).plist"))
}

private func removeDomain(_ name: String) {
    guard let defaults = UserDefaults(suiteName: name) else { return }
    defaults.removePersistentDomain(forName: name)
    defaults.synchronize()
}

private final class SuiteSweeper: NSObject, XCTestObservation {
    private let lock = NSLock()
    private var names: Set<String> = ["naki.tests.host"]

    func track(_ name: String) {
        lock.lock()
        names.insert(name)
        lock.unlock()
    }

    func testBundleDidFinish(_ testBundle: Bundle) {
        lock.lock()
        let tracked = names
        lock.unlock()
        tracked.forEach(removeDomain)
        for _ in 0..<3 {
            Thread.sleep(forTimeInterval: 0.3)
            tracked.forEach(removePlist)
        }
    }
}

private let sweeper: SuiteSweeper = {
    let sweeper = SuiteSweeper()
    XCTestObservationCenter.shared.addTestObserver(sweeper)
    return sweeper
}()

func removeIsolatedSuite(_ name: String) {
    guard name.hasPrefix("naki.tests.") || name.hasPrefix("naki.test.") else {
        XCTFail("拒絕清理非測試 suite：\(name)")
        return
    }
    sweeper.track(name)
    removeDomain(name)
    removePlist(name)
}

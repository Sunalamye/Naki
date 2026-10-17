# 插件來源顯示 implementation notes

## 做了什麼
- `PluginDescriptor.sourceURL`：`PluginRegistry.load` 讀 `install-receipt.json` 的 `sourceURL`；缺檔、壞 JSON、非 http／https、無 host 一律 nil。
- 詳情頁 id/version 下新增來源列：有 URL 顯示 `Link`（host＋path，完整 URL 在 `.help`），否則「手動安裝」；macOS 加「在 Finder 中顯示」，iOS 顯示 `Plugins/<id>` 唯讀文字。
- 新 Action `RevealPluginDirectoryAction`（`.live` 呼叫 `NSWorkspace.activateFileViewerSelecting`，iOS 為空操作），View 不直接碰 NSWorkspace。
- 字串三條進 `Localizable.xcstrings`（四語系）。

## 驗證
- `PluginSourceReceiptTests` 4 個；停用 `sourceURL` 賦值時有效案例紅，還原後綠。
- 全量 NakiTests 1163 通過、0 failures；macOS 與 iOS（iPhone 17 模擬器）build 通過。
- `xcstrings-gate.py`（404 keys）與 `ui-token-gate.sh` 通過。
- 畫面未驗證（不碰執行中的 Naki，未做 Preview 截圖）。

## Deviations
- 另改 `command/App/NakiRuntime.swift` 一行（`makeActions` 接上 `revealPluginDirectory: .live`），Action 注入必經之處。
- `load` 拆出 `parse(directory:)`：避免改動 5 個 `PluginDescriptor` 回傳點，`sourceURL` 以有預設值的 `var` 在 `load` 補上。

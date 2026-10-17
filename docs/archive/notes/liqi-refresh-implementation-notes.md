# liqi-refresh implementation notes

目標：`docs/protocol/liqi.json` 改由雀魂官方 Unity 資源包抽出，`scripts/check-liqi-drift.sh` 改比對同一條管線。

## 做法

- `scripts/extract-liqi.py` 有三個子命令。`fetch` 下載並解包（需要 UnityPy）。`build` 做純轉換，不連網。`diff` 比較型別、欄位與 RPC。
- 管線比照 Akagi v3 的 `scripts/extract_liqi.py`。Lua 屬性解析容許等號兩側有空白，因為 `com_const_pb.lua` 沒有壓縮。
- 輸出沿用舊檔格式：protobufjs nested，區塊依舊檔的模組順序排，欄位型別寫成從所在範圍可解析的最短名稱。
- `diff` 先把型別解析成完整路徑再比，所以 `lq.X` 與 `X` 這類寫法差異不算變動。

## 驗證

- 與 Akagi v3 `liqi.proto` 比對：1390 個型別逐欄相同，443 個 RPC 相同。
- protobufjs 7.4.0 `resolveAll()` 通過。`ReqSelfOperation` 的編碼與舊檔相同。
- 三次獨立下載，原始檔與輸出逐位元組相同。
- drift 腳本的三條路徑都跑過：一致時退出 0，不一致時退出 1，`--update` 之後再跑退出 0。
- 證據放在主 repo 的 `.swfd/logs/liqi-refresh/`。

## Deviations

- **不輸出 `options.go_package`。** 舊檔的這個值來自舊 `.proto`，Lua descriptor 沒有這項資訊。保守選擇是不捏造。Naki 沒有任何程式讀它。
- **只走 DXT profile。** Akagi 先試 ASTC。DXT 是任務指定的官方索引，而且實測可用。ASTC 失效時不會自動退回，腳本會直接失敗。
- **drift 腳本不再需要 Naki 在跑。** 舊版靠 App 取 CDN manifest，新版直接讀公開靜態資源。用法與退出碼不變。
- **Swift 註解未改。** `LiqiOperationStore.swift` 檔頭仍寫「schema 基準本身過期」。本包不得改 Swift，所以留給後續處理。

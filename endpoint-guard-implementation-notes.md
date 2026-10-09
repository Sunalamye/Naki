# endpoint-guard implementation notes

## 目標
雲端推論的伺服器 URL 不可指向雀魂網域：牌局資料與 API key 送去那裡是填錯。設定階段擋下並在畫面說明原因。

## 改動
- `command/Services/Bot/AkagiApiClient.swift`：新增 `forbiddenDomains` 與 `isForbiddenHost`；`init?` 對雀魂網域回 nil。
- `command/Services/Bot/CloudInferenceConfig.swift`：`isActive` 加 `!isForbiddenHost`；`missingItems` 多一項「伺服器 URL 不可為雀魂網域」。
- `command/Resources/Localizable.xcstrings`：新增該字串。
- `NakiTests/CloudInferenceTests.swift`：禁止／允許清單、非 http scheme、normalize 冪等。

## 設計
- 判斷放 `AkagiApiClient`：`init?` 是唯一建立連線的入口，config 與 client 共用同一個判斷，不會漂開。
- `isActive` 與 `missingItems` 互斥：雀魂網域時 `isActive` 為 false，且 `missingItems` 恰有該項，畫面不會同時顯示「已啟用」與缺項。
- host 比對：小寫、去尾端一個或多個 `.`、等於網域或以 `.網域` 結尾；以 `URL.host` 解析，userinfo 與 path 內的網域字樣不影響。

## codex 審查後的修正
- 尾點繞過：`maj-soul.com.` 原本不被擋，現在去尾點後比對。
- 移除冗餘的 `game.maj-soul.net`（已被 `maj-soul.net` 涵蓋）。
- 補測試：尾點、userinfo 在前（擋）、userinfo 內含雀魂但真 host 為他站（放行）、normalize 冪等。

## Deviations
- `isActive` 不涵蓋「非法 URL／非 http scheme」，那個狀態只有 `init?` 會擋。這是既有語意，本工作包不改。

## 未驗證
- 網域清單是否完整（只含已知雀魂／Yo-Star 網域）。
- UI 上缺項文字的實際顯示未實機看。

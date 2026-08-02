# Naki 文件索引

**最後核對**：2026-08-01  
**原則**：本索引只列目前可用的文件；Laya、DesktopMgr、座標點擊與過渡期調查不再提供入口。

## 先看哪一份

| 需求 | 文件 |
|------|------|
| Unity、Liqi、Mortal、自動打牌、自摸與高亮的 current truth | [majsoul-unity-protocol.md](majsoul-unity-protocol.md) |
| Naki Swift／JS 元件與資料流 | [architecture-deep-dive.md](architecture-deep-dive.md) |
| 當前 `lqc.lqbin` 下載、hash 與解析結果 | [majsoul-config-tables.md](majsoul-config-tables.md) |
| MCP 工具清單與安全用法 | [mcp-server-guide.md](mcp-server-guide.md) |
| HTTP Debug API | [debug-api-help-endpoint.md](debug-api-help-endpoint.md) |
| Liqi field schema | [protocol/liqi.json](protocol/liqi.json) |
| Shell 工具約定 | [shell-tools-guide.md](shell-tools-guide.md) |

Repo 根目錄另有：

- [`README.md`](../README.md)：使用者導向的產品說明。
- [`CLAUDE.md`](../CLAUDE.md)：agent 操作邊界與 current facts。
- [`AUDIT.md`](../AUDIT.md)：目前驗證差距與完成判準。
- [`RELEASE.md`](../RELEASE.md)：release 流程。

## Current baseline

- 雀魂 live client：Unity WebGL `chs_t-WebGL-release-4.0.45(45)`。
- 狀態與動作：Liqi protobuf；Laya globals 不存在。
- AI：本機目前 resolve MortalSwift 0.5.0，但 bundled 權重未更新，沒有「最強」benchmark。
- 四麻：有固定 parity fixtures；三麻沒有專用模型。
- 自摸：resolver 單測已通過，但 integration 仍有 recommendation gate 與 send-result 兩個 P0。
- MCP：live `tools/list` 為 42。
- 配置：2026-08-01 live manifest fresh parse 為 41 tables／263 sheets／119,289 rows。

## 文件維護規則

1. 先以 Naki loopback API 或當前程式碼查證，再更新文件。
2. runtime 事實附日期與 client／resource version。
3. 「sendRaw 成功」「server RESPONSE」「權威 action」分三層描述。
4. 單元測試、live 對局、視覺驗收與牌力 benchmark 不互相替代。
5. 被 current code 推翻的內容直接移除；歷史需要時從 git history 取回，不在 active docs 內保留兩套說法。

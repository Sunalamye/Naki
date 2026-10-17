# wp5-kan-select implementation notes

## 結論
協定 selector 的語意（`index`／`tile` 對暗槓、加槓代表什麼）在 repo 內沒有 runtime 證據，依計畫第 5 步不做修正，只交調查與 live 抓包需求。

## 協定事實
- `ReqSelfOperation` 有 `index`(2)、`tile`(3)；`ReqChiPengGang` 只有 `index`(2)，沒有 `tile`（`docs/protocol/liqi.json`）。
- `OptionalOperation` 的候選欄位是 `combination`（repeated string）；暗槓 type=4、大明槓 type=5、加槓 type=6 是各自獨立的 operation（`LiqiOperationStore.swift:43-48`、`:121`）。
- 三種槓 runtime 全標「未驗證」（`docs/majsoul-unity-protocol.md:153-155`、`:162`）。
- `index` = combination 序號只寫在吃的註解（`LiqiRequestBuilder.swift:222`），吃本身也未驗證。
- 未知：槓的 combination 字串格式；`index` 是 operation 內 combination 序號還是跨 operation 序號；`tile` 何時必要、與 `index` 誰優先；暗槓＋加槓並存時伺服器怎麼處理只帶 type 的請求。

## Naki 現況
- executor 只帶 type，type 取 `kanOperation`，優先序暗槓 → 加槓 → 大明槓（`AutoPlayActionExecutor.swift:117-120`、`LiqiOperationStore.swift:184-189`）。
- MCP 路沒有「計算」index／tile，是呼叫端傳入的參數，缺省 index=0（`GameTools.swift:100-103`、`MCPContext.swift:81-84`）。
- bot 建議不帶要槓哪張：本地 Mortal 只給 `kan`（`MortalActionMapper.swift:167-168`）；雲端與三麻只把 consumed 放進顯示字串 `detail`，並把 ankan／kakan／daiminkan 合併成 `.kan`（`CloudDecisionMapper.swift:86-89`、`AkagiSanmaBot.swift:150-151`）。

## live 抓包需求
- 同時可兩個加槓、加槓＋暗槓並存時，伺服器下發的 `OptionalOperationList` 原始 bytes（看 combination 字串）。
- 原生客戶端點選第二個候選時送出的 `inputOperation` payload（看 index／tile 帶哪個）。
- 對應的 `ActionAnGangAddGang.tiles` 回音，確認槓到哪張。

## Deviations
- 未做第 4 步修正，沒有改程式碼，因此沒跑 xcodebuild 與變異測試（保守選項：不在語意未知時改送出行為）。

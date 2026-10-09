# Naki（鳴き）

[繁體中文](README.md) | [English](README.en.md) | **日本語**

**雀魂の AI 雀友。ネイティブ macOS / iOS アプリで、開けばすぐ使えます。**

<p align="center">
  <img src="docs/images/macos-decision.png" width="760" alt="Naki macOS 画面">
</p>

<p align="center">
  <a href="https://github.com/Sunalamye/Naki/releases/latest"><img src="https://img.shields.io/badge/version-2.16.0-green" alt="Version 2.16.0"></a>
  <img src="https://img.shields.io/badge/macOS-26.0+-blue" alt="macOS">
  <img src="https://img.shields.io/badge/iOS-17.0+-blue" alt="iOS">
  <img src="https://img.shields.io/badge/Apple%20Silicon-required-red" alt="Architecture">
  <img src="https://img.shields.io/badge/license-AGPL--3.0-lightgrey" alt="License">
</p>

<p align="center">
  <a href="https://github.com/Sunalamye/Naki/releases/latest"><b>ダウンロード</b></a> ·
  <a href="#クイックスタート"><b>クイックスタート</b></a> ·
  <a href="#できること"><b>できること</b></a> ·
  <a href="#開発者向け"><b>開発者向け</b></a>
</p>

---

> ## ⚠️ 最初にお読みください
>
> 本プロジェクトは**学習・研究目的のみ**です。使用すると雀魂の利用規約に違反し、アカウントが凍結される可能性があります。
>
> **メインアカウントでは使用しないでください。** 作者はいかなる損害についても責任を負いません。使用を続けることは、このリスクを受け入れたものとみなします。

---

## これは何か

「鳴き」は日本麻雀の用語で、チー・ポン・カンなどの副露アクションを指します。このアプリは、鳴くべきところで「鳴け」と教えてくれます。

Naki は雀魂と麻雀 AI をひとつのウィンドウにまとめました。**Python、Docker、ブラウザ拡張、プロキシサーバーは不要**です。
ダウンロードして、開いて、ログインするだけで、AI の推奨がゲーム画面の上にそのまま重なります。

推論エンジンは [Mortal](https://github.com/Equim-chan/Mortal) で、Core ML 経由で Apple Neural Engine 上で動きます。
**デフォルト**ではモデルも計算もすべてローカルで行い、外部の推論サービスは呼び出しません。ただし雀魂のゲーム自体にはネットワーク接続が必要です。

サンマ（三麻）は独立したローカルエンジンが処理します（Akagi v3 のサンマ行動クローンモデルで、**default strength、天鳳の人間を模倣したもので、Mortal 級ではありません**）。
詳しくは〈サンマについて〉をご覧ください。

さらに、[Akagi](https://github.com/shinkuan/Akagi) のクラウド推論サーバーを**オプションで**接続し、
より強力なホスト型モデル（本物のサンマモデルを含む）で判断させることもできます。デフォルトはオフです。詳しくは下記〈クラウド推論〉をご覧ください。

---

## できること

<table>
<tr>
<td width="52%">

### 推奨が牌にそのまま表示される

サイドバーを見てから牌を探し直す必要はありません。AI の提案はゲーム画面上に表示され、サイドバーには詳細な分析も同時に出ます。

- サイドバーは上から下へ判断の順序どおり：最善手 → その他の選択肢 → 対局の詳細（折りたたみ可）
- 牌面は本物の牌画像で、赤五には専用の画像があります
- 打牌 / チー / ポン / カン / リーチ / 和了 / 北抜き / 九種九牌に対応（九種九牌は live 未検証）

</td>
<td width="48%">
<img src="docs/images/macos-details.png" width="100%" alt="対局とモデル情報を展開した画面">
</td>
</tr>
<tr>
<td width="52%">
<img src="docs/images/ios-decision.png" width="100%" alt="iPhone 横向き：卓が全高、右側に判断パネル">
</td>
<td width="48%">

### Mac でも iPhone でも使える

- **macOS** — 判断サイドバー。自動送信と局間の自動確認に対応
- **iPhone / iPad** — 卓が画面の全高を使い、操作と判断は右側の常駐パネルに収まります
- ダークモード、レスポンシブレイアウト

横向き iPhone のボトルネックは**高さ**です。雀魂は 16:9 の等比スケーリングで表示されるため、高さに合わせると左右に
もともと黒帯ができます。ナビゲーションバーの高さを卓に返し、パネルを黒帯だった幅に置くことで、
「ナビゲーションバーあり・パネルなし」のときよりも卓が大きくなります。

</td>
</tr>
<tr>
<td width="52%">

### 対局の詳細は同じ欄にまとめて収納

サマリーバーを開くとこの層が現れます：サーバーが現在許可しているアクション、4 家の持ち点、ドラ表示牌、
この一手の判断がローカルかクラウドか。折りたたんでいるときは 1 行しか使いません。

</td>
<td width="48%">
<img src="docs/images/ios-details.png" width="100%" alt="iPhone：対局とモデル情報を展開した画面">
</td>
</tr>
</table>

<sub>iPhone のスクリーンショットは iOS 26 シミュレーターの実画面です。プレイヤー名は、アプリ内蔵の「プレイヤー名を隠す」効果が適用されています。</sub>

### 雀魂の 3 つのサーバー、起動時に選択

中国サーバー（国服）、日本サーバー（日服）、国際サーバー。**デフォルトでは起動のたびに確認します**。サーバーごとにアカウントは共通ではなく、選び間違えると
画面が違うのではなくログインできません。「今後はこのサーバーを使う」にチェックすると確認しなくなります。詳細設定でいつでもサーバーを切り替えられ、固定を解除して
毎回確認する状態に戻すこともできます。

<table>
<tr>
<td width="50%">
<img src="docs/images/server-picker-macos.png" width="100%" alt="macOS：雀魂サーバーの選択">
</td>
<td width="50%">
<img src="docs/images/server-picker-ios.png" width="100%" alt="iPhone：雀魂サーバーの選択">
</td>
</tr>
</table>

<sub>3 つのサーバーは同じクライアントを動かしています（実測で <code>version.json</code> はすべて <code>0.11.252.w</code>）。
そのためプロトコルは共通で、Naki はサーバーごとに別のパースを用意する必要がありません。</sub>

### 4 つのモード、いつでも切り替え

| モード | 動作 |
|:---:|-----|
| **オフ** | アクションを自動送信せず、推奨も表示しません（サイドバーには「推奨表示はオフです」と表示され、ゲーム内のハイライトも消えます）。AI はバックグラウンドで計算を続けるため、戻すとすぐに結果が出ます |
| **推奨** | 提案を表示し、判断はあなたが行います |
| **自動** | AI／サーバーの oplist に従って自動送信し、局間の精算も自動で確認して次の局へ進みます（`confirmNewRound`）。対局中、手動でクリックする必要はありません |
| **全自動** | 自動に加えて、対局終了後に次の対局を自動でキューに入れます。自動とは別に許可が必要です。アカウントを自分からサーバーのキューへ並ばせるためです |

自動と全自動は、自動送信に対応したプラットフォーム（macOS / iOS 26+）のみです。iOS 17–25 はオフと推奨だけです。モードは記憶され、アプリを再起動してもリセットされません。ツールバーには**遅延基準**のステッパー（0.5–3.0s）もあります：
これは人間らしい遅延のランダム分布に掛けるスケール係数です（1.0s＝現行の挙動、大きいほど遅く、小さいほど速くなります）。
テンポを固定値にはしません（固定のテンポは検出されやすいため）。

### クラウド推論（オプション）

詳細設定 →「クラウド推論」：API key を貼り付けると、各判断ポイントで**この局のここまでの
対局イベント（自分の手牌を含む）**が推論サーバー（デフォルトは Akagi 公式の
`mjapi.shinkuan.me`、自前で立てることも可能）へ送信され、より強力なモデルの判断が返ってきます。

- **デフォルトはオフ**で、オフのときの挙動は純ローカル版とまったく同じです。key は自分で入手します
  （アプリには購入・引き換えの導線を意図的に含めていません）。**Keychain** に保存され、log には末尾 4 桁だけが出ます
- ローカルモデルは常に待機しています：サーバーのタイムアウト・レート制限・切断時には**自動的にローカルの判断へ戻り**
  （指数バックオフのサーキットブレーカー 5s→120s）、対局が止まることはありません。各手の判断元
  （`local` / `cloud:<モデル>`）は、サイドバーと `/bot/status` にそのまま表示されます
- 有効な間、サイドバーには**「対局データの送信先 \<host\>」が常に表示されます**。送信されるのは対局イベントです。
  受け入れるかどうかは各自でご判断ください
- **失敗時にはサイドバーが赤い警告に変わります**：「クラウド失敗――ローカルモデルを使用中（連続 N 手）」。劣化中に小さな文字だけで気づかせるわけにはいかないため、連続手数も併せて表示します。
  `/bot/status` には `cloudDegraded`／`cloudFallbackStreak` という機械可読の項目もあります
- **キーの状態を自動で照会**：key を入力すると、設定画面が自動で `/v3/key` を呼び出し、
  **プラン、有効期限、残り日数、本日の使用量**（`1683 / 6000` のような形式）を表示します。手動でテストを押す必要はありません。
  key を打ち間違えた場合はその場で読み取れないことが表示されます。対局が終わるまで気づかずにずっとローカルを使い続けることはありません
- 「接続テスト」ボタンも引き続きあり、サーバーと key を検証して、あなたのプランで使えるモデル
  （サンマ 3p モデルを含む）を一覧にします。モデル欄の横のドロップダウンから直接選べます
- ツールバーには**クラウドスイッチ**があり、対局中でもいつでもローカルに戻せます。アイコンは実際に有効な状態を反映します
  （有効／オンだが条件不足／オフの 3 状態でそれぞれ別のアイコン）
- 対局中に key やモデルを変更しても即座に反映され、対局を再開する必要はありません
- サンマも同様に**クラウド優先、ローカルが引き継ぎ**：クラウドがタイムアウトまたは失敗したときは、ローカルの Akagi サンマエンジンが判断します
- `scripts/cloud-watch.sh`（任意）はバックグラウンドで event log を監視し、同期ずれ／失敗／
  watchdog による再接続／送信の停滞が起きると **macOS 通知を出します**。log を自分で見張る必要はありません

<p align="center">
  <img src="docs/images/settings.png" width="760" alt="詳細設定">
</p>

詳細設定は 2 列に分かれています。左はこのマシンの動かし方（画面、自動操作、Bot、MCP Server）、
右はクラウド推論です。キーの状態は key を入力すると自動で表示され、接続テストを押す必要はありません。

<sub>macOS の設定画面の画像はデザイン案（`docs/ui-reference/`）です。アプリ内のスクリーンショット API では sheet の完全な描画を取得できません。
`CaptureScreenshotAction.windowScreenshot` のコメントを参照してください。</sub>

iPhone は同じ設定フォームの 1 列版です（狭い画面には 2 列が収まりません）：

<table>
<tr>
<td width="50%">
<img src="docs/images/ios-settings-general.png" width="100%" alt="iPhone 詳細設定：自動操作と画面">
</td>
<td width="50%">
<img src="docs/images/ios-settings-cloud.png" width="100%" alt="iPhone 詳細設定：クラウド推論">
</td>
</tr>
</table>

「ステータスメッセージ行を表示」は、卓の下部に出るフローティングメッセージ（接続状態、自動送信されなかった理由など）を制御します。
**デフォルトはオフ**です。卓の上に重なる上、内容の多くは一度きりのフィードバックや診断出力だからです。
放っておいても直らない本当のエラーは上部のバナーに出るため、このスイッチの影響を受けません。

クラウド関連の検証の進捗は [`AUDIT.md`](AUDIT.md) §20 と
[`docs/cloud-inference-plan.md`](docs/cloud-inference-plan.md) に記録されています。

### その他

- **プロトコル層のスタンプツール** — MCP からスタンプを送信し、受信したブロードキャストを読み取れます。旧来の自動返信の経路は Unity では使えません
- **プレイヤー名を隠す** — 詳細設定のスイッチで、2 つの層が一緒に働きます：
  - **プロトコル層** ゲームがパケットを解析する前に、ニックネームを `Player 1`–`Player 4` に書き換えます。オンにした後に
    始まった対局にのみ有効です
  - **レンダリング層**（2.8.0 で追加）はゲーム画面上の名前を直接非表示にし、**スイッチを入れた瞬間に有効**になります。次の局を待つ必要はありません。
    Unity クライアントにはフックできる UI 層がないため、自己キャリブレーションで名前の層を見つけます：オンにすると 1 つずつ隠してみて
    画面を比較し、「隠すと 4 家の位置が同時に変化し、かつ変化するピクセルが非常に少ない」ものを選びます。見つけられなければ何も隠さず、
    他の UI を誤って隠すことはありません
- **MCP Server** — Claude Code などの AI アシスタントからゲームを直接操作できます
- **ローカル Debug API** — loopback のみにバインドされ、同じネットワークの他のデバイスからは接続できません

---

## クイックスタート

### システム要件

| プラットフォーム | バージョン | アーキテクチャ |
|-----|------|-----|
| **macOS** | **26.0+** | Apple Silicon |
| **iOS / iPadOS** | 17.0+ | A12 以上 |

> **なぜ Apple Silicon が必要なのか**
> AI モデルは Apple Neural Engine 上で動きます。これは Apple Silicon 固有のハードウェアで、Intel Mac にはありません。

> **iOS 17–25** は `WKWebView` の Legacy 経路を使い、**iOS 26+** は新しい `WebPage` API を使います。
> 両経路の判断層は現在同じです（同一の resolver）。ただし Legacy は**推奨の表示のみで、自動送信はしません**
> （自動と全自動は推奨に格下げされます）。実機での完全な対局もまだ行っていません。自動モードを使うには macOS／iOS 26+ をご利用ください。

### インストール

1. [Releases](https://github.com/Sunalamye/Naki/releases/latest) からダウンロードします：
   - macOS：`Naki.dmg`（開いて「アプリケーション」へドラッグ）または `Naki.zip`（展開して「アプリケーション」へ移動）
   - iPhone / iPad：`Naki-M.ipa`（自分で署名して sideload）
2. macOS 版は公証されておらず、IPA は未署名です：初回起動時に「システム設定」での承認が必要になる場合があります。提供元が信頼できるバージョンだけを承認してください

### 使い方

1. Naki を開くと、雀魂が自動で読み込まれます
2. アカウントにログインします（**サブアカウントを使ってください**）
3. 対局を始めると、推奨がリアルタイムで表示されます
4. サイドバーで使いたいモードを選びます

---

## 開発者向け

<details>
<summary><b>アーキテクチャ：なぜゲーム画面を操作しないのか</b></summary>

```
┌──────────────────────────────────────────────────────────┐
│              WebPage（雀魂 · Unity WebGL）                │
│                          │                               │
│    JavaScript は 2 つだけ：WebSocket の送受信、牌の着色     │
│              naki-core / naki-websocket                  │
└──────────────────────────┼───────────────────────────────┘
                           ▼
┌──────────────────────────────────────────────────────────┐
│                      Swift サービス層                      │
│                                                          │
│  MajsoulBridge  →  NativeBotController  →  LiqiActionSender
│   (Liqi→MJAI)      (純 Swift + Core ML)      (パケット組立・送信)
│                           │                              │
│   AutoPlayEngine（単一 Task ループ：ゲート→遅延→再試行） │
│      AutoPlayDecisionResolver（合法性とモードのゲート）     │
│                           │                              │
│              GameStore  ←→  SwiftUI Views / MCP          │
└──────────────────────────────────────────────────────────┘
```

現在の雀魂クライアントは Unity WebGL で、ゲームロジックと描画は wasm の中にあります。
JavaScript からはゲーム内部のオブジェクトに触れません。そのため Naki は一貫して**プロトコル層**を使います：
状態は WebSocket パケットから解析し、アクションは自分で protobuf を組み立てて送信します。

プロトコルのフィールド定義は**ゲーム自身が公開しているリソースファイル** `res/proto/liqi.json` から取得したもので、クライアントの逆アセンブルで得たものではありません。

画面のハイライトは、WebGL の描画呼び出しを横取りし、atlas UV から牌の種類を識別して、その draw の色パラメータを一時的に書き換える方式です。
画面座標には依存しません。ただし現時点で確認できているのは hook が実行されることだけで、毎回正しい牌とボタンに当たることは screenshot regression ではまだ証明していません。

**合法性はサーバーが決めるものであり、モデルが決めるものではありません。** macOS／iOS 26+ の主経路にはすでに resolver があります：
oplist がなければ fail closed、和了は AI に優先し、その他のアクションは同じ oplist に存在しなければなりません。
先に挙がっていた 2 つの統合上の欠落（空の推奨のせいでツモが resolver に入らない可能性、hora の send が失敗しても handled になる問題）は
ソース層で解消しました。`AutoPlayGate` は推奨が空でも oplist に和了があれば forceHora を行い、
送信成功後にだけ markHandled し、注入式 fixture でカバーしています。**ただし CLAUDE.md が求める敵対的な
live fixture（server `[1,7,8]` + AI が discard を選ぶ → resolver が hora に上書き → RESPONSE →
`ActionHule`）はまだ live で再現できていないため、「ツモ和了の見逃しが完全になくなった」とは主張しません。** Legacy の iOS 17–25
も同じ resolver に接続済みですが、こちらも実機での検証がありません。

技術的な詳細：[`docs/majsoul-unity-protocol.md`](docs/majsoul-unity-protocol.md) ·
[`AUDIT.md`](AUDIT.md)

</details>

<details>
<summary><b>Debug API（HTTP、port 8765）</b></summary>

アプリを起動すると、ローカルに HTTP server が立ち上がります。`requiredInterfaceType = .loopback` で、
127.0.0.1 / ::1 のみにバインドされます。

```bash
# Bot の状態、手牌、推奨
curl http://localhost:8765/bot/status

# プロトコル層で現在利用可能な操作（チー/ポン/カン/リーチ…）
curl http://localhost:8765/bot/ops

# 自動打牌を手動で 1 回トリガー
curl -X POST http://localhost:8765/bot/trigger

# 指定した画面を直接開く、言語を切り替える（DEBUG ビルド専用、Release にはありません）
curl -X POST http://localhost:8765/debug/ui -d '{"screen":"settings","language":"en"}'

# ゲームページで JS を実行（⚠️ 戻り値を得るには必ず return を使うこと）
curl -X POST http://localhost:8765/js -d 'return window.location.href'
```

`/status` はログファイルのパスを返します。過去のログは直近 8 回の起動分のディレクトリを丸ごと保持し、それより古いものは対局の録画（`games/`）だけを残します。

</details>

<details>
<summary><b>MCP Server（Claude Code 連携）</b></summary>

[Model Context Protocol](https://modelcontextprotocol.io/) server を内蔵しており、
Debug API と同じ port を共有します。プロトコルは **2026-07-28（stateless）** に更新され、従来の
`initialize` handshake とも互換です：ツールの結果は `structuredContent` で返り（「JSON を JSON 文字列に包む」形式ではなくなりました）、
loopback 以外の Origin には 403 を返します。ツール数は `tools/list` または `get_status.toolsCount` でその都度確認してください
（2.7.0 では静的に 40 個を登録。旧ハイライトの失敗スタブ 6 個は削除済み）。

```bash
claude mcp add --transport http naki http://localhost:8765/mcp
```

| カテゴリ | 数 | 例 |
|-----|:---:|------|
| システム | 6 | `get_status` · `get_logs` · `replay_game` |
| Bot 制御 | 7 | `bot_status` · `bot_ops` · `bot_trigger` |
| ゲーム状態とアクション | 8 | `game_state` · `game_action` · `game_confirm_new_round` |
| ロビー | 8 | `lobby_start_match` · `lobby_account_info` |
| 友人戦 | 7 | `room_create` · `room_add_robot` · `room_quick_test` |
| スタンプ | 2 | `game_emoji` · `game_emoji_listen` |
| その他 | 2 | `execute_js` · `lobby_anti_idle` |

`room_quick_test` は「部屋を作る → CPU を補充 → 開始」を一度に実行します。担当するのはテスト用の対局を作ることだけで、
クライアントの再接続、AI のアクション、RESPONSE、権威ある action は別途検証が必要です。
`game_vote_game_end`（投票による対局中止）は破壊的な操作のため、手動での呼び出しのみを提供し、どの自動経路にも接続していません。

</details>

<details>
<summary><b>自分でビルドする</b></summary>

Xcode 26 以上が必要です。

```bash
git clone https://github.com/Sunalamye/Naki.git
cd Naki
xcodebuild build -project Naki.xcodeproj -scheme Naki
xcodebuild test  -project Naki.xcodeproj -scheme Naki -only-testing:NakiTests
```

**実際に対局するときは Release ビルドを使ってください。** Core ML と期待値の計算は最適化設定の影響を受けます。
今回の棚卸しではレイテンシのベンチマークを再実行していないため、以前の固定ミリ秒の数値は残していません。
Xcode では `Product → Scheme → Edit Scheme → Run → Build Configuration` で変更できます。

</details>

---

## 現況

| 機能 | 状態 |
|---|---|
| AI 推奨（四麻） | 利用可 |
| AI 推奨（サンマ） | ローカルで利用可（default strength）、下記参照 |
| 全自動打牌 · 局間の自動確認 | 利用可（macOS / iOS 26+） |
| 全自動（対局終了後に次の対局を自動でキューへ） | 実装済み、独立した選択モード（macOS / iOS 26+） |
| ゲーム内の牌ハイライト | 利用可 |
| クラウド推論（オプション） | 利用可。四麻は live 検証済み、サンマのクラウドモデルは live 対局なし |
| プレイヤー名を隠す | 利用可（プロトコル層 + レンダリング層） |
| MCP Server · Debug API | 利用可 |
| iOS 17–25 | 推奨の表示のみ、自動送信なし |
| 牌譜リプレイ分析 | 未着手 |

項目ごとの検証の程度と既知の欠落は [`AUDIT.md`](AUDIT.md) に記録されています。

### サンマについて

**サンマは独立したローカルエンジンを使い、四麻のモデルは流用しません。** 内蔵の四麻 Mortal モデルはサンマには触れません。
observation のレイアウトが異なるため、それでサンマを推論するのは構造的に無効です。サンマは `AkagiSanma` を経由します
（[MortalSwift](https://github.com/Sunalamye/MortalSwift) 0.6.0 に含まれる純 Swift の移植で、
Akagi v3 のサンマ行動クローンモデル、Apache 2.0。37×27 の observation、60 のアクション）。

- **強度は default strength**：天鳳の人間の打ち方を模倣したもので、**Mortal 級ではありません**。四麻の推奨と強さを比べないでください。
  サイドバーのモデル名もそのように表示されます
- クラウドが有効なときはクラウド優先でローカルが引き継ぎ、クラウドが無効のときはローカルエンジンそのものです。エンジンの構築に失敗した場合にだけクラウド専用に戻ります
- 合法なアクションはサーバーの oplist が許可します：和了は形だけを見て、役はサーバーが決めます。oplist がない場合は打牌とパスだけが残ります
- サンマの友人戦にはサンマ用のルール（赤ドラ 2、持ち点 35000、返し 40000）を付ける必要があり、付けないとサーバーが error 1112 を返します。
  `room_quick_test` の `player_count=3` では自動で付与されます
- 北抜き：ツモったばかりの北には `moqie` が付きます。切断時は直ちに手を止めて停滞を表示し、再接続までバックオフしながらリトライします

**live 検証（2026-10-09、CPU 戦 3 試合）**：ローカルエンジンによる判断、リーチ、和了、ポン、北抜き 11/11
（ツモったばかりの北を含む）の経路が完全に通りました。**未検証**：他の端末からのログインで切断された後のバックオフと停滞表示、親番の最初の打牌で時折起こる再送
（3 回、原因不明）、iOS 実機。詳細は [`AUDIT.md`](AUDIT.md) と
[`sanma-implementation-notes.md`](sanma-implementation-notes.md) をご覧ください。

---

## 謝辞

- [Mortal](https://github.com/Equim-chan/Mortal) — 麻雀 AI エンジンと libriichi
- [Akagi](https://github.com/shinkuan/Akagi) — 参考実装、および（オプションの）クラウド推論サーバーと `/v3` プロトコル。
  サンマのローカルエンジンは、その v3 ブランチのサンマ行動クローンの重みと、移植した tile／obs／action のロジックを使用しています（Apache 2.0、
  ライセンス全文は MortalSwift の `Sources/AkagiSanma/LICENSE-Akagi.txt` に同梱）
- [RiichiEnv](https://github.com/smly/RiichiEnv)（`riichienv-core`） — サンマの状態と合法アクション列挙の参考実装。
  Akagi のサンマがこれに依存しており、ライセンス表記は上記と同じです
- [riichi-mahjong-tiles](https://github.com/FluffyStuff/riichi-mahjong-tiles)（FluffyStuff）
  — サイドバーで使用している麻雀牌の画像、**CC0 1.0／パブリックドメイン**
- 雀魂（Majsoul） — 素晴らしい麻雀ゲーム

### 牌画像アセット

サイドバーの牌面は FluffyStuff/riichi-mahjong-tiles（CC0 1.0、パブリックドメイン）のもので、
SVG は全 40 枚：数牌 27 枚、赤五 3 枚、字牌 7 枚、牌の裏など 3 枚です。

それ以前の Naki は Unicode の麻雀文字（`🀇🀙🀐`）を使っていました。システムフォントはそれらを白黒の線画で描画するため、
推奨列のサイズでは、まず牌を「見分けて」からでないと卓上の牌と対応づけられませんでした。さらに**赤五を表現できません**。
`5mr` と `5m` は同じ code point で、牌全体を赤く染めるしかなかったのです。画像ファイルに切り替えたことで、赤五は独立したアセットになりました。

アセットは MJAI 形式で命名されており（`5mr`／`5pr`／`5sr`）、`Tile.mjaiString` と同じ規約です。
取り込みの記録と牌ごとの対応表は [`docs/third-party/riichi-mahjong-tiles.md`](docs/third-party/riichi-mahjong-tiles.md) にあります。

CC0 はクレジット表記を求めませんが、ここに記載しているのは追跡可能性のためです。

---

## ライセンス

[AGPL-3.0 with Commons Clause](LICENSE) — オープンソースですが、**商用販売は禁止**です。

---

## ⚖️ 免責事項

**開発目的**：Swift / SwiftUI によるネイティブ開発、Core ML モデルの統合、
WebSocket と Protobuf のプロトコル解析の学習です。

**アカウントのリスク**：本ツールを使用すると雀魂の利用規約に違反する可能性があり、アカウントが一時停止または永久凍結される場合があります。
**サブアカウントの使用を強く推奨します。**

- **事例**：2026-08-30、日本語チャンネルで、iPhone で Naki とクラウド v8 を組み合わせ、
  対局中の自動打牌だけをオンにして、1 日あたり約 6 戦の東風戦を打っていたユーザーから、約 1 週間後に 2 週間のアカウント停止を受け、
  段位が雀傑3 から初心3 に下がったという報告がありました。
- **コミュニティの推測（未検証）**：以下の検出要因はいずれもコミュニティで議論されている推測であり、凍結の原因と確認されたものではありません。
  - `timeuse` と打牌時間の分布
  - 終局後にロビーへ戻らないこと
  - 長時間の連続対局。ほかに、1 日 8 時間の連続対局で 3 日から 1 週間で凍結され、1 日 4 時間に減らしたところ約 1 か月もったという報告もあります
  - 公開モデルとの高い一致率
- **確認済み**：2026-08 の凍結の波は MITM 証明書のテレメトリに関係しています。Naki は WebView を使い MITM を経由しないため、この点の影響は受けません。
- 以上は、どのような遅延や設定でも凍結を避けられるという保証を意味するものではありません。

**API key の誤送信**：雀魂の URL を「サーバー URL」欄に入力したことがある場合、key が意図しないサーバーへ送信された可能性があります。
エンドポイントの保護で防げるのはそれ以降の誤送信だけで、すでに送信された key を回収することはできません。key を発行したサービスで失効または再発行してください
（デフォルトのサービスでは Discord の `!api_new` コマンドです。デフォルトのサービスにのみ該当します）。問題を報告するときは、先に key をマスクしてください。

**法的リスク**：地域によっては、この種のツールの使用が法的な問題になる場合があります。現地の法令を各自でご確認ください。

**無保証**：本ソフトウェアは「現状のまま」提供され、明示・黙示を問わずいかなる保証もありません。
作者は、いかなる請求、損害、その他の責任についても負いません。

**第三者**：雀魂は猫糧工作室の登録商標です。本プロジェクトは猫糧工作室および悠星網絡とは一切関係がありません。

本ソフトウェアを使用することは、以上の条項を読み、理解し、同意したものとみなされます。

---

<p align="center">
  <a href="https://star-history.com/#Sunalamye/Naki&Date">
    <img src="https://api.star-history.com/svg?repos=Sunalamye/Naki&type=Date" width="500" alt="Star History">
  </a>
</p>

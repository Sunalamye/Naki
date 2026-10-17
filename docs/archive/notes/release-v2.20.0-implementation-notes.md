# release v2.20.0 實作筆記

日期：2026-10-17。基底 main `f8a2915`。log：`.swfd/logs/release-v2.20.0/`。

## Deviations
- 沒有直接跑 `release.sh`。它把 commit、tag、push、release 綁在一起，live smoke 插不進 tag 之前。改成照腳本相同指令分步執行：NakiTests 門禁、bump、Release build、iOS archive、打包，live smoke 通過後才 tag、push、建 release。
- README.en／README.ja 的版本 badge 不在腳本範圍，手動一併改。
- `lint-notes.py` 在 tag 建立前必因 compare 連結失敗；先以替換連結的探針驗其他項，tag 推上後再補跑。

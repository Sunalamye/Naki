#!/usr/bin/env python3
"""把 Asset Catalog 的麻將牌 SVG 併成一份 sprite，供 UI wireframe 內嵌使用。

為什麼要這支腳本：`docs/ui-reference/action-states/prototype.html` 原本用手繪的
`tileSVG()`（數字＋「萬」、圓圈陣列、箭頭狀索子）畫牌，與 shipping App 實際會顯示的
牌面不是同一套東西——wireframe 因此無法用來判斷「這個尺寸看不看得清」。

改成直接吃 shipping 用的同一批資產（FluffyStuff/riichi-mahjong-tiles, CC0），
wireframe 與 SwiftUI 就共用同一個視覺事實。

兩個必須處理的細節：

1. **id 衝突**：每個 Inkscape 檔案內部都有 `svg2`、`linearGradient…` 這種 id，
   40 份併進同一個文件會互相覆蓋（後者贏），畫面上表現為漸層／遮罩錯亂。
   所以每份的 id 全部加上該牌的前綴，並同步改寫 `url(#…)`／`href="#…"` 引用。

2. **體積**：Inkscape 會寫入 RDF metadata、編輯器狀態與 15 位小數座標，
   原始 40 份共 778KB。清掉 metadata 並把座標降到 2 位小數後約 487KB，
   對單檔自包含的參考檔案來說可以接受。

用法：
    python3 scripts/build-tile-sprite.py            # 寫入 prototype.html 旁的 sprite
    python3 scripts/build-tile-sprite.py --check    # 只驗證，不寫檔（CI／驗收用）
"""

from __future__ import annotations

import argparse
import glob
import pathlib
import re
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
CATALOG = REPO / "command/Resources/Assets.xcassets/MahjongTiles"
OUT = REPO / "docs/ui-reference/action-states/tile-sprite.svg"
PROTOTYPE = REPO / "docs/ui-reference/action-states/prototype.html"
# `.swfd` 那份的 byte-identical 由 README 的驗收條目鎖著，注入後一起更新，
# 否則兩份會從這一刻起漂開。
MIRROR = REPO / ".swfd/html-artifact/naki-action-state-reference/2026-08-08.html"
BEGIN = "<!-- TILE-SPRITE:BEGIN -->"
END = "<!-- TILE-SPRITE:END -->"

# 資產的 imageset 名稱直接就是 MJAI 字串（含赤五 5mr/5pr/5sr），
# 所以這裡不需要第二套對照表——資產改名的用意正是消掉那層轉換。
EXPECTED = (
    [f"{n}{s}" for s in "mps" for n in range(1, 10)]
    + ["5mr", "5pr", "5sr"]
    + ["E", "S", "W", "N", "P", "F", "C"]
    + ["back", "blank", "front"]
)


def clean(src: str, prefix: str) -> str:
    """去掉編輯器殘留並把 id namespace 化，回傳 `<symbol>` 的內容。"""
    s = re.sub(r"<\?xml[^>]*\?>", "", src)
    s = re.sub(r"<!--.*?-->", "", s, flags=re.S)
    s = re.sub(r"<metadata.*?</metadata>", "", s, flags=re.S)
    s = re.sub(r"<sodipodi:namedview.*?(/>|</sodipodi:namedview>)", "", s, flags=re.S)
    s = re.sub(r"\s+(inkscape|sodipodi):[\w-]+=\"[^\"]*\"", "", s)

    # id 前綴：先收集再取代，避免邊改邊掃到自己改出來的新 id
    ids = set(re.findall(r'\bid="([^"]+)"', s))
    for old in sorted(ids, key=len, reverse=True):
        new = f"{prefix}-{old}"
        s = s.replace(f'id="{old}"', f'id="{new}"')
        s = s.replace(f"url(#{old})", f"url(#{new})")
        s = s.replace(f'href="#{old}"', f'href="#{new}"')

    # 座標精度：Inkscape 的 15 位小數對 300×400 的圖毫無意義
    s = re.sub(
        r"(\d+\.\d{3,})",
        lambda m: f"{float(m.group(1)):.2f}".rstrip("0").rstrip("."),
        s,
    )

    # 只留 <svg> 的內容；外層由 <symbol> 取代（viewBox 統一在 symbol 上）
    body = re.search(r"<svg[^>]*>(.*)</svg>", s, flags=re.S)
    if not body:
        raise ValueError(f"{prefix}: 找不到 <svg> 根元素")
    inner = body.group(1)
    inner = re.sub(r"\s{2,}", " ", inner)
    inner = re.sub(r">\s+<", "><", inner)
    return inner.strip()


def collect() -> dict[str, str]:
    found: dict[str, str] = {}
    for path in sorted(glob.glob(str(CATALOG / "*/*.imageset/*.svg"))):
        code = pathlib.Path(path).parent.name.removesuffix(".imageset")
        found[code] = clean(pathlib.Path(path).read_text(), code)
    return found


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true", help="只驗證，不寫檔")
    parser.add_argument(
        "--inject",
        action="store_true",
        help="把 sprite 內嵌進 prototype.html 與 .swfd 鏡像（維持兩份 byte-identical）",
    )
    args = parser.parse_args()

    if not CATALOG.is_dir():
        print(f"找不到資產目錄：{CATALOG}", file=sys.stderr)
        return 1

    tiles = collect()

    missing = [c for c in EXPECTED if c not in tiles]
    extra = [c for c in tiles if c not in EXPECTED]
    if missing or extra:
        if missing:
            print(f"缺少 {len(missing)} 張：{', '.join(missing)}", file=sys.stderr)
        if extra:
            print(f"多出 {len(extra)} 張：{', '.join(extra)}", file=sys.stderr)
        return 1

    symbols = "".join(
        f'<symbol id="t-{code}" viewBox="0 0 300 400">{tiles[code]}</symbol>'
        for code in EXPECTED
    )
    sprite = (
        '<svg xmlns="http://www.w3.org/2000/svg" '
        'xmlns:xlink="http://www.w3.org/1999/xlink" '
        'style="display:none" aria-hidden="true" id="tile-sprite">'
        f"<defs>{symbols}</defs></svg>"
    )

    if args.check:
        print(f"✓ {len(tiles)} 張齊全，sprite 將為 {len(sprite) / 1024:.0f}KB")
        return 0

    OUT.write_text(sprite + "\n")
    print(f"✓ 寫入 {OUT.relative_to(REPO)}（{len(tiles)} 張，{len(sprite) / 1024:.0f}KB）")

    if not args.inject:
        return 0

    html = PROTOTYPE.read_text()
    if BEGIN not in html or END not in html:
        print(f"{PROTOTYPE.name} 找不到 {BEGIN}…{END} 標記", file=sys.stderr)
        return 1
    head, rest = html.split(BEGIN, 1)
    _, tail = rest.split(END, 1)
    injected = f"{head}{BEGIN}{sprite}{END}{tail}"

    PROTOTYPE.write_text(injected)
    print(f"✓ 注入 {PROTOTYPE.relative_to(REPO)}（{len(injected) / 1024:.0f}KB）")

    if MIRROR.parent.is_dir():
        MIRROR.write_text(injected)
        print(f"✓ 同步 {MIRROR.relative_to(REPO)}（byte-identical）")
    else:
        print(f"! 找不到鏡像目錄 {MIRROR.parent}，未同步", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

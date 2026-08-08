# Riichi Mahjong Tile Assets

Naki vendors the `Regular` SVG tile set from
[`FluffyStuff/riichi-mahjong-tiles`](https://github.com/FluffyStuff/riichi-mahjong-tiles).

- Upstream commit: `26e127ba2117f45cdce5ea0225748cc0cfad3169`
- Upstream asset directory: `Regular/`
- License: CC0 1.0 / public domain
- License source: <https://github.com/FluffyStuff/riichi-mahjong-tiles/blob/master/LICENSE.md>

The files are copied without artwork modification. Each SVG is stored as a
universal Xcode imageset with vector preservation enabled in both application
asset catalogs:

- `command/Resources/Assets.xcassets/MahjongTiles/`
- `Naki-M/Assets.xcassets/MahjongTiles/`

The `MahjongTiles` group and each category group provide Xcode asset namespaces.
String-based image lookups therefore use names such as
`MahjongTiles/Pinzu/5p`, while generated Swift symbols are grouped
under `ImageResource.MahjongTiles.Pinzu`. Because Swift identifiers cannot
begin with a number, Xcode generates numeric symbols with a leading underscore,
for example `.MahjongTiles.Pinzu._5P`. Honor and utility examples are
`.MahjongTiles.Honors.F` and `.MahjongTiles.Utility.back`.

- `Manzu`: characters (`1m`–`9m`, `5mr`)
- `Pinzu`: circles (`1p`–`9p`, `5pr`)
- `Souzu`: bamboo (`1s`–`9s`, `5sr`)
- `Honors`: winds and dragons (`E`, `S`, `W`, `N`, `P`, `F`, `C`)
- `Utility`: tile back, blank face, and empty tile body

## Asset-name mapping

Naki uses the existing MJAI code as the short imageset name. The category
namespace supplies the semantic grouping without repeating `MahjongTile`.

Red fives are named `5mr`/`5pr`/`5sr`, matching `Tile.mjaiString` — not the
Tenhou-style `0m`/`0p`/`0s` the upstream filenames imply. Naki is the single
convention here, so `TileImage.assetName(for:)` needs no red-five special case
and cannot silently render a red five as a plain five. A `0m` reaching the view
layer is treated as unrecognised and falls back to a labelled tile.

| MJAI / purpose | Asset name | Upstream file |
| --- | --- | --- |
| `1m`–`9m` | `Manzu/1m`–`Manzu/9m` | `Man1.svg`–`Man9.svg` |
| red `5m` | `Manzu/5mr` | `Man5-Dora.svg` |
| `1p`–`9p` | `Pinzu/1p`–`Pinzu/9p` | `Pin1.svg`–`Pin9.svg` |
| red `5p` | `Pinzu/5pr` | `Pin5-Dora.svg` |
| `1s`–`9s` | `Souzu/1s`–`Souzu/9s` | `Sou1.svg`–`Sou9.svg` |
| red `5s` | `Souzu/5sr` | `Sou5-Dora.svg` |
| `E`, `S`, `W`, `N` | `Honors/E`, `/S`, `/W`, `/N` | `Ton.svg`, `Nan.svg`, `Shaa.svg`, `Pei.svg` |
| `P`, `F`, `C` | `Honors/P`, `/F`, `/C` | `Haku.svg`, `Hatsu.svg`, `Chun.svg` |
| tile back | `Utility/back` | `Back.svg` |
| blank face | `Utility/blank` | `Blank.svg` |
| empty tile body | `Utility/front` | `Front.svg` |

CC0 does not require attribution, but this record is retained for provenance,
reproducibility, and future asset audits.

## Import verification

- Both catalogs contain 40 namespaced imageset entries.
- Every imageset manifest parses as JSON and every source file parses as SVG/XML.
- The two catalog copies are byte-identical, and the desktop copy matches the
  files at the upstream commit recorded above.
- Xcode's asset compiler accepts both catalogs and emits `Assets.car`.
- The `Naki` macOS scheme and `Naki-M` iOS Simulator scheme both build with the
  imported assets and generate Swift asset symbols.

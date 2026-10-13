#!/usr/bin/env python3
"""Localizable.xcstrings 閘：來源語系 zh-Hant、每 key 四語系齊、各語系占位符與 key 一致。
用法：python3 scripts/xcstrings-gate.py [catalog 路徑]；有 FAIL 即 exit 1。"""
import json
import re
import sys
from collections import Counter
from pathlib import Path

LANGUAGES = ("en", "ja", "ko", "zh-Hans")
PLACEHOLDER = re.compile(r"%(?:\d+\$)?(@|l{0,2}[dui]|f)")


def placeholders(text):
    return Counter(PLACEHOLDER.findall(text.replace("%%", "")))


def main():
    path = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent / "command/Resources/Localizable.xcstrings"
    catalog = json.loads(path.read_text(encoding="utf-8"))
    failures = []
    if catalog.get("sourceLanguage") != "zh-Hant":
        failures.append(f"sourceLanguage={catalog.get('sourceLanguage')!r}")
    for key, entry in catalog["strings"].items():
        expected = placeholders(key)
        localizations = entry.get("localizations", {})
        for language in LANGUAGES:
            unit = localizations.get(language, {}).get("stringUnit")
            if not unit or unit.get("state") != "translated" or not unit.get("value"):
                failures.append(f"{key!r} 缺 {language}")
            elif placeholders(unit["value"]) != expected:
                failures.append(f"{key!r} {language} 占位符不符：{unit['value']!r}")
    for failure in failures:
        print(f"FAIL {failure}")
    print(f"{len(catalog['strings'])} keys, {len(failures)} failures")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())

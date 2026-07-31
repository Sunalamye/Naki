#!/usr/bin/env python3
"""解析雀魂 lqc.lqbin（自描述配置表）。

Schema 來自遊戲自己的 res/proto/config.proto：
  ConfigTables { version=1, header_hash=2, schemas=3 (TableSchema), datas=4 (SheetData) }
  TableSchema  { name=1, sheets=2 (SheetSchema) }
  SheetSchema  { name=1, meta=2 (SheetMeta), fields=3 (Field) }
  Field        { field_name=1, array_length=2, pb_type=3, pb_index=4 }
  SheetData    { table=1, sheet=2, data=3 (repeated bytes) }
不猜任何欄位編號——全部照 proto 定義。
"""
import sys
from collections import OrderedDict


def read_varint(b, i):
    v = 0
    shift = 0
    while True:
        x = b[i]
        i += 1
        v |= (x & 0x7F) << shift
        if not (x & 0x80):
            return v, i
        shift += 7


def fields(b, start=0, end=None):
    """逐一產出 (field_no, wire_type, value)。value 對 wt=2 是 bytes，wt=0 是 int。"""
    if end is None:
        end = len(b)
    i = start
    while i < end:
        tag, i = read_varint(b, i)
        fno, wt = tag >> 3, tag & 7
        if wt == 0:
            v, i = read_varint(b, i)
            yield fno, wt, v
        elif wt == 2:
            ln, i = read_varint(b, i)
            yield fno, wt, b[i:i + ln]
            i += ln
        elif wt == 5:
            yield fno, wt, b[i:i + 4]
            i += 4
        elif wt == 1:
            yield fno, wt, b[i:i + 8]
            i += 8
        else:
            raise ValueError(f"unsupported wire type {wt} at {i}")


def s(x):
    return x.decode("utf-8", "replace")


def parse_field(b):
    f = {"name": None, "array_length": 0, "pb_type": None, "pb_index": None}
    for no, wt, v in fields(b):
        if no == 1:
            f["name"] = s(v)
        elif no == 2:
            f["array_length"] = v
        elif no == 3:
            f["pb_type"] = s(v)
        elif no == 4:
            f["pb_index"] = v
    return f


def parse_sheet_schema(b):
    sh = {"name": None, "category": None, "key": None, "fields": []}
    for no, wt, v in fields(b):
        if no == 1:
            sh["name"] = s(v)
        elif no == 2:
            for mno, _, mv in fields(v):
                if mno == 1:
                    sh["category"] = s(mv)
                elif mno == 2:
                    sh["key"] = s(mv)
        elif no == 3:
            sh["fields"].append(parse_field(v))
    return sh


def main(path):
    raw = open(path, "rb").read()
    schemas = OrderedDict()   # table -> [sheet...]
    counts = OrderedDict()    # (table, sheet) -> row count
    version = header_hash = None

    for no, wt, v in fields(raw):
        if no == 1:
            version = s(v)
        elif no == 2:
            header_hash = s(v)
        elif no == 3:
            tname, sheets = None, []
            for tno, _, tv in fields(v):
                if tno == 1:
                    tname = s(tv)
                elif tno == 2:
                    sheets.append(parse_sheet_schema(tv))
            schemas[tname] = sheets
        elif no == 4:
            table = sheet = None
            rows = 0
            for dno, _, dv in fields(v):
                if dno == 1:
                    table = s(dv)
                elif dno == 2:
                    sheet = s(dv)
                elif dno == 3:
                    rows += 1
            counts[(table, sheet)] = rows

    print(f"version={version} header_hash={header_hash}")
    print(f"tables={len(schemas)} sheet_data_entries={len(counts)}")
    total_rows = sum(counts.values())
    print(f"total_rows={total_rows}")
    print()

    if len(sys.argv) > 2:
        pat = sys.argv[2].lower()
        print(f"--- 符合 '{pat}' 的表 ---")
        for t, sheets in schemas.items():
            for sh in sheets:
                label = f"{t}.{sh['name']}"
                blob = (label + " " + " ".join(f["name"] or "" for f in sh["fields"])).lower()
                if pat in blob:
                    n = counts.get((t, sh["name"]), 0)
                    print(f"\n{label}  (rows={n}, key={sh['key']}, category={sh['category']})")
                    for f in sh["fields"]:
                        arr = f"[{f['array_length']}]" if f["array_length"] else ""
                        print(f"    {f['pb_index']:>3} {f['name']}{arr}: {f['pb_type']}")
    else:
        print("--- 所有表 (table.sheet = rows) ---")
        for t, sheets in schemas.items():
            for sh in sheets:
                print(f"{t}.{sh['name']} = {counts.get((t, sh['name']), 0)}")


if __name__ == "__main__":
    main(sys.argv[1])

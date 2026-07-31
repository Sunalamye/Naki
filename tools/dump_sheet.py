#!/usr/bin/env python3
"""依 lqc.lqbin 自帶的 schema 解出指定 sheet 的資料列。

用法: dump_sheet.py lqc.lqbin <table.sheet> [限制筆數]
欄位編號一律取自檔案內的 SheetSchema.fields[].pb_index，不做任何猜測。
"""
import sys
import json
from parse_lqc import fields, s, parse_sheet_schema


def decode_row(blob, schema_fields):
    by_idx = {f["pb_index"]: f for f in schema_fields}
    out = {}
    for no, wt, v in fields(blob):
        f = by_idx.get(no)
        name = f["name"] if f else f"field{no}"
        t = f["pb_type"] if f else None
        is_arr = bool(f and f["array_length"])

        if wt == 2:
            if t == "string":
                val = s(v)
            elif t in ("uint32", "int32", "uint64", "int64", "bool"):
                # packed repeated varint
                val, i = [], 0
                while i < len(v):
                    x, i = _varint(v, i)
                    val.append(x)
            else:
                val = v.hex()[:60]
        elif wt == 0:
            val = v
        elif wt == 5:
            val = int.from_bytes(v, "little")
        else:
            val = v.hex()[:40] if isinstance(v, (bytes, bytearray)) else v

        if is_arr or name in out:
            out.setdefault(name, [])
            if not isinstance(out[name], list):
                out[name] = [out[name]]
            out[name].append(val)
        else:
            out[name] = val
    return out


def _varint(b, i):
    v = 0
    shift = 0
    while True:
        x = b[i]
        i += 1
        v |= (x & 0x7F) << shift
        if not (x & 0x80):
            return v, i
        shift += 7


def main():
    path, target = sys.argv[1], sys.argv[2]
    limit = int(sys.argv[3]) if len(sys.argv) > 3 else 20
    raw = open(path, "rb").read()

    want_table, want_sheet = target.split(".", 1)
    schema_fields = None
    rows = []

    for no, wt, v in fields(raw):
        if no == 3:
            tname = None
            sheets = []
            for tno, _, tv in fields(v):
                if tno == 1:
                    tname = s(tv)
                elif tno == 2:
                    sheets.append(parse_sheet_schema(tv))
            if tname == want_table:
                for sh in sheets:
                    if sh["name"] == want_sheet:
                        schema_fields = sh["fields"]
        elif no == 4:
            table = sheet = None
            blobs = []
            for dno, _, dv in fields(v):
                if dno == 1:
                    table = s(dv)
                elif dno == 2:
                    sheet = s(dv)
                elif dno == 3:
                    blobs.append(dv)
            if table == want_table and sheet == want_sheet:
                rows.extend(blobs)

    if schema_fields is None:
        print(f"找不到 schema: {target}")
        return
    print(f"{target}: rows={len(rows)}")
    for blob in rows[:limit]:
        print(json.dumps(decode_row(blob, schema_fields), ensure_ascii=False))


if __name__ == "__main__":
    main()

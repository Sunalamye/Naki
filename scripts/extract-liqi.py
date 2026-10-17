#!/usr/bin/env python3
"""從雀魂官方 Unity 資源包抽出 Liqi 協定，產生 protobufjs nested 格式的 liqi.json。

  extract-liqi.py fetch RAW_DIR        下載 Protol/*_pb.lua 與 proto_config 到 RAW_DIR（需 UnityPy）
  extract-liqi.py build RAW_DIR OUT    由 RAW_DIR 產生 OUT（純轉換，不連網）
  extract-liqi.py diff OLD NEW         列出型別、欄位、RPC 差異；有差異時退出碼 1

管線比照 Akagi v3 scripts/extract_liqi.py：client HTML → clientBundleSettings → warehouse → DXT bundle_info_so → Protol/*_pb.lua＋proto_config.bytes。
"""
import hashlib, json, posixpath, re, sys, urllib.request, warnings
from pathlib import Path
from urllib.parse import urljoin

CLIENT_URL = "https://game.maj-soul.com/1/"
LUA_XOR_KEY = b"wrelupqezdfrqdsd"
PROTOL_PREFIX = "LuaByte/Lua/Protol/"
PROTO_CONFIG = "MyAssets/docs/proto_config.bytes"
UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"


def fetch(raw: Path) -> None:
    import UnityPy
    UnityPy.config.FALLBACK_UNITY_VERSION = "2022.3.62f2c1"
    warnings.simplefilter("ignore")
    log = []

    def get(url):
        with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": UA}), timeout=60) as r:
            data = r.read()
        log.append({"url": url, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()})
        return data

    def join(base, path):
        return urljoin(base.rstrip("/") + "/", path.lstrip("/"))

    best = lambda urls: max(urls, key=lambda e: (e.get("Priority", 0), e.get("weight", 0)))["url"]  # noqa: E731
    html = get(CLIENT_URL).decode("utf-8", "replace")
    issuer = re.search(r"Build/([^\"']+?)-WebGL-release-", html).group(1)
    version = re.search(r"productVersion\s*:\s*[\"']([^\"']+)", html).group(1)
    wh = json.loads(get(urljoin(CLIENT_URL, f"/assetbundles/clientBundleSettings/{issuer}-release.json")))["warehouses"][0]
    whs = json.loads(get(join(best(wh["urls"]), wh["warehouseSettingPath"])))
    base = join(join(best(whs["urls"]), whs["bundlePath"]), "DXT") + "/"
    bundle_hash = get(base + "bundle_hash.txt").decode().strip()

    info = next(o.read_typetree() for o in UnityPy.load(get(base + "bundle_info_so.majset")).objects
                if o.type.name == "MonoBehaviour" and "assetInfos" in o.read_typetree())
    wanted = {}
    for a in info["assetInfos"]:
        p = a.get("assetPath", "")
        if (p.startswith(PROTOL_PREFIX) and p.endswith(".lua.bytes")) or p == PROTO_CONFIG:
            wanted.setdefault(a["ownerBundleIndex"], []).append(p)

    (raw / "Protol").mkdir(parents=True, exist_ok=True)
    for idx, paths in sorted(wanted.items()):
        assets = (o.read() for o in UnityPy.load(get(base + info["bundleInfos"][idx]["name"])).objects
                  if o.type.name == "TextAsset")
        texts = {t.m_Name: t.m_Script if isinstance(t.m_Script, bytes) else t.m_Script.encode("utf-8", "surrogateescape")
                 for t in assets}
        for p in paths:
            name = posixpath.basename(p)
            data = texts.get(name) or texts[name[:-len(".bytes")]]
            if p == PROTO_CONFIG:
                (raw / "proto_config.json").write_bytes(data)
            else:
                if not data.lstrip().startswith((b"--", b"local", b"return")):
                    data = bytes(b ^ LUA_XOR_KEY[i % 16] for i, b in enumerate(data))
                (raw / "Protol" / name[:-len(".bytes")]).write_bytes(data)
    (raw / "source.json").write_text(json.dumps({"product_version": version, "issuer": issuer, "bundle_hash": bundle_hash, "downloads": log}, indent=1) + "\n")
    print(f"productVersion={version} bundle_hash={bundle_hash} 下載 {len(log)} 檔")


SCALAR = {1: "double", 2: "float", 3: "int64", 4: "uint64", 5: "int32", 6: "fixed64", 7: "fixed32", 8: "bool",
          9: "string", 12: "bytes", 13: "uint32", 15: "sfixed32", 16: "sfixed64", 17: "sint32", 18: "sint64"}
PROP = re.compile(r'(\w+)\.(\w+)\s*=\s*("(?:\\.|[^"\\])*"|-?\d+|\{[^{}]*\}|\w+(?:\.\w+)?)')
DECL = re.compile(r"(\w+)\s*=\s*\w+\.(Descriptor|EnumDescriptor)\(\)")
# 沿用舊 liqi.json（原 liqi.proto）的區塊順序，diff 才可讀；未列名的模組依名稱排在最後
ORDER = ["notify_lobby_pb", "com_struct_pb", "Lobby", "cli_lobby_pb", "amulet_struct_pb",
         "FastTest", "cli_game_pb", "liqi_struct_pb", "Route", "cli_route_pb"]
IMPORT = re.compile(r'local (\w+)\s*=\s*require\s*\(?\s*"Protol\.(\w+)"\)?')


def parse_module(src):
    """回傳 (宣告順序的頂層 descriptor 變數, 變數屬性表, import alias 表)。"""
    props = {}
    for var, key, val in PROP.findall(src):
        val = (val[1:-1] if val[0] == '"' else re.findall(r"\w+", val) if val[0] == "{"
               else int(val) if re.fullmatch(r"-?\d+", val) else val)
        props.setdefault(var, {}).setdefault(key, val)
    decls = DECL.findall(src)
    inner = {n for v, _ in decls for k in ("nested_types", "enum_types") for n in props.get(v, {}).get(k, [])}
    return [d for d in decls if d[0] not in inner], props, dict(IMPORT.findall(src))


def type_paths(nested, prefix=()):
    """lq 底下每個型別（含巢狀）的路徑 → 定義。"""
    out = {}
    for name, body in nested.items():
        if "methods" not in body:
            out[prefix + (name,)] = body
            out |= type_paths(body.get("nested", {}), prefix + (name,))
    return out


def resolve(known, scope, name):
    """protobufjs 式名稱查找：由內層 scope 往外找；lq. 開頭視為套件絕對路徑。"""
    parts = tuple(name.split("."))
    if parts[0] == "lq":
        return parts[1:] if parts[1:] in known else None
    return next((scope[:i] + parts for i in range(len(scope), -1, -1) if scope[:i] + parts in known), None)


def build(raw: Path, out: Path) -> None:
    mods = {p.name[:-len(".lua")]: parse_module(p.read_text(errors="surrogateescape"))
            for p in sorted((raw / "Protol").glob("*_pb.lua"))}

    def fqn(mod, ref):
        alias, _, var = ref.rpartition(".")
        props = mods[mods[mod][2][alias]][1] if alias else mods[mod][1]
        return props[var]["full_name"]

    def node(mod, var, kind):
        p = mods[mod][1][var]
        if kind == "EnumDescriptor":
            vals = sorted((mods[mod][1][v] for v in p.get("values", [])), key=lambda v: v["index"])
            return {"values": {v["name"]: v["number"] for v in vals}}
        fields = {}
        for f in sorted((mods[mod][1][v] for v in p.get("fields", [])), key=lambda f: f["index"]):
            ref = f.get("message_type") or f.get("enum_type")
            t = fqn(mod, ref) if ref else SCALAR[f["type"]]
            fields[f["name"]] = ({"rule": "repeated"} if f["label"] == 3 else {}) | {"type": t, "id": f["number"]}
        body = {"fields": fields}
        inner = [(v, "Descriptor") for v in p.get("nested_types", [])] + [(v, "EnumDescriptor") for v in p.get("enum_types", [])]
        if inner:
            body["nested"] = {mods[mod][1][v]["name"]: node(mod, v, k) for v, k in inner}
        return body

    types = {}
    for mod, (top, props, _) in mods.items():
        for var, kind in top:
            if props[var]["full_name"] == ".lq." + props[var]["name"]:
                types.setdefault(mod, {})[props[var]["name"]] = node(mod, var, kind)
    names = {n for t in types.values() for n in t}
    if sum(map(len, types.values())) != len(names):
        sys.exit("lq 套件內有重複的型別名")
    services = json.loads((raw / "proto_config.json").read_bytes())["service"]
    groups = types | {svc: {svc: {"methods": {m: {"requestType": s["request"], "responseType": s["response"]}
                                             for m, s in methods.items() if {s["request"], s["response"]} <= names}}}
                      for svc, methods in services.items()}
    lq = {}
    for key in ORDER + sorted(set(groups) - set(ORDER)):
        lq |= groups.get(key, {})
    known = type_paths(lq)
    for scope, body in known.items():
        for f in body.get("fields", {}).values():
            if f["type"].startswith(".lq."):
                full = tuple(f["type"][4:].split("."))
                f["type"] = next((".".join(full[-k:]) for k in range(1, len(full) + 1)
                                  if resolve(known, scope, ".".join(full[-k:])) == full), f["type"][1:])
    out.write_text(json.dumps({"nested": {"lq": {"nested": lq}}}, ensure_ascii=False, separators=(",", ":")))
    print(f"{len(lq) - len(services)} 個型別、{len(services)} 個 service、{sum(len(v.get('methods', ())) for v in lq.values())} 個 RPC → {out}")


def flatten(path):
    """{型別路徑: 欄位（型別解析成完整路徑）或 enum 值, "rpc Svc.m": 請求/回應}。"""
    lq = json.loads(Path(path).read_bytes())["nested"]["lq"]["nested"]
    known = type_paths(lq)
    out = {f"rpc {s}.{m}": f'{r["requestType"]} -> {r["responseType"]}'
           for s, body in lq.items() for m, r in body.get("methods", {}).items()}
    for scope, body in known.items():
        out[".".join(scope)] = body.get("values") or {
            f: (v.get("rule", ""), ".".join(resolve(known, scope, v["type"]) or (v["type"],)), v["id"])
            for f, v in body["fields"].items()}
    return out


def diff(old_path, new_path) -> int:
    old, new = flatten(old_path), flatten(new_path)
    for kind, pred in (("RPC", lambda k: k.startswith("rpc ")), ("型別", lambda k: not k.startswith("rpc "))):
        o, n = {k for k in old if pred(k)}, {k for k in new if pred(k)}
        print(f"{kind}：{len(o)} -> {len(n)}（+{len(n - o)} -{len(o - n)}）")
        print("".join(f"  + {k}\n" for k in sorted(n - o)) + "".join(f"  - {k}\n" for k in sorted(o - n)), end="")
        for k in sorted(k for k in o & n if old[k] != new[k]):
            print(f"  ~ {k}" + (f"：{old[k]} -> {new[k]}" if kind == "RPC" else ""))
            for f in sorted(set(old[k]) | set(new[k])) if kind == "型別" else []:
                if old[k].get(f) != new[k].get(f):
                    print(f"      {f}: {old[k].get(f)} -> {new[k].get(f)}")
    return int(old != new)


if __name__ == "__main__":
    cmd, args = sys.argv[1:2], sys.argv[2:]
    if cmd == ["fetch"] and len(args) == 1:
        fetch(Path(args[0]))
    elif cmd == ["build"] and len(args) == 2:
        build(Path(args[0]), Path(args[1]))
    elif cmd == ["diff"] and len(args) == 2:
        sys.exit(diff(*args))
    else:
        sys.exit(__doc__)

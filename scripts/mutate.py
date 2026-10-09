#!/usr/bin/env python3
"""手工變異測試。用法：mutate.py --diff base..head [--files 名稱…] [--tests 類別…] [--list] [--range a b] [--limit n --offset k] [--out dir]
只變異 diff 新增／修改行；運算子：關係、邏輯連接詞、三元互換、條件取反、移除 !。逐檔摘要：檔案｜總數｜殺掉｜存活｜逾時｜未編譯｜耗時秒。"""
import argparse, json, os, re, signal, subprocess, sys, time

REL = {"==": "!=", "!=": "==", ">=": "<=", "<=": ">=", "<": ">", ">": "<"}
LOG = {"&&": "||", "||": "&&"}
TOKEN = re.compile(r"(?<=\s)(==|!=|>=|<=|&&|\|\||<|>)(?=\s)")
SRC = ["command/*.swift"]

def sh(*a):
    return subprocess.run(a, capture_output=True, text=True).stdout

def changed(base_head):
    out, cur = {}, None
    for l in sh("git", "diff", "-U0", base_head, "--", *SRC).split("\n"):
        if l.startswith("+++ b/"): cur = out.setdefault(l[6:], [])
        elif l.startswith("@@") and cur is not None:
            m = re.search(r"\+(\d+)(?:,(\d+))?", l)
            s, c = int(m.group(1)), int(m.group(2) or 1)
            if c: cur.append((s, s + c - 1))
    return out

def ternary(rest):
    depth, colon = 0, None
    for i, ch in enumerate(rest):
        if ch in "([{": depth += 1
        elif ch in ")]}":
            if depth == 0: break
            depth -= 1
        elif ch == ":" and depth == 0 and colon is None and rest[i - 1] == " " and rest[i + 1:i + 2] == " ": colon = i
        elif ch == "," and depth == 0 and colon is not None: break
    else: i = len(rest)
    return (None, None) if colon is None else (rest[:colon].strip(), rest[colon + 1:i].strip())

def mutants(ranges):
    out = []
    for f, rs in ranges.items():
        for n, line in enumerate(open(f).read().split("\n"), 1):
            code = line.split("//")[0]
            if not any(a <= n <= b for a, b in rs) or not code.strip(): continue
            def add(op, col, frm, to):
                out.append(dict(id=f"{os.path.basename(f)}:{n}:{col}:{op}", file=f, line=n, col=col, op=op, frm=frm, to=to, text=line.strip()))
            for m in TOKEN.finditer(code):
                o = m.group(1)
                if o in "<>" and "->" in code[max(0, m.start() - 1):m.end() + 1]: continue
                if o in LOG: add("ChangeLogicalConnector", m.start(), o, LOG[o])
                else: add("RelationalOperatorReplacement", m.start(), o, REL[o])
            q = code.find(" ? ")
            if q >= 0:
                a, b = ternary(code[q + 3:])
                if a: add("SwapTernary", q + 1, f"? {a} : {b}", f"? {b} : {a}")
            for m in re.finditer(r"(?<![=!<>&|\w])!(?=[a-zA-Z(])", code): add("RemoveNegation", m.start(), "!", "")
            g = re.match(r"(\s*)(if|guard|\} else if) (.+?)( else \{| \{)\s*$", code)
            if g and "let " not in g.group(3):
                add("NegateCondition", len(g.group(1)) + len(g.group(2)) + 1, g.group(3), f"!({g.group(3)})")
    return out

def default_tests(f):
    name = os.path.basename(f)[:-6]
    files = [os.path.join("NakiTests", x) for x in os.listdir("NakiTests") if x.endswith("Tests.swift")]
    hits = sh("grep", "-lw", name, *files).split()
    return sorted({c for h in hits for c in re.findall(r"class (\w+): XCTestCase", open(h).read())})

def run_one(m, tests):
    orig = open(m["file"]).read()
    lines = orig.split("\n"); l = lines[m["line"] - 1]; c = m["col"]
    lines[m["line"] - 1] = l[:c] + l[c:].replace(m["frm"], m["to"], 1)
    args = ["xcodebuild", "test", "-project", "Naki.xcodeproj", "-scheme", "Naki", "-derivedDataPath", "build-test"]
    for t in tests: args += ["-only-testing", f"NakiTests/{t}"]
    if not tests: args += ["-only-testing", "NakiTests"]
    open(m["file"], "w").write("\n".join(lines)); time.sleep(1.1)
    t0, p = time.time(), subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, start_new_session=True)
    try:
        log, code = p.communicate(timeout=420)[0], p.returncode
    except subprocess.TimeoutExpired:
        os.killpg(p.pid, signal.SIGKILL); p.communicate(); log, code = "", "timeout"
    finally:
        open(m["file"], "w").write(orig); time.sleep(1.1)
    failed = sorted(set(re.findall(r"Test Case '-\[NakiTests\.(\w+ \w+)\]' failed", log)))[:3]
    if code == "timeout": st = "timeout"
    elif "BUILD FAILED" in log or (code != 0 and not failed and re.search(r"\.swift:\d+:\d+: error:", log)): st = "build_error"
    elif code != 0: st = "killed"
    elif not re.search(r"Executed [1-9]\d* tests", log): st = "no_tests"
    else: st = "survived"
    if st == "killed" and not failed: failed = [x[:160] for x in re.findall(r".*(?:error|failed|crash|Crash).*", log)[:2]]
    return dict(m, status=st, failed=failed, secs=round(time.time() - t0, 1))

def main():
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    ap = argparse.ArgumentParser()
    ap.add_argument("--diff", required=True); ap.add_argument("--files", nargs="*", default=[]); ap.add_argument("--tests", nargs="*")
    ap.add_argument("--list", action="store_true"); ap.add_argument("--range", nargs=2, type=int); ap.add_argument("--limit", type=int); ap.add_argument("--offset", type=int, default=0)
    ap.add_argument("--out", default=os.path.join(os.environ.get("MAIN_REPO", "."), ".swfd/logs/m2-mutation"))
    a = ap.parse_args()
    ranges = {f: r for f, r in changed(a.diff).items() if not a.files or os.path.basename(f)[:-6] in a.files or os.path.basename(f) in a.files}
    ms = mutants(ranges)
    if a.range: ms = [m for m in ms if a.range[0] <= m["line"] <= a.range[1]]
    ms = ms[a.offset:a.offset + a.limit if a.limit else None]
    if a.list:
        for i, m in enumerate(ms): print(i + a.offset, m["id"], m["frm"], "->", m["to"], "|", m["text"][:90])
        return
    os.makedirs(a.out, exist_ok=True)
    for f in {m["file"] for m in ms}:
        res, mine = os.path.join(a.out, os.path.basename(f)[:-6] + ".jsonl"), [m for m in ms if m["file"] == f]
        done = {json.loads(x)["id"] for x in open(res)} if os.path.exists(res) else set()
        tests = a.tests if a.tests is not None else default_tests(f)
        for m in mine:
            if m["id"] in done: continue
            r = run_one(m, tests); print(r["id"], r["status"], r["failed"][:1], r["secs"], flush=True)
            open(res, "a").write(json.dumps(r, ensure_ascii=False) + "\n")
        rows = [json.loads(x) for x in open(res)]; c = lambda s: sum(r["status"] == s for r in rows)
        print(f"{os.path.basename(f)}｜{len(rows)}｜{c('killed')}｜{c('survived')}｜{c('timeout')}｜{c('build_error')}｜{round(sum(r['secs'] for r in rows))}")

if __name__ == "__main__": main()

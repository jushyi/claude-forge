import datetime
import json
import os
import re
import shlex
import sys
from decimal import Decimal

WS = re.compile(r"[ \t\r\n]*")
TOK = re.compile(r'"(?:[^"\\\x00-\x1f]|\\["\\/bfnrt]|\\u[0-9a-fA-F]{4})*"|-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?|NaN|-?Infinity|true|false|null|[{}\[\]:,]')
STEP = r'\.[A-Za-z_][A-Za-z0-9_]*|\[\]|\["(?:[^"\\]|\\.)*"\]'
IDENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
NORMS = ("keys", "numbers", "space")


def fail(msg):
    print("forge: " + msg, file=sys.stderr)
    sys.exit(1)


def steps(path):
    out = []
    for s in re.findall(STEP, path):
        if s == "[]":
            out.append(("i", None))
        elif s.startswith("["):
            out.append(("k", json.loads(s[1:-1])))
        else:
            out.append(("k", s[1:]))
    return out


def rules(path):
    ignore, norm = [], set()
    with open(path, encoding="utf-8") as f:
        for n, line in enumerate(f, 1):
            w = line.split()
            if not w:
                continue
            if not (len(w) >= 2 and (w[0] == "ignore" or (w[0] == "normalize" and w[1] in NORMS))):
                fail(f"rule line {n} is not 'ignore <path> <reason>' or 'normalize keys|numbers|space <reason>': {line.rstrip()}")
            m = re.fullmatch(rf"\s*(?:ignore\s+((?:{STEP})+)|normalize\s+(\S+))(?:\s+(\S.*?))?\s*", line)
            if not m:
                fail(f"rule line {n} has a bad path; a path joins .key, [\"key\"] and [] steps: {line.rstrip()}")
            if not m.group(3):
                fail(f"rule line {n} needs a reason; every rule needs one: {line.rstrip()}")
            if m.group(2):
                norm.add(m.group(2))
            else:
                ignore.append(steps(m.group(1)))
    return ignore, norm


class Paths:
    def __init__(self, ignore):
        self.ids, self.up, self.seg, self.ign, self.at = {}, [None], [None], [False], [frozenset((r, 0) for r in range(len(ignore)))]
        self.rules = ignore

    def child(self, p, seg):
        k = (p, seg)
        if k not in self.ids:
            at = set()
            for r, i in self.at[p]:
                s = self.rules[r][i]
                if s[0] == seg[0] and (s[1] is None or s[1] == seg[1]):
                    at.add((r, i + 1))
            self.ids[k] = len(self.up)
            self.up.append(p)
            self.seg.append(seg)
            self.ign.append(self.ign[p] or any(i == len(self.rules[r]) for r, i in at))
            self.at.append(frozenset((r, i) for r, i in at if i < len(self.rules[r])))
        return self.ids[k]

    def show(self, n):
        out = []
        while n:
            k, v = self.seg[n]
            out.append("[]" if k == "i" else "." + v if IDENT.fullmatch(v) else "[" + json.dumps(v, ensure_ascii=False) + "]")
            n = self.up[n]
        out.reverse()
        return "".join(out if len(out) <= 32 else out[:16] + ["..."] + out[-16:]) or "."

    def under(self, n, nodes):
        n = self.up[n]
        while n is not None and n not in nodes:
            n = self.up[n]
        return n is not None


def parse(text, P):
    leaves, keys, order, space, seen = {}, {}, [], [], set()
    stack, cur, state, pos = [], 0, "value", 0

    def keep(n, d, v):
        if not P.ign[n]:
            d[n] = v

    while True:
        w = WS.match(text, pos).group()
        pos += len(w)
        ctx = cur if state in ("value", "colon") else stack[-1][0] if stack else 0
        if w and not P.ign[ctx]:
            space.append((ctx, state, stack[-1][2] if stack else 0, w))
        if pos == len(text):
            return (leaves, keys, order, space) if state == "done" else None
        m = TOK.match(text, pos)
        if not m or state == "done":
            return None
        t = m.group()
        pos = m.end()
        if state in ("key_or_end", "value_or_end", "comma_or_end") and t in "}]":
            if not stack or "{[".index(stack[-1][1]) != "}]".index(t):
                return None
            stack.pop()
            state = "comma_or_end" if stack else "done"
            continue
        if state == "comma_or_end":
            if t != ",":
                return None
            if stack[-1][1] == "{":
                state = "key"
            else:
                cur = P.child(stack[-1][0], ("i", stack[-1][2]))
                stack[-1][2] += 1
                state = "value"
            continue
        if state in ("key_or_end", "key"):
            if not t.startswith('"'):
                return None
            cur = P.child(stack[-1][0], ("k", json.loads(t)))
            stack[-1][2] += not P.ign[cur]
            if cur in seen:
                return None
            seen.add(cur)
            keep(cur, keys, t)
            state = "colon"
            continue
        if state == "colon":
            if t != ":":
                return None
            state = "value"
            continue
        if state == "value_or_end":
            cur = P.child(stack[-1][0], ("i", 0))
            stack[-1][2] = 1
        if t in ":,}]":
            return None
        keep(cur, leaves, t)
        if not P.ign[cur]:
            order.append(cur)
        if t in "{[":
            stack.append([cur, t, 0])
            state = "key_or_end" if t == "{" else "value_or_end"
        else:
            state = "comma_or_end" if stack else "done"


def num(v):
    try:
        return Decimal(v) if v[0] in "-0123456789" else v
    except ArithmeticError:
        return v


def compare(want, got, ignore, norm):
    if want == got:
        return []
    P = Paths(ignore)
    a = parse(want.decode("utf-8", "surrogateescape"), P)
    b = parse(got.decode("utf-8", "surrogateescape"), P)
    if a is None or b is None:
        return ["body"]
    same = (lambda x, y: num(x) == num(y)) if "numbers" in norm else (lambda x, y: x == y)
    diff = {n for d in (0, 1) for n in a[d].keys() | b[d].keys() if n not in a[d] or n not in b[d] or not same(a[d][n], b[d][n])}
    if diff:
        return sorted({P.show(n) for n in diff if not P.under(n, diff)})
    if "keys" not in norm and a[2] != b[2]:
        return ["order"]
    if "space" not in norm and a[3] != b[3]:
        return ["space"]
    return []


def ids(j):
    for s in ("requests", "holdout"):
        d = os.path.join(j, s)
        for i in sorted(os.listdir(d)) if os.path.isdir(d) else []:
            if os.path.isfile(os.path.join(d, i)):
                yield s, i


def read(*p):
    with open(os.path.join(*p), "rb") as f:
        return f.read()


def text(b):
    return b.decode("utf-8", "replace")


def classes(rows):
    seen = {}
    for i, c in rows:
        seen.setdefault(c, []).append(i)
    return sorted(seen.items(), key=lambda kv: (-len(kv[1]), kv[0]))


def noise(j):
    rows = []
    for _, i in ids(j):
        rows += [(i, c) for c in compare(read(j, "answers", i), read(j, "noise", i), [], set())]
    for c, xs in classes(rows):
        print(f"noise {c} {len(xs)} {xs[0]}")
    if not rows:
        print("noise none")


def run(j, cmd):
    ignore, norm = rules(os.path.join(j, "rules"))
    out = {"requests": [], "holdout": []}
    count = {"requests": 0, "holdout": 0}
    for s, i in ids(j):
        count[s] += 1
        want, got = read(j, "answers", i), read(j, "got", i)
        c = " ".join(compare(want, got, ignore, norm))
        if c:
            req = os.path.join(j, s, i)
            out[s].append({"id": i, "class": c, "request": text(read(req)).rstrip("\n"), "want": text(want), "got": text(got), "repro": f"bash -c {shlex.quote(cmd)} < {shlex.quote(req)}"})
    for s, f in (("requests", "report.jsonl"), ("holdout", "holdout.jsonl")):
        with open(os.path.join(j, f), "w", encoding="utf-8") as fh:
            for r in out[s]:
                fh.write(json.dumps(r, ensure_ascii=False) + "\n")
    cs = classes([(r["id"], r["class"]) for r in out["requests"]])
    print(f"requests={count['requests']} mismatches={len(out['requests'])} classes={len(cs)} holdout={count['holdout']} holdout_mismatches={len(out['holdout'])}")
    for c, xs in cs:
        print(f"class {c} {len(xs)} {xs[0]}")
    return 1 if out["requests"] or out["holdout"] else 0


def when(v):
    t = datetime.datetime.fromisoformat(v)
    if t.tzinfo is None:
        raise ValueError
    return t.astimezone(datetime.timezone.utc)


def records(j):
    lock = open(os.path.join(j, "lock")).read().strip()
    p = os.path.join(j, "shadow.jsonl")
    rows = [json.loads(x) for x in open(p, encoding="utf-8")] if os.path.exists(p) else []
    return lock, rows, [r for r in rows if r["lock"] == lock]


def window(j):
    hours, need = map(int, open(os.path.join(j, "cutover")).read().split())
    _, _, cur = records(j)
    bad = [when(r["at"]) for r in cur if r["class"]]
    ok = [when(r["at"]) for r in cur if not r["class"]]
    start = max(bad) if bad else min(ok, default=None)
    clean = [t for t in ok if not bad or t > start]
    span = (max(clean) - start).total_seconds() / 3600 if clean else 0.0
    since = f" since {start.isoformat()}" if start else ""
    return span >= hours and len(clean) >= need, f"{int(span * 10) / 10:.1f}h and {len(clean)} requests clean{since}; needs {hours}h and {need}"


def shadow(j, feed):
    ignore, norm = rules(os.path.join(j, "rules"))
    lock, _, cur = records(j)
    seen = {r["id"] for r in cur}
    lines = []
    with (sys.stdin if feed == "-" else open(feed, encoding="utf-8")) as f:
        for n, line in enumerate(f, 1):
            try:
                x = json.loads(line)
                when(x["at"])
                if not all(isinstance(x[k], str) for k in ("id", "at", "request", "old", "new")):
                    raise TypeError
            except (ValueError, KeyError, TypeError):
                fail(f"feed line {n} is not a JSON object with string id, at (ISO-8601 with offset), request, old and new")
            lines.append(x)
    new, rows, dup = [], [], 0
    for x in lines:
        if x["id"] in seen:
            dup += 1
            continue
        seen.add(x["id"])
        c = " ".join(compare(x["old"].encode(), x["new"].encode(), ignore, norm))
        r = {"id": x["id"], "at": x["at"], "lock": lock, "class": c}
        if c:
            r.update(request=x["request"], old=x["old"], new=x["new"])
            new.append((x["id"], c))
        rows.append(r)
    with open(os.path.join(j, "shadow.jsonl"), "a", encoding="utf-8") as fh:
        for r in rows:
            fh.write(json.dumps(r, ensure_ascii=False) + "\n")
    print(f"shadow: {len(rows)} compared, {len(new)} mismatches, {dup} already seen")
    for c, xs in classes(new):
        print(f"class {c} {len(xs)} {xs[0]}")
    print("window: " + window(j)[1])
    return 1 if new else 0


def cutover(j):
    go, text = window(j)
    print(f"cutover: {'go' if go else 'wait'}: {text}")
    return 0 if go else 1


def main():
    cmd = sys.argv[1]
    if cmd == "rules":
        print(sum(len(x) for x in rules(sys.argv[2])))
    elif cmd == "noise":
        noise(sys.argv[2])
    elif cmd == "shadow":
        sys.exit(shadow(sys.argv[2], sys.argv[3]))
    elif cmd == "cutover":
        sys.exit(cutover(sys.argv[2]))
    else:
        sys.exit(run(sys.argv[2], sys.argv[3]))


main()

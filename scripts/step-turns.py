import glob
import json
import os
import re
import sys

USAGE = 'usage: python3 -I scripts/step-turns.py tok2:<dir>|projects:<dir> <from>..<to> [tok2:<dir>|projects:<dir> <from>..<to>]'
STEPS = ('plan', 'task', 'verify', 'review', 'result')
ANCHOR = re.compile(r'forge (?:commit \S+ ([A-Za-z0-9_-]+)|(plan-done|task-done|verify-finish|finish) \S+)')
NEW = {'plan-done': 'plan', 'task-done': 'task', 'verify-finish': 'verify', 'finish': 'result'}
WINDOW = re.compile(r'(\d{4}-\d{2}-\d{2})\.\.(\d{4}-\d{2}-\d{2})')
SOURCE = re.compile(r'(tok2|projects):(.+)')


class Unreadable(Exception):
    pass


def load_json(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError) as e:
        raise Unreadable(f'{path}: {e}')


def read_lines(path):
    try:
        with open(path, errors='replace') as f:
            return f.readlines()
    except OSError as e:
        raise Unreadable(f'{path}: {e}')


def tok2(d):
    lines = read_lines(os.path.join(d, 'turns.jsonl'))
    meta = load_json(os.path.join(d, 'meta.json'))
    phase = {s['session'] for s in meta if s.get('stype') == 'forge-phase'}
    sessions = []
    for n, line in enumerate(lines, 1):
        try:
            r = json.loads(line)
        except ValueError as e:
            raise Unreadable(f'{d}/turns.jsonl:{n}: {e}')
        if r['session'] in phase:
            sessions.append([dict(ts=t['ts'], dup=t['dup'], tools=[(x[0], x[2]) for x in t['tools']]) for t in r['turns']])
    return sessions


def text_of(c):
    if isinstance(c, str):
        return c
    if isinstance(c, list):
        return '\n'.join(x.get('text', '') for x in c if isinstance(x, dict) and x.get('type') == 'text')
    return ''


def transcript(path):
    turns = {}
    order = []
    first_ts = None
    first_user = None
    bad = 0
    for line in read_lines(path):
        try:
            d = json.loads(line)
        except ValueError:
            bad += 1
            continue
        if not isinstance(d, dict):
            continue
        if first_ts is None and d.get('timestamp'):
            first_ts = d['timestamp']
        t = d.get('type')
        if t == 'user' and first_user is None:
            first_user = text_of((d.get('message') or {}).get('content'))
        if t != 'assistant':
            continue
        m = d.get('message') or {}
        mid = m.get('id') or d.get('uuid')
        if mid not in turns:
            turns[mid] = dict(mid=mid, ts=d.get('timestamp'), model=m.get('model'), u=None, tools=[])
            order.append(mid)
        e = turns[mid]
        if m.get('usage'):
            e['u'] = m['usage']
        for c in m.get('content') or []:
            if isinstance(c, dict) and c.get('type') == 'tool_use':
                inp = c.get('input') or {}
                e['tools'].append((c.get('name'), (inp.get('command') or inp.get('file_path') or '')[:1500]))
    if bad:
        print(f'step-turns: skipped {bad} unparsable line(s) in {path}', file=sys.stderr)
    out = [turns[k] for k in order if turns[k]['u'] and turns[k]['model'] != '<synthetic>']
    phase = '<command-name>/forge-phase' in (first_user or '')
    return first_ts or '', phase, out


def projects(d):
    try:
        os.listdir(d)
    except OSError as e:
        raise Unreadable(f'{d}: {e}')
    parsed = []
    for path in glob.glob(os.path.join(glob.escape(d), '*', '*.jsonl')):
        ts, phase, out = transcript(path)
        parsed.append((ts, os.path.basename(path)[:-6], phase, out))
    parsed.sort(key=lambda x: (x[0], x[1]))
    seen = set()
    sessions = []
    for _, _, phase, out in parsed:
        for t in out:
            t['dup'] = t['mid'] in seen
            seen.add(t['mid'])
        if phase:
            sessions.append(out)
    return sessions


def anchor(turn):
    for _, desc in turn['tools']:
        m = ANCHOR.search(desc or '')
        if m:
            if m.group(1):
                return 'task' if re.fullmatch(r'T\d+', m.group(1)) else m.group(1)
            return NEW[m.group(2)]
    return None


def count(sessions, lo, hi):
    total = 0
    occ = dict.fromkeys(STEPS, 0)
    single = dict.fromkeys(STEPS, 0)
    for turns in sessions:
        buf = 0
        for t in turns:
            if t['dup'] or not lo <= (t['ts'] or '')[:10] <= hi:
                continue
            one = sum(1 for name, _ in t['tools'] if name == 'Bash') == 1
            total += one
            buf += one
            st = anchor(t)
            if st:
                if st in occ:
                    occ[st] += 1
                    single[st] += buf
                buf = 0
    return total, occ, single


def per(turns, occ):
    return turns / occ if occ else None


def fmt(x):
    return '-' if x is None else f'{x:.1f}'


def main(argv):
    if len(argv) not in (2, 4):
        print(USAGE, file=sys.stderr)
        return 2
    pairs = []
    for i in range(0, len(argv), 2):
        s = SOURCE.fullmatch(argv[i])
        w = WINDOW.fullmatch(argv[i + 1])
        if not s or not w:
            print(USAGE, file=sys.stderr)
            return 2
        pairs.append((s.group(1), s.group(2), argv[i + 1], w.group(1), w.group(2)))
    lines = []
    fives = []
    try:
        for kind, d, label, lo, hi in pairs:
            sessions = tok2(d) if kind == 'tok2' else projects(d)
            total, occ, single = count(sessions, lo, hi)
            lines.append(f'{label} all {total}')
            for st in STEPS:
                lines.append(f'{label} {st} {occ[st]} {single[st]} {fmt(per(single[st], occ[st]))}')
            o, n = sum(occ.values()), sum(single.values())
            fives.append(per(n, o))
            lines.append(f'{label} five {o} {n} {fmt(fives[-1])}')
    except Unreadable as e:
        print(f'step-turns: cannot read {e}', file=sys.stderr)
        return 1
    if len(fives) == 2:
        a, b = fives
        lines.append('change -' if not a or b is None else f'change {(b - a) / a * 100:.1f}%')
    print('\n'.join(lines))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))

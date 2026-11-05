#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
st=$root/scripts/step-turns.py
fx=$root/tests/fixtures/step-turns
export LC_ALL=C
tmp=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$tmp"' EXIT

fail() { echo "step-turns: FAIL $*" >&2; exit 1; }
only=${1:-}
ok() { echo "step-turns $1: ok"; [ "$1" != "$only" ] || exit 0; }
want() { [ -z "$only" ] || [ "$only" = "$1" ]; }
run() { local s=0; python3 -I "$st" "$@" >"$tmp/out" 2>"$tmp/err" || s=$?; echo "$s"; }
golden() {
  local name=$1 s
  shift
  s=$(run "$@")
  [ "$s" = 0 ] || fail "$name: must exit 0, got $s: $(cat "$tmp/out" "$tmp/err")"
  diff -u "$tmp/want" "$tmp/out" >"$tmp/diff" || fail "$name: output differs from golden:
$(cat "$tmp/diff")
stderr: $(cat "$tmp/err")"
}
usage() {
  local s
  s=$(run "$@")
  [ "$s" = 2 ] || fail "usage: '$*' must exit 2, got $s: $(cat "$tmp/out" "$tmp/err")"
  cat "$tmp/out" "$tmp/err" | grep -qi usage || fail "usage: '$*' must print a usage line: $(cat "$tmp/out" "$tmp/err")"
}
unreadable() {
  local name=$1 s
  shift
  s=$(run "$@")
  [ "$s" = 1 ] || fail "unreadable: '$*' must exit 1, got $s: $(cat "$tmp/out" "$tmp/err")"
  cat "$tmp/out" "$tmp/err" | grep -qF -- "$name" || fail "unreadable: '$*' must name $name: $(cat "$tmp/out" "$tmp/err")"
}

base=2026-09-25..2026-10-15
later=2026-10-20..2026-10-21
tok2_want() {
  cat <<EOF
$base all 17
$base plan 2 4 2.0
$base task 2 3 1.5
$base verify 1 2 2.0
$base review 1 2 2.0
$base result 1 3 3.0
$base five 7 14 2.0
EOF
}
projects_want() {
  cat <<EOF
$later all 14
$later plan 2 3 1.5
$later task 2 3 1.5
$later verify 2 3 1.5
$later review 2 2 1.0
$later result 2 2 1.0
$later five 10 13 1.3
EOF
}

if want exists; then
  [ -f "$st" ] || fail "scripts/step-turns.py must exist"
  ok exists
fi

if want tok2; then
  tok2_want >"$tmp/want"
  golden tok2 "tok2:$fx/tok2" "$base"
  ok tok2
fi

if want projects; then
  projects_want >"$tmp/want"
  golden projects "projects:$fx/projects" "$later"
  ok projects
fi

if want change; then
  { tok2_want; projects_want; echo 'change -35.0%'; } >"$tmp/want"
  golden change "tok2:$fx/tok2" "$base" "projects:$fx/projects" "$later"
  ok change
fi

if want truncate; then
  mkdir -p "$tmp/long/p"
  python3 -I - "$tmp/long/p/s.jsonl" <<'PY'
import json, sys
u = {'input_tokens': 1, 'output_tokens': 1}
rows = [
    {'type': 'user', 'timestamp': '2026-10-20T09:00:00Z', 'message': {'role': 'user', 'content': '<command-name>/forge-phase</command-name>'}},
    {'type': 'assistant', 'timestamp': '2026-10-20T09:00:01Z', 'message': {'id': 'm1', 'model': 'm', 'usage': u, 'content': [{'type': 'tool_use', 'name': 'Bash', 'input': {'command': 'x' * 1490 + ' && forge commit 1 plan'}}]}},
    {'type': 'assistant', 'timestamp': '2026-10-20T09:00:02Z', 'message': {'id': 'm2', 'model': 'm', 'usage': u, 'content': [{'type': 'tool_use', 'name': 'Bash', 'input': {'command': 'forge commit 1 review'}}]}},
]
with open(sys.argv[1], 'w') as f:
    f.write(''.join(json.dumps(r) + '\n' for r in rows))
PY
  cat >"$tmp/want" <<EOF
$later all 2
$later plan 0 0 -
$later task 0 0 -
$later verify 0 0 -
$later review 1 2 2.0
$later result 0 0 -
$later five 1 2 2.0
EOF
  golden truncate "projects:$tmp/long" "$later"
  ok truncate
fi

if want usage; then
  usage
  usage "tok2:$fx/tok2"
  usage "tok2:$fx/tok2" 2026-09-25
  usage "tok2:$fx/tok2" 2026-09-25..
  usage "tok2:$fx/tok2" "$base" "projects:$fx/projects"
  usage "other:$fx/tok2" "$base"
  usage "$fx/tok2" "$base"
  usage "tok2:$fx/tok2" "$base" "tok2:$fx/tok2" "$base" "projects:$fx/projects" "$later"
  ok usage
fi

if want unreadable; then
  unreadable "$tmp/none" "tok2:$tmp/none" "$base"
  mkdir "$tmp/nometa"
  cp "$fx/tok2/turns.jsonl" "$tmp/nometa/"
  unreadable meta.json "tok2:$tmp/nometa" "$base"
  unreadable "$tmp/noproj" "tok2:$fx/tok2" "$base" "projects:$tmp/noproj" "$later"
  ok unreadable
fi

[ -z "$only" ] || fail "no case $only"

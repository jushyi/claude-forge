#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/../forge-common.sh"

lint() {
  local s=0
  LC_ALL=${loc:-C} bash -c 'set -euo pipefail; shopt -s nullglob; for m in "$1"/bin/forge.d/*.sh; do . "$m"; done; s=0; doc_lint "${@:2}" || s=$?; exit $s' _ "$root" "$@" >"$tmp/out" 2>"$tmp/err" || s=$?
  echo $s
}
seen() { echo "rc $1, stdout: $(cat "$tmp/out"), stderr: $(cat "$tmp/err")"; }
passes() {
  local m=$1 rc
  shift
  rc=$(lint "$@")
  [ "$rc" = 0 ] && [ ! -s "$tmp/err" ] && [ ! -s "$tmp/out" ] || fail "$m: doc_lint $* must return 0 and print nothing: $(seen "$rc")"
}
warns() {
  local m=$1 want=$2 rc
  shift 2
  rc=$(lint "$@")
  [ "$rc" = 0 ] || fail "$m: doc_lint $* must return 0: $(seen "$rc")"
  [ "$(cat "$tmp/err")" = "$want" ] || fail "$m: doc_lint $* must print exactly"$'\n'"$want"$'\n'"got: $(seen "$rc")"
  [ ! -s "$tmp/out" ] || fail "$m: doc_lint $* prints nothing on stdout: $(seen "$rc")"
}
rep() { local s= i; for ((i = 0; i < $2; i++)); do s+=$1; done; printf %s "$s"; }
scratch() { rm -rf "$tmp/d"; mkdir -p "$tmp/d"; cd "$tmp/d"; }
lines() { local n i; n=$1; for ((i = 0; i < n; i++)); do echo xxxxxxx; done; }

if want doc-lint-size; then
scratch
lines 1024 >ok.md
[ "$(wc -c <ok.md)" = 8192 ] || fail "fixture ok.md must be 8192 bytes"
passes "a file of exactly 8192 bytes" ok.md
cp ok.md big.md
printf x >>big.md
warns "a file of 8193 bytes" "forge: warning: big.md:1: over 8 KB (8193 bytes)" big.md
lines 1250 >huge.md
warns "a file of 10000 bytes" "forge: warning: huge.md:1: over 8 KB (10000 bytes)" huge.md
ok doc-lint-size
fi

if want doc-lint-length; then
scratch
x100=$(rep x 100)
printf -- '# Doc\n\n- %s\n  %s\n    %s\n\nTail.\n' "$x100" "$x100" "$(rep x 96)" >ok.md
passes "a 300-character bullet over continuation lines" ok.md
printf -- '# Doc\n\n- %s\n  %s\n    %s\n\nTail.\n' "$x100" "$x100" "$(rep x 97)" >long.md
warns "a 301-character bullet over continuation lines" "forge: warning: long.md:3: bullet over 300 characters (301)" long.md
printf -- '# Doc\n\n- %s\n' "$(rep x 298)" >one.md
passes "a one-line bullet of 300 characters with its marker" one.md
printf -- '# Doc\n\n- %s\n' "$(rep x 348)" >wide.md
warns "a one-line bullet of 350 characters" "forge: warning: wide.md:3: bullet over 300 characters (350)" wide.md
printf -- '- Parent.\n    - %s\n' "$(rep x 298)" >deep.md
passes "an indented bullet counted with its indent stripped" deep.md
ok doc-lint-length
fi

if want doc-lint-phrases; then
scratch
printf -- '# P\n\n- Forge now runs the gate.\n' >p1.md
printf -- '# P\n\n- The gate\n  no longer runs.\n' >p2.md
printf -- '# P\n\n- It was slow.\n' >p3.md
printf -- '# P\n\n- Previously the gate ran twice.\n' >p4.md
printf -- '# P\n\n- The hook USED TO block.\n' >p5.md
warns "now " 'forge: warning: p1.md:3: history phrase "now "' p1.md
warns "no longer on a continuation line" 'forge: warning: p2.md:3: history phrase "no longer"' p2.md
warns "was " 'forge: warning: p3.md:3: history phrase "was "' p3.md
warns "Previously at the bullet start" 'forge: warning: p4.md:3: history phrase "previously"' p4.md
warns "USED TO in capitals" 'forge: warning: p5.md:3: history phrase "used to"' p5.md
ok doc-lint-phrases
fi

if want doc-lint-code; then
scratch
cat >ok.md <<'EOF'
# Code

- Run `forge now --x` to start.
- The known issue stays.
- Snow melts in spring.
- Use `` `was here` `` for it.
- Run `git
  was here` today.
- Use `` was ` x `` here.
EOF
passes "phrases inside backtick spans and inside words" ok.md
printf -- '- A lone ` tick and it was fine.\n' >lone.md
warns "a phrase after an unmatched backtick" 'forge: warning: lone.md:1: history phrase "was "' lone.md
printf -- '- Mark `` then it was done ` ok.\n' >runs.md
warns "a phrase between runs of different lengths" 'forge: warning: runs.md:1: history phrase "was "' runs.md
ok doc-lint-code
fi

if want doc-lint-split; then
scratch
printf -- '# S\n\n- It was\n  later fixed.\n' >was.md
warns "was split across a continuation break" 'forge: warning: was.md:3: history phrase "was "' was.md
printf -- '- The gate now\n  runs.\n' >now.md
warns "now split across a continuation break" 'forge: warning: now.md:1: history phrase "now "' now.md
printf -- '- The hook used\n  to block.\n' >used.md
warns "used to split across a continuation break" 'forge: warning: used.md:1: history phrase "used to"' used.md
ok doc-lint-split
fi

if want doc-lint-prose; then
scratch
x400=$(rep x 400)
{
  echo "## It was now previously used to"
  echo
  echo "<!-- it was now no longer -->"
  echo
  echo "| Name | Note |"
  echo "|---|---|"
  echo "| row | $x400 it was now |"
  echo
  echo "It was now $x400 no longer used to previously."
  echo
  echo "- Short bullet."
  echo "It was a lazy line $x400"
  echo
  echo "- Another short bullet."
  echo
  echo "  It was an indented paragraph $x400"
} >prose.md
passes "headings, comments, tables and paragraphs over 300 with phrases" prose.md
ok doc-lint-prose
fi

if want doc-lint-nested; then
scratch
printf -- '- %s\n  - %s\n' "$(rep x 200)" "$(rep x 200)" >two.md
passes "a nested bullet is not joined into its parent" two.md
printf -- '- Parent.\n  - %s\n  %s\n' "$(rep x 250)" "$(rep x 100)" >equal.md
passes "an equally indented line ends a nested bullet" equal.md
printf -- '- Parent text\n  - It was nested\n    more.\n- Sibling.\n' >child.md
warns "a phrase in a nested bullet is reported at the nested line" 'forge: warning: child.md:2: history phrase "was "' child.md
printf -- '- Parent\n  continued.\n  - %s\n' "$(rep x 299)" >deep.md
warns "a nested bullet over 300 is reported at its own line" "forge: warning: deep.md:3: bullet over 300 characters (301)" deep.md
ok doc-lint-nested
fi

if want doc-lint-multibyte; then
scratch
e=$'\303\251' dash=$'\342\200\224' smile=$'\360\237\230\200'
printf -- '- %s\n' "$(rep "$e" 298)" >ok.md
printf -- '- %s\n' "$(rep "$e" 299)" >long.md
printf -- '- %s\n  %s\n  %s\n' "$(rep "$dash" 100)" "$(rep "$smile" 100)" "$(rep "$e" 97)" >mixed.md
for loc in C C.UTF-8; do
  passes "300 two-byte characters under LC_ALL=$loc" ok.md
  warns "301 two-byte characters under LC_ALL=$loc" "forge: warning: long.md:1: bullet over 300 characters (301)" long.md
  warns "301 characters of two, three and four bytes under LC_ALL=$loc" "forge: warning: mixed.md:1: bullet over 300 characters (301)" mixed.md
done
loc=
ok doc-lint-multibyte
fi

if want doc-lint-many; then
scratch
mkdir sub
{
  echo "# A"
  echo
  echo "- $(rep x 348)"
  echo "- Forge now gates."
  echo "- The gate"
  echo "  previously ran."
  echo "- Fine."
} >a.md
printf -- '# Ok\n\n- Fine.\n' >ok.md
lines 1125 >sub/b.md
printf -- '- The hook used to block.\n' >c.md
passes "several passing files" ok.md ./ok.md
warns "every violation of every file in order" "forge: warning: a.md:3: bullet over 300 characters (350)
forge: warning: a.md:4: history phrase \"now \"
forge: warning: a.md:5: history phrase \"previously\"
forge: warning: ./sub/b.md:1: over 8 KB (9000 bytes)
forge: warning: $tmp/d/c.md:1: history phrase \"used to\"" a.md ok.md ./sub/b.md "$tmp/d/c.md"
ok doc-lint-many
fi

if want doc-lint-unreadable; then
scratch
printf -- '# Ok\n\n- Fine.\n' >ok.md
rc=$(lint ok.md gone.md)
[ "$rc" != 0 ] || fail "an unreadable file must return nonzero: $(seen "$rc")"
ok doc-lint-unreadable
fi

finish

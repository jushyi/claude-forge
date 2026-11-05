#!/usr/bin/env bash
read -r -d '' defs <<'JQ' || true
def unq:
  if test("['\"\\\\]") | not then .
  else
  [scan("'[^']*'|\"(?:[^\"\\\\]|\\\\.)*\"|\\\\.|[^'\"\\\\]+")]
  | map(if startswith("'") then .[1:-1]
        elif startswith("\"") then .[1:-1] | gsub("\\\\(?<c>[\"\\\\$`])"; .c)
        elif startswith("\\") then .[1:]
        else . end)
  | join("") end;
def hre: "(?<op>(?<!<)<<-?[ \\t]*(?<q>['\"]?)(?<d>[A-Za-z_][A-Za-z0-9_]*)\\k<q>)(?<rest>[^\\n]*)\\n(?<body>(?:[^\\n]*\\n)*?)(?:[ \\t]*\\k<d>(?=\\n|\\)|$)|[^\\n]*\\z)";
def nohere:
  gsub(hre;
    "\(.op):\(.body // "" | split("\n")[0] // "" | sub("^[ \\t]+"; "") | @base64)\(.rest)");
def dq: "(?:[^\"\\\\]++|\\\\.)*+";
def open($q):
  if $q == 1 then (match("^[^']*'") // null) as $m | if $m then .[$m.length:] | open(0) else {q: 1, e: false} end
  elif $q == 2 then (match("^" + dq + "\"") // null) as $m
    | if $m then .[$m.length:] | open(0) else {q: 2, e: test("^" + dq + "\\\\$")} end
  else .[match("^(?:[^'\"\\\\]++|\\\\.|'[^']*'|\"" + dq + "\")*+").length:]
    | if . == "" then {q: 0, e: false}
      elif startswith("'") then {q: 1, e: false}
      elif startswith("\"") then .[1:] | open(2)
      else {q: 0, e: true} end end;
def chunks:
  split("\n") | . as $l | length as $n
  | range(0; [$n, 1] | max; 200) as $b | (if $b + 200 < $n then "\n" else null end) as $tail
  | $l[$b:$b + 200] | join("\n") | split(" ") | length as $w
  | range(0; [$w, 1] | max; 200) as $i | {c: (.[$i:$i + 200] | join(" ")), s: (if $i + 200 < $w then " " else $tail end)};
def groups:
  foreach chunks as $c ({q: 0, buf: null, out: null};
    .buf = (.buf // "") + $c.c | .out = null
    | .q as $q | ($c.c | open($q)) as $s | .q = $s.q
    | if $s.q == 0 and ($s.e | not) then .out = [.buf, ($c.s | select(. == "\n"))] | .buf = null
      elif $c.s then .buf += $c.s
      else .out = [.buf] end;
    .out // empty | .[]);
def toks:
  groups | if . == "\n" then . else scan("[0-9](?:>>|>&|>\\||>|<<<|<<-?|<)|(?:[^\\s;&|<>()'\"\\\\]|\\\\.|'[^']*'|\"(?:[^\"\\\\]|\\\\.)*\")+|&&|\\|\\||;;|&>>|>>|&>|>&|>\\||<<<|<<-?|[;&|\\n()<>]") end;
def segs:
  ({"&&": "s", "||": "s", ";": "s", ";;": "s", "|": "s", "&": "s", "\n": "s", "(": "s", ")": "s",
   ">": "o", ">|": "o", ">>": "o", "&>": "o", "&>>": "o", ">&": "d", "<<<": "k", "<<": "k", "<<-": "k", "<": "i"}
  | reduce range(10) as $d (.; ($d | tostring) as $n | (if $d == 1 then "o" else "e" end) as $e
      | .[$n + ">"] = $e | .[$n + ">|"] = $e | .[$n + ">>"] = $e | .[$n + ">&"] = (if $d == 1 then "d" else "k" end) | .[$n + "<"] = (if $d == 0 then "i" else "k" end)
      | .[$n + "<<"] = "k" | .[$n + "<<-"] = "k" | .[$n + "<<<"] = "k")) as $ops
  | reduce (toks, "\n") as $t ({out: [], w: [], o: [], r: [], i: [], f: false, n: null};
      $ops[$t] as $k
      | if .n == "o" then ($t | unq) as $u | .o[.o | length] = $u | .r[.r | length] = $u | .n = null
        elif .n == "e" then .o[.o | length] = ($t | unq) | .n = null
        elif .n == "i" then .i[.i | length] = ($t | unq) | .n = null
        elif .n == "d" then ($t | unq) as $u | (if $u | test("^[0-9]*-?$") then . else .o[.o | length] = $u | .r[.r | length] = $u end) | .n = null
        elif .n then .n = null
        elif $k == "s" then
          (if .w != [] or .o != [] or .i != [] then .out[.out | length] = ({w, o, r, i, f} + (if $t == "(" then {fp: true} else {} end)) | .w = [] | .o = [] | .r = [] | .i = [] | .f = ($t == "|")
           else .f = (.f or $t == "|") end)
        elif $k then .n = $k
        else .w[.w | length] = ($t | unq) end)
  | .out[];
def opt($s; $l):
  .w[0] as $a
  | if $a | startswith("--") then
      ($a | index("=")) as $i
      | if $i then {n: 1, o: $a[:$i], v: $a[$i + 1:]}
        elif $a | IN($l[]) then {n: 2, o: $a, v: .w[1]}
        else {n: 1, o: $a, v: null} end
    else (if $s == "" then null else first($a | capture("^-[^" + $s + "]*(?<o>[" + $s + "])(?<v>.*)$"), null) end) as $m
      | if $m == null then {n: 1, o: $a, v: null}
        elif $m.v == "" then {n: 2, o: ("-" + $m.o), v: .w[1]}
        else {n: 1, o: ("-" + $m.o), v: $m.v} end end;
def wrapped($s; $l):
  if (.w | length) == 0 then .
  elif .w[0] == "--" then .w |= .[1:]
  elif .w[0] | startswith("-") then
    opt($s; $l) as $x
    | .w |= .[$x.n:]
    | if $x.v == null then .
      elif $x.o | IN("-C", "--chdir") then .c += [$x.v]
      elif $x.o | IN("-S", "--split-string") then .w = [$x.v | segs | .w[]] + .w
      else . end
    | wrapped($s; $l)
  else . end;
def strip:
  {env: ["uCS", ["--unset", "--chdir", "--split-string"]], timeout: ["sk", ["--signal", "--kill-after"]],
   nice: ["n", ["--adjustment"]], nohup: ["", []], command: ["", []], builtin: ["", []], exec: ["a", []], stdbuf: ["ioe", ["--input", "--output", "--error"]],
   time: ["fo", ["--format", "--output"]],
   xargs: ["aEILnsPd", ["--arg-file", "--delimiter", "--max-args", "--max-procs", "--max-chars", "--process-slot-var"]]} as $wr
  | def go:
      if (.w | length) == 0 then .
      else .w[0] as $a | ($a | sub("^.*/"; "")) as $b
      | if $a | test("^[A-Za-z_][A-Za-z0-9_]*=") then (if $a | startswith("GIT_DIR=") or startswith("GIT_WORK_TREE=") or startswith("XDG_RUNTIME_DIR=") or startswith("BASH_ENV=") then .e += [$a] else . end) | .w |= .[1:] | go
        elif $a | IN("while", "until") then .l = (.l // "") + $a[:1] | .w |= .[1:] | go
        elif $a | IN("!", "{", "}", "if", "then", "else", "elif", "do") then .w |= .[1:] | go
        elif $wr[$b] then .w |= .[1:] | (if $b == "xargs" then .x = 1 else . end) | wrapped($wr[$b][0]; $wr[$b][1]) | (if $b == "timeout" then (.w[0] // "" | test("^([0-9]+\\.?[0-9]*|\\.[0-9]+)[smhd]?$") and test("[1-9]")) as $t | .w |= .[1:] | (if $t then .l = (.l // "") + "t" else . end) else . end) | go
        else . end end;
    go;
def cmds($k):
  gsub("\\\\\\n"; "") | nohere | segs | strip
  | (if .w[0] // "" | test("^(.*/)?(ba|z|da)?sh$") then .w | map(test("^-[a-zA-Z]*c[a-zA-Z]*$")) | index(true) else null end) as $i
  | if $i == null and .l then .l |= gsub("t"; "") else . end
  | if $i != null then
      . as $s | .l as $l | (reduce (.e // [])[] as $a ({}; .[$a | sub("=.*"; "")] = $a) | [.[]]) as $e
      | {w: [], o: [], p: "u", d: (.c // [])} as $u
      | [.w[$i + 1] // "" | cmds($k) | .e = $e + (.e // [])]
      | (if $l then .[0] = ((.[0] // {w: [], o: []}) | .l = $l + (.l // "")) else . end)
      | (if $k then $s else empty end), $u, .[], {w: [], o: [], p: "o", l: (if $l // "" | contains("t") then "t" else null end)}
    elif .w[0] == "eval" then ., ((.e // []) as $e | .w[1:] | join(" ") | cmds($k) | .e = $e + (.e // []))
    else . end;
def cmds: cmds(false);
def gatefns: ["records", "pending", "open_findings", "blocking", "phase_gate", "landed", "fixes", "branch_read", "build_state",
  "build_fails", "build_gate", "build_results", "finish", "gate", "reviewed", "checked", "tests_state", "tests_none"];
def heres: ., (match(hre; "g").string | sub("^[^\\n]*\\n"; "") | heres);
def internal($fd; $fb):
  if $fd and ((.w[0] // "" | IN(".", "source")) and (.w | length) > 1
      or (.w[0] // "" | test("^(.*/)?(ba|z|da)?sh$")) and any(.w[1:][]; test("^--(rcfile|init-file)(=|$)"))
      or any((.e // [])[], .w[]; startswith("BASH_ENV=")))
  then "sources a file while it names forge.d"
  elif .fp and (.w | length) == 1 and (.w[0] | IN($fb[])) then "defines forge gate function \(.w[0])"
  elif .w[0] == "function" and (.w[1] // "" | IN($fb[])) then "defines forge gate function \(.w[1])"
  else empty end;
def named($n): "(^|[^A-Za-z0-9_])(" + $n + ")([^A-Za-z0-9_]|$)";
def fre: named("forge\\.d|" + (gatefns | join("|")));
def bodied($n): "(^|[^A-Za-z0-9_])(function[ \\t]+" + $n + "([ \\t]*\\([ \\t]*\\))?|" + $n + "[ \\t]*\\([ \\t]*\\))[ \\t\\n]*\\{";
def internals:
  fre as $re | named("forge\\.d") as $dre
  | if test($re) or (unq | test($re)) then
      (test($dre) or (unq | test($dre))) as $fd
      | . as $t | unq as $u
      | [gatefns[] | bodied(.) as $b | select(($t | test($b)) or ($u | test($b)))] as $fb
      | first(heres | cmds(true) | internal($fd; $fb))
    else empty end;
def tnl: split("\n") | any(test("^- All tests: none[[:space:]]*$"));
def unqs: split("'") | join("") | split("\"") | join("") | split("\\") | join("");
def tnb($t): contains($t) or (unqs | contains($t));
JQ
read -r -d '' prog <<'JQ' || true
"tool=\(.tool_name // "" | @sh)",
"cwd=\(.cwd // "" | @sh)",
"agent=\(.agent_id // "" | @sh)",
"atype=\(.agent_type // "" | @sh)",
"path=\(.tool_input.file_path // .tool_input.notebook_path // "" | @sh)",
"fint=\(.tool_input.command // "" | first(internals) // "" | @sh)",
"cint=\({Edit: "new_string", Write: "content", NotebookEdit: "new_source"}[.tool_name // ""] as $k | if $k then .tool_input[$k] else null end | strings // "" | first(internals) // "" | @sh)",
"fcont=\({Edit: "new_string", Write: "content", NotebookEdit: "new_source"}[.tool_name // ""] as $k | if $k then .tool_input[$k] else null end | strings // "" | @sh)",
"tn=\({Edit: "new_string", Write: "content"}[.tool_name // ""] as $k | if $k and (.tool_input[$k] | strings // "" | contains("All tests: none") and tnl) and (.tool_name == "Write" or (.tool_input.old_string | strings // "" | tnl | not)) then .tool_name else "" end | @sh)",
(if .tool_name == "Edit" and (.tool_input.file_path | strings // "" | contains("TESTING.md")) then
  "te=1", "teo=\(.tool_input.old_string | strings // "" | @sh)", "ten=\(.tool_input.new_string | strings // "" | @sh)",
  "ter=\(if .tool_input.replace_all == true then 1 else "" end)"
else "te=" end),
(.tool_input.command // "" | strings // "" | if tnb("All tests: none") and tnb("TESTING.md") then
  "tb=1", "tc=\(gsub("\\\\\\n"; "") | unqs | split("TESTING.md") | [length - 1, 0] | max)"
else "tb=", "tc=0" end),
"fre=\(fre | @sh)",
"segs=()",
(.tool_input.command // "" | cmds | "segs+=(\("envs=(\(.e // [] | @sh)); outs=(\(.o | @sh)); souts=(\(.r // [] | @sh)); ins=(\(.i // [] | @sh)); pf=\(if .f then 1 else "" end); cds=(\(.c // [] | @sh)); pd=(\(.d // [] | @sh)); pp=\(.p // ""); xa=\(.x // ""); lp=\(.l // ""); seg \(.w | @sh)" | @sh))")
JQ

deny() {
  echo "forge-guard: $1: $2" >&2
  exit 42
}

abs() {
  ap=$1
  case $ap in
    '~' | '$HOME' | '${HOME}') ap=$HOME ;;
    '~/'*) ap=$HOME/${ap#'~/'} ;;
    '$HOME/'*) ap=$HOME/${ap#'$HOME/'} ;;
    '${HOME}/'*) ap=$HOME/${ap#'${HOME}/'} ;;
  esac
  case $ap in /*) ;; *) ap=$2/$ap ;; esac
}

expand() {
  local ap
  abs "$1" "$2"
  realpath -m -- "$ap"
}

paths() {
  local d=$1 p ap out
  xs=()
  shift
  [ $# -gt 0 ] || return 0
  for p; do
    abs "$p" "$d"
    xs+=("$ap")
  done
  out=$(realpath -m -- "${xs[@]}") || exit 1
  mapfile -t xs <<<"$out"
}

repo() {
  local out
  out=$(git -C "$1" "${go[@]}" rev-parse --path-format=absolute --git-dir --git-common-dir --show-toplevel 2>/dev/null) || return 1
  { read -r gd; read -r gc; read -r top; } <<<"$out"
}

repo_of() {
  local d=${1%/*}
  while [ -n "$d" ] && [ ! -d "$d" ]; do d=${d%/*}; done
  repo "${d:-/}"
}

main_root() {
  repo "$1" && [ "$gd" = "$gc" ] || return 1
  [ ! -d "${gc%/*}/.forge" ] || top=${gc%/*}
  [ -d "$top/.forge" ]
}

in_forge() {
  local d=$1
  while [ -n "$d" ]; do
    [ ! -d "$d/.forge" ] || return 0
    case $d in */.git) return 1 ;; esac
    d=${d%/*}
  done
  return 1
}

forge_repo() {
  local m
  case $gc in */.git) m=${gc%/.git} ;; *) m=$top ;; esac
  [ -f "$m/.forge/PROJECT.md" ] && [ -d "$m/bin/forge.d" ] || return 1
  frt=$m
}

froot() {
  local gd gc top d
  local -a go=()
  if [ -z "${fcw+x}" ]; then
    fcw=
    fdf=$h/.local/share/forge/no-source
    if [ -r "$h/.local/state/forge/port.json" ] && [[ $(<"$h/.local/state/forge/port.json") =~ \"source\":\ *\"([^\"]+)\" ]]; then fdf=${BASH_REMATCH[1]}; fi
    fdf=$(realpath -m -- "$fdf") || exit 1
    ! { repo "$cwd" && forge_repo; } || fcw=$frt
  fi
  frt=${fcw:-$fdf}
  [ -z "$fcw" ] && [ -n "${1:-}" ] || return 0
  d=${1%/*}
  while [ -n "$d" ] && [ ! -d "$d" ]; do d=${d%/*}; done
  d=${d:-/}
  if [ -z "${frc[k$d]+x}" ]; then
    frc[k$d]=
    ! { repo "$d" && forge_repo; } || frc[k$d]=$frt
  fi
  frt=${frc[k$d]:-$fdf}
}

fscript() {
  case $1 in
    "$h"/.local/bin/forge | "$h"/.local/bin/forge.d | "$h"/.local/bin/forge.d/* | "$h"/.claude/forge | "$h"/.claude/forge/*) return 0 ;;
    */bin/forge.d | */bin/forge.d/*) ;;
    *) return 1 ;;
  esac
  froot "$1"
  case $1 in
    "$frt"/bin/forge.d | "$frt"/bin/forge.d/* | "$frt"/.claude/worktrees/*/bin/forge.d | "$frt"/.claude/worktrees/*/bin/forge.d/*) return 0 ;;
  esac
  return 1
}

fsrc() {
  local p
  paths "$@"
  for p in "${xs[@]}"; do
    if fscript "$p"; then
      fs=$p
      return 0
    fi
  done
  return 1
}

tgt() {
  local p
  paths "$@"
  [ ${#xs[@]} -gt 0 ] || return 1
  for p in "${xs[@]}"; do
    froot "$p"
    case $p in
      /dev/null | "$frt" | "$frt"/*) ;;
      *)
        ft=$p
        return 0
        ;;
    esac
  done
  return 1
}

fsums() {
  froot "$1"
  [ -n "${fsm[k$frt]+x}" ] ||
    fsm[k$frt]=$(find "$h"/.local/bin/forge* "$h"/.claude/forge "$frt"/bin/forge.d -type f -print0 2>/dev/null | xargs -0 -r sha256sum 2>/dev/null)
}

fcopy() {
  local x
  froot "$2"
  case $2 in "$frt" | "$frt"/*) return 1 ;; esac
  fsums "$2"
  x=$(grep -m1 "^$1 " <<<"${fsm[k$frt]}") || return 1
  fs=${x#*  }
}

fwrite() {
  local x c=${fcont%$'\n'}
  [ -n "$c" ] || return 0
  for x in "$c" "$c"$'\n'; do
    x=$(printf '%s' "$x" | sha256sum) || exit 1
    if fcopy "${x%% *}" "$1"; then
      deny forge-copy "$2 writes $1 with the content of forge script $fs, outside the forge repo $frt and its worktrees; change forge in the forge repo through a phase, never a copy"
    fi
  done
}

shargs() {
  local k=
  shift
  while [ $# -gt 0 ]; do
    if [ -n "$k" ]; then
      k=
    else
      case $1 in
        -o | -O | +o | +O | --rcfile | --init-file) k=1 ;;
        -* | +*) ;;
        *) break ;;
      esac
    fi
    shift
  done
  sa=("$@")
}

frun() {
  local rf= b p d=$1 c=$3
  local -a sa=()
  case $2 in
    bash | sh | zsh | dash)
      shargs "${@:3}"
      rf=${sa[0]-}
      ;;
    *)
      case $3 in
        source | .) rf=${4-} ;;
        */*) rf=$3 ;;
      esac
      ;;
  esac
  [ -n "$rf" ] || return 0
  b=${rf%"${rf##*[!/]}"}
  p=$(expand "$rf" "$d")
  case $p in "$h"/.local/bin/forge | "$h"/.local/bin/forge.d/* | "$h"/.claude/forge/*) return 0 ;; esac
  if [ -f "$p" ] && [ -r "$p" ] && b=$(sha256sum -- "$p") && fcopy "${b%% *}" "$p"; then
    deny forge-copy "$c runs $p, a copy of forge script $fs, outside the live install and the forge repo $frt and its worktrees; change forge in the forge repo through a phase, never a copy"
  fi
  fscan "$p" "$c"
}

fscan() {
  local t r
  [ -f "$1" ] && [ -r "$1" ] || return 0
  if IFS= read -r -d '' -n 80 t <"$1" && [ ${#t} -lt 80 ] && [[ $t != *$'\n'* ]]; then return 0; fi
  t=$(tr -d '\0' <"$1") || exit 1
  [[ $t =~ $fre ]] || { r=${t//[\'\"\\]/} && [[ $r =~ $fre ]]; } || return 0
  froot "$1"
  case $1 in "$frt" | "$frt"/*) return 0 ;; esac
  r=$(jq -Rrs "$defs
first(internals) // \"\"" <<<"$t") || exit 1
  [ -z "$r" ] || deny forge-internals "$2 runs $1, outside the forge repo $frt and its worktrees, and the script $r; run the forge command itself (for example forge done N) instead of sourcing or redefining forge's internals, and report a gate it cannot pass"
}

forge_session() { [ -n "${FORGE_ROOT:-}" ] || in_forge "$cwd" || in_forge "$1"; }

root_rule() {
  local d=$1 sub=$2 a bad= mv= n=0
  shift 2
  case $sub in
    switch | pull | reset | restore | clean) bad=1 ;;
    rebase | cherry-pick | merge) case $#:${1:-} in 1:--abort | 1:--quit) ;; *) bad=1 ;; esac ;;
    checkout) [ $# = 0 ] || bad=1 ;;
    stash) case ${1:-} in list | show) ;; *) bad=1 ;; esac ;;
    commit) for a; do case $a in --amend) bad=1 ;; esac; done ;;
    branch)
      for a; do case $a in -m | -M | --move) mv=1 ;; -*) ;; *) n=$((n + 1)) ;; esac; done
      [ -z "$mv" ] || [ $n != 1 ] || bad=1
      ;;
  esac
  [ -z "$xa" ] || case $sub in switch | checkout | restore | clean | reset | rebase | merge | pull | cherry-pick | stash | branch | commit | '' | *[!a-z-]*) bad=1 ;; esac
  if [ -n "$bad" ] && main_root "$d"; then
    deny root-checkout "git $sub in $top, a forge project's main checkout that other sessions share; work in a worktree (git worktree add $top/.claude/worktrees/<name>, or under the job tmp dir) and land it via forge land or forge golive"
  fi
}

main_ref_rule() {
  local d=$1 sub=$2 a force= op= m= h= nd= ref= w= all
  local -a n=()
  shift 2
  all=$*
  case $sub in
    update-ref)
      while [ $# -gt 0 ]; do
        case $1 in
          --stdin) m=1 ;;
          --no-deref) nd=1 ;;
          -m) [ $# -lt 2 ] || shift ;;
          -*) ;;
          *) [ -n "$ref" ] || ref=$1 ;;
        esac
        shift
      done
      case $ref in
        refs/heads/main) m=1 ;;
        HEAD) if [ -n "$nd" ]; then m=1; else h=1; fi ;;
      esac
      ;;
    symbolic-ref)
      while [ $# -gt 0 ]; do
        case $1 in
          -d | --delete) w=1 ;;
          -m) [ $# -lt 2 ] || shift ;;
          -*) ;;
          *) n+=("$1") ;;
        esac
        shift
      done
      [ ${#n[@]} -lt 2 ] || w=1
      [ -z "$w" ] || case ${n[0]:-} in HEAD | refs/heads/main) m=1 ;; esac
      ;;
    branch)
      for a; do
        case $a in
          -f | --force) force=1 ;;
          -D | -d | --delete) op=del ;;
          -m | -M | --move) op=move ;;
          -c | -C | --copy) op=copy ;;
          -*) ;;
          *) n+=("$a") ;;
        esac
      done
      [ ${#n[@]} = 0 ] || case $op in
        del | move) for a in "${n[@]}"; do [ "$a" != main ] || m=1; done ;;
        copy) [ "${n[-1]}" != main ] || m=1 ;;
        *) [ -z "$force" ] || [ "${n[0]}" != main ] || m=1 ;;
      esac
      ;;
  esac
  [ -z "$xa" ] || case $sub in update-ref | symbolic-ref | branch | '' | *[!a-z-]*) m=1 ;; esac
  [ -n "$m$h" ] && repo "$d" || return 0
  [ -d "$top/.forge" ] || [ -d "${gc%/*}/.forge" ] || return 0
  [ -z "$h" ] || [ "$(git -C "$d" "${go[@]}" symbolic-ref -q HEAD)" = refs/heads/main ] || return 0
  deny main-ref "git $sub $all moves main or a checkout's HEAD in forge project ${gc%/*}, which every session shares; main moves only through forge commit, forge land and forge golive, and HEAD only by switching branches in your own worktree"
}

commit_rule() {
  local d=$1 msg= found= subj re
  shift
  while [ $# -gt 0 ]; do
    case $1 in
      --message=*) msg=${1#*=} ;;
      -m | --message | -[!-]*m) msg=${2-} ;;
      -m*) msg=${1#-m} ;;
      *)
        shift
        continue
        ;;
    esac
    found=1
    break
  done
  [ -n "$found" ] || return 0
  repo "$d" || return 0
  [ -d "$top/.forge" ] || [ -d "${gc%/*}/.forge" ] || return 0
  case $msg in
    *'<<'*)
      re=$'<<-?[ \t]*[\'"]?[A-Za-z_][A-Za-z0-9_]*[\'"]?:([A-Za-z0-9+/=]*)'
      [[ $msg =~ $re ]] || return 0
      subj=$(base64 -d <<<"${BASH_REMATCH[1]}") || return 0
      ;;
    *'$'* | *'`'*) return 0 ;;
    *) subj=${msg%%$'\n'*} ;;
  esac
  re='^(feat|fix|refactor|perf|test|docs|build|ci|chore|style|revert)(\([^)]+\))?!?: .+'
  if ! [[ $subj =~ $re || $subj =~ ^(forge\(|Revert\ \"|fixup!\ |squash!\ |amend!\ |Merge\ ) ]]; then
    deny conventional-commit "commit subject \"$subj\" in forge-managed repo $top is not Conventional Commits; use <type>(<scope>)?!?: <summary> with type feat, fix, refactor, perf, test, docs, build, ci, chore, style or revert"
  fi
}

git_rules() {
  local d=$dir sub a gdir= wtree=
  local -a go=()
  for a in "${envs[@]}"; do
    case $a in
      GIT_DIR=*) gdir=${a#*=} ;;
      GIT_WORK_TREE=*) wtree=${a#*=} ;;
    esac
  done
  while [ $# -gt 0 ]; do
    case $1 in
      -C)
        [ $# -ge 2 ] || return 0
        d=$(expand "$2" "$d")
        shift 2
        ;;
      --git-dir=*) gdir=${1#*=} && shift ;;
      --work-tree=*) wtree=${1#*=} && shift ;;
      --git-dir | --work-tree)
        [ $# -ge 2 ] || return 0
        if [ "$1" = --git-dir ]; then gdir=$2; else wtree=$2; fi
        shift 2
        ;;
      -c | --namespace | --config-env)
        [ $# -ge 2 ] || return 0
        shift 2
        ;;
      -*) shift ;;
      *) break ;;
    esac
  done
  [ $# -gt 0 ] || [ -n "$xa" ] || return 0
  [ -z "$gdir" ] || go+=(--git-dir="$(expand "$gdir" "$d")")
  [ -z "$wtree" ] || go+=(--work-tree="$(expand "$wtree" "$d")")
  sub=${1-}
  [ $# = 0 ] || shift
  root_rule "$d" "$sub" "$@"
  main_ref_rule "$d" "$sub" "$@"
  [ "$sub" != commit ] || commit_rule "$d" "$@"
  if [ "$sub" = stash ] && [ "${1:-}" != list ] && [ "${1:-}" != show ] && forge_session "$d"; then
    deny stash "git stash shares one stack across every worktree and session of the repo; commit a WIP or keep the change in your own worktree"
  fi
}

live() {
  local m
  case $1 in
    "$h"/.claude/settings.json) return 1 ;;
    "$h"/.claude/forge | "$h"/.claude/forge/*) return 0 ;;
  esac
  if [ -z "${man+x}" ]; then
    man=()
    [ ! -f "$h/.local/state/forge/port.manifest" ] || mapfile -t man <"$h/.local/state/forge/port.manifest"
    man=("${man[@]/#"$HOME"/$h}")
  fi
  for m in "${man[@]}"; do
    case $m in "$1" | "$1"/*) return 0 ;; esac
  done
  return 1
}

owned() {
  local r
  [ -n "${sb:-}" ] || sb=$(realpath -m -- "${XDG_STATE_HOME:-$HOME/.local/state}/forge") || exit 1
  case $1 in "$sb"/*/*) ;; *) return 1 ;; esac
  r=${1#"$sb"/}
  r=.forge/${r#*/}
  case $r in
    .forge/phases/*/plan.json | \
      .forge/phases/*/merge/*.json | .forge/features/*/docs.json | \
      .forge/features/*/fixes/*.json | .forge/features/*/merge/*.json | .forge/features/*/research/*.json | \
      .forge/features/*/review/reviewer.json | .forge/features/*/review/reviewer-*.json | \
      .forge/features/*/review/audit.json)
      return 0
      ;;
  esac
  return 1
}

write_rules() {
  oldstate "$1"
  if live "$1"; then
    deny live-install "$1 is part of the live forge install; change the forge repo and port it (./port, then ./port --apply once approved)"
  fi
  if [ -z "$agent" ] && owned "$1"; then
    deny agent-record "$1 is a forge agent's record; rerun the agent; don't edit its record"
  fi
  if [ -n "$agent" ] && judged "$1"; then
    deny port-judge "$1 is in a /forge-port judge, and only the operator changes a /forge-port judge; report what you cannot match instead"
  fi
}

judged() {
  [ -n "${sb:-}" ] || sb=$(realpath -m -- "${XDG_STATE_HOME:-$HOME/.local/state}/forge") || exit 1
  case $1 in "$sb"/*/port | "$sb"/*/port/*) return 0 ;; esac
  return 1
}

oldstate() {
  local gd gc top r m
  local -a go=()
  case $1 in */.forge/archive/* | */.forge/phases/* | */.forge/features/*) ;; *) return 0 ;; esac
  repo_of "$1" || return 0
  r=${1#"$top"/}
  case $r in .forge/archive/* | .forge/phases/* | .forge/features/*) ;; *) return 0 ;; esac
  case $gc in */.git) m=${gc%/.git} ;; *) m=$top ;; esac
  deny old-state "$1 is in $top/.forge/, but forge phase, feature and archive records live in the forge state dir: write ${XDG_STATE_HOME:-$HOME/.local/state}/forge/${m##*/}/${r#.forge/}"
}

planning_rule() {
  local r
  oldstate "$1"
  case $1 in */.forge/tracks/*) ;; *) return 0 ;; esac
  repo_of "$1" && [ "$gd" != "$gc" ] || return 0
  r=${1#"$top"/}
  case $r in .forge/tracks/*) ;; *) return 0 ;; esac
  if [ "$atype" = forge-merger ] && [ -f "$gd/MERGE_HEAD" ] && [ -n "$(git -C "$top" ls-files -u -- "$r")" ]; then
    return 0
  fi
  deny planning-path "$1 is in linked worktree $top, whose .forge/ copy is stale; forge planning state lives in the main worktree: write ${gc%/*}/$r"
}

code_rule() {
  local d
  [ -z "$agent" ] || return 0
  [ -n "${FORGE_PHASE:-}" ] || { [ -n "${FORGE_ROOT:-}" ] && [[ $cwd =~ /\.claude/worktrees/[^/]+-[0-9]+(/|$) ]]; } || return 0
  case $1 in */.forge/*) return 0 ;; esac
  d=${1%/*}
  while [ -n "$d" ] && [ ! -d "$d" ]; do d=${d%/*}; done
  if [ "$(git -C "${d:-/}" rev-parse --is-inside-work-tree 2>/dev/null)" = true ]; then
    deny orchestrator-code "a forge phase session's main agent must not edit code ($1); spawn forge-fixer / forge-implementer"
  fi
}

copies() {
  local c=${1##*/} t= nt= d s
  local -a src=()
  shift
  while [ $# -gt 0 ]; do
    case $c:$1 in
      *:-t | *:--target-directory)
        t=${2:-}
        [ $# -lt 2 ] || shift
        ;;
      *:--target-directory=*) t=${1#*=} ;;
      rsync:-[efT] | rsync:--exclude | rsync:--include | rsync:--filter | rsync:--files-from | rsync:--rsh | \
        install:-[mog] | *:-S | *:--suffix) [ $# -lt 2 ] || shift ;;
      *:-T | *:--no-target-directory) nt=1 ;;
      *:-*) ;;
      *) src+=("$1") ;;
    esac
    shift
  done
  if [ -n "$t" ]; then
    d=$t
  else
    [ ${#src[@]} -gt 0 ] || return 0
    d=${src[-1]}
    unset 'src[-1]'
  fi
  case $c in cp | rsync | install) cps+=("${src[@]}") ;; esac
  if [ -z "$t" ] && { [ -n "$nt" ] || { [[ $d != */ ]] && [ ${#src[@]} -lt 2 ] && [ ! -d "$(expand "$d" "$dir")" ]; }; }; then
    tg+=("$d")
    return 0
  fi
  for s in "${src[@]}"; do
    if [ "$c" = rsync ] && [[ $s == */ ]]; then
      tg+=("$d")
    else
      s=${s%"${s##*[!/]}"}
      tg+=("${d%/}/${s##*/}")
    fi
  done
}

suite_of() {
  local d=$1 l a= g= t= re='^- (All tests|Changed tests|Test):[^`]*`([^`]*)`'
  local -a ls
  [[ $d == /* ]] || d=
  while [ -n "$d" ] && [ ! -e "$d/.git" ]; do d=${d%/*}; done
  [ -z "${sroot+x}" ] || [ "$d" != "$sroot" ] || return 0
  sroot=$d
  sall=()
  schg=()
  sone=()
  [ -n "$d" ] && [ -f "$d/.forge/TESTING.md" ] || return 0
  mapfile -t ls <"$d/.forge/TESTING.md"
  for l in "${ls[@]}"; do
    [[ $l =~ $re ]] || continue
    case ${BASH_REMATCH[1]} in
      All*)
        [ -n "$a" ] || read -ra sall <<<"${BASH_REMATCH[2]//\{files\}/}"
        a=1
        ;;
      Changed*)
        [ -n "$g" ] || read -ra schg <<<"${BASH_REMATCH[2]//\{files\}/}"
        g=1
        ;;
      *)
        [ -n "$t" ] || read -ra sone <<<"${BASH_REMATCH[2]}"
        t=1
        ;;
    esac
  done
  for l in "${!sone[@]}"; do
    d=${sone[l]//\\/\\\\}
    d=${d//\*/\\*}
    d=${d//\?/\\?}
    d=${d//\[/\\[}
    d=${d//\(/\\(}
    sone[l]=${d//\{test\}/*}
  done
}

runs() {
  local -n w=$1
  local i
  shift
  [ ${#w[@]} -gt 0 ] && [ $# = ${#w[@]} ] || return 1
  for i in "${!w[@]}"; do [ "${w[i]}" = "${@:i+1:1}" ] || return 1; done
}

one() {
  local i
  for i in "${!sone[@]}"; do [[ ${@:i+1:1} == ${sone[i]} ]] || return 1; done
}

jbc() {
  local a k= v
  case ${1##*/} in
    chrome | google-chrome* | chromium*)
      for a in "${@:2}"; do
        if [ -n "$k" ]; then
          k=
          a=--user-data-dir=$a
        fi
        case $a in
          --remote-debugging-port=9222 | --remote-debugging-port=*'$'* | --remote-debugging-port=*'`'* | --user-data-dir=*.jev-browser-control*) return 0 ;;
          --user-data-dir) k=1 ;;
          --user-data-dir=*)
            v=${a#*=}
            case $v in '$HOME' | '${HOME}' | '$HOME/'* | '${HOME}/'*) v=${v#*HOME} ;; esac
            case $v in *'$'* | *'`'*) return 0 ;; esac
            ;;
        esac
      done
      ;;
    node)
      for a in "${@:2}"; do
        case $a in *.local/share/forge/jbc/server.mjs) return 0 ;; esac
      done
      ;;
  esac
  return 1
}

seg() {
  local a t ip= c re b od fs= ft e ap ev= wt= k
  local -a tg=() cps=() xs=() pc=("${pq[@]}")
  pq=()
  case $pp in
    u)
      dstk+=("$dir")
      for c in "${pd[@]}"; do dir=$(expand "$c" "$dir"); done
      ;;
    o)
      dir=${dstk[-1]}
      unset 'dstk[-1]'
      [ -z "$lp" ] || lps=${lps%t*}
      lp=
      ;;
  esac
  od=$dir
  for t in "${outs[@]}"; do
    e=$(expand "$t" "$dir")
    write_rules "$e"
  done
  if [ ${#cds[@]} -gt 0 ]; then
    local dir=$dir
    for c in "${cds[@]}"; do dir=$(expand "$c" "$dir"); done
  fi
  if [ -n "$tb" ]; then
    for t in "${outs[@]}" "${ins[@]}"; do tn_seg "$t" "$od"; done
    [ "${1:-}" != eval ] || ev=1
    for t; do tn_seg "$t" "$dir" "$ev"; done
  fi
  [ -z "$xa" ] || case ${1:-} in
    cp | mv | install | rsync | ln | tee | sponge | sed)
      for a in "${@:2}"; do case $a in --*=*) tg+=("${a#*=}") ;; -*) ;; *) tg+=("$a") ;; esac; done
      ;;
  esac
  case ${1:-} in
    for | select) lps+=f ;;
    done) lps=${lps%?} ;;
  esac
  c=${1:-}
  b=${c##*/}
  [ "$b" != sleep ] || wt=sleep
  [ "$c" != read ] || for a in "${@:2}"; do
    case $a in -*) a=${a#-} && a=${a%%[adinNpu]*} && [[ $a != *t* ]] || wt="read -t" ;; esac
  done
  [ "$c" != read ] || [ -n "$wt" ] || case $lp in *w) lp=${lp%w}W ;; *u) lp=${lp%u}U ;; *) lp=$lp${lp:+r} ;; esac
  lps+=$lp
  re='\$\([[:space:]]*([^[:space:])]*/)?(pgrep|ps)([[:space:])]|$)'
  if [[ $lps == *[wu]* ]] && [[ ${c##*/} == pgrep || ${c##*/} == ps || $* =~ $re ]]; then
    deny polling "a pgrep/ps wait loop; wait on a command that exits"
  fi
  if [ -n "$wt" ] && [ -n "${FORGE_ROOT:-}${FORGE_PHASE:-}" ]; then
    k=${lps%%t*}
    k=${k//[^wuWU]/}
    case ${k: -1} in [wW]) k=while ;; [uU]) k=until ;; *) k= ;; esac
    [ -z "$k" ] || deny polling "a $k loop that waits with $wt; run the command once with run_in_background and wait for its completion notification; don't poll"
  fi
  if [ -z "$agent" ] && [ -n "${FORGE_ROOT:-}${FORGE_PHASE:-}" ]; then
    [ "$b" != sleep ] || [ ${#dstk[@]} -gt 0 ] || deny polling "$* in the main agent of a forge-launched session; wait for the agent's completion notification; don't poll"
    [ "$b" != claude ] || ! cagents "${@:2}" || deny polling "$* in the main agent of a forge-launched session; wait for the agent's completion notification; don't poll"
  fi
  if [ -n "$agent" ] && [ "$b" = forge ] && [[ ${2:-} == @(replay|shadow) ]]; then
    deny port-judge "$* changes a /forge-port judge, and only the operator changes a /forge-port judge; report what you cannot match instead"
  fi
  if [ $# -gt 0 ] && jbc "$@"; then
    deny jbc-browser "run forge-browser start [--headed] instead of launching Chrome or JBC yourself"
  fi
  if [ $# -gt 0 ] && [ -n "${FORGE_ROOT:-}${FORGE_PHASE:-}" ]; then
    suite_of "$dir"
    if { runs sall "${@:1:${#sall[@]}}" || runs schg "${@:1:${#schg[@]}}"; } && { [ $# != ${#sone[@]} ] || ! one "$@"; }; then
      deny test-bypass "$* runs a test suite of $sroot/.forge/TESTING.md directly, which skips forge test's machine-wide test run semaphore; run forge test (forge test --changed for the changed suites, forge test --one <id> for one test)"
    fi
    [ "${1##*/}" != forge ] || case ${2:-} in
      test)
        for a in "${envs[@]}"; do
          case $a in XDG_RUNTIME_DIR=*) deny test-bypass "$* overrides XDG_RUNTIME_DIR, which moves forge test outside its machine-wide test run semaphore; run forge test without XDG_RUNTIME_DIR" ;; esac
        done
        ;;
    esac
  fi
  [ $# = 0 ] || frun "$dir" "$b" "$@"
  case ${1:-} in
    cd | pushd) dir=$(expand "${2:-$HOME}" "$dir") ;;
    git)
      shift
      git_rules "$@"
      ;;
  esac
  case $b in
    cp | mv | install | rsync | ln) copies "$@" ;;
    cat) for a in "${@:2}"; do case $a in -*) ;; *) cps+=("$a") ;; esac; done ;;
    tee | sponge)
      shift
      for a; do case $a in -*) ;; *) tg+=("$a") ;; esac; done
      ;;
    sed)
      shift
      for a; do case $a in -i* | --in-place*) ip=1 ;; esac; done
      [ -z "$ip" ] || for a; do case $a in -*) ;; *) tg+=("$a") ;; esac; done
      ;;
  esac
  for t in "${tg[@]}"; do
    e=$(expand "$t" "$dir")
    write_rules "$e"
  done
  case $b in
    cp | install | rsync) fsrc "$dir" "${cps[@]}" && tgt "$dir" "${tg[@]}" && copy_deny ;;
    cat | tee)
      [ -z "$pf" ] || pq=("${pc[@]}")
      for a in "${cps[@]}"; do
        abs "$a" "$dir"
        pq+=("$ap")
      done
      for a in "${ins[@]}"; do
        abs "$a" "$od"
        pq+=("$ap")
      done
      [ ${#souts[@]} -gt 0 ] || [ ${#tg[@]} -gt 0 ] || return 0
      fsrc / "${pq[@]}" && { tgt "$od" "${souts[@]}" || tgt "$dir" "${tg[@]}"; } && copy_deny
      ;;
  esac
  return 0
}

cagents() {
  local a k=
  for a; do
    if [ "$k" = 1 ] || { [ "$k" = 2 ] && [ "${a#-}" = "$a" ]; }; then
      k=
      continue
    fi
    k=
    case $a in
      --settings | --setting-sources | --model | --fallback-model | --agent | --agents | --add-dir | --mcp-config | --permission-mode | \
        --session-id | --allowedTools | --allowed-tools | --disallowedTools | --disallowed-tools | --tools | --append-system-prompt | \
        --system-prompt | --output-format | --input-format | --plugin-dir | --max-turns | --effort | -n | --name | --autocompact | \
        --betas | --debug-file | --environment | --file | --json-schema | --max-budget-usd | --permission-prompts | --plugin-url | \
        --remote-control-session-name-prefix | --system-prompt-snapshot | --append-system-prompt-file | --system-prompt-file) k=1 ;;
      --cloud | -d | --debug | --from-pr | --prompt-suggestions | --remote-control | -r | --resume | --teleport | -w | --worktree) k=2 ;;
      -*) ;;
      agents) return 0 ;;
      *) return 1 ;;
    esac
  done
  return 1
}

tn_free() {
  local r
  froot "$1"
  case $1 in
    "$frt"/tests/*) return 0 ;;
    "$frt"/.claude/worktrees/*)
      r=${1#"$frt"/.claude/worktrees/}
      case ${r#*/} in tests/*) return 0 ;; esac
      ;;
  esac
  return 1
}

tn_seg() {
  local e r
  case $1 in *TESTING.md*) ;; *) return 0 ;; esac
  r=${1//TESTING.md/}
  [ -n "${3:-}" ] || tnf=$((tnf + (${#1} - ${#r}) / 10))
  e=$(expand "$1" "$2")
  tn_free "$e" || tn_deny "this command" "$e"
}

tn_count() {
  grep -cE '^- All tests: none[[:space:]]*$' <<<"$1" || [ $? -eq 1 ]
}

tn_edit() {
  local c= r n0 n1 o
  if [ -e "$1" ]; then
    c=$(cat -- "$1" && printf x) || exit 1
    c=${c%x}
  fi
  c=${c//$'\r\n'/$'\n'}
  o=$teo
  if [ -n "$o" ]; then
    [[ $c == *"$o"* ]] || tn_deny "Edit of $1 has an old_string that is not in the file verbatim, so the guard cannot check its result, and it may be an Edit that" "$1"
    [ -n "$ten" ] || [ "${o: -1}" = $'\n' ] || [[ $c != *"$o"$'\n'* ]] || o+=$'\n'
  fi
  if [ -z "$o" ]; then
    r=$ten$c
  elif [ -n "$ter" ]; then
    r=${c//"$o"/"$ten"}
  else
    r=${c/"$o"/"$ten"}
  fi
  n0=$(tn_count "$c") || exit 1
  n1=$(tn_count "$r") || exit 1
  [ "$n1" -gt "$n0" ]
}

tn_deny() {
  deny tests-none "$1 adds the line \"- All tests: none\" to $2; only the operator adds that declaration, since it lets forge done pass a phase untested. Ask the operator to add it outside your tool calls, either by editing $2 by hand or with a ! command that appends - All tests: none under ## Commands of $2"
}

copy_deny() {
  deny forge-copy "$c copies forge script $fs to $ft, outside the forge repo $frt and its worktrees; change forge in the forge repo through a phase, never a copy"
}

main() {
  set -euo pipefail
  local code real s
  code=$(jq -r "$defs
$prog") || exit 1
  eval "$code"
  [ -n "$cwd" ] || cwd=$PWD
  go=()
  unset fcw
  declare -A frc=() fsm=()
  if [ "${1:-}" = planning ]; then
    case $tool in Edit | Write | NotebookEdit) [ -z "$path" ] || planning_rule "$(expand "$path" "$cwd")" ;; esac
    exit 0
  fi
  h=$(realpath -m -- "$HOME")
  case $tool in
    ScheduleWakeup | CronCreate)
      if [ -n "${FORGE_ROOT:-}${FORGE_PHASE:-}" ]; then
        deny polling "$tool in a forge-launched session; wait for the agent's completion notification; don't poll"
      fi
      ;;
    ReadNotifications)
      if [ -z "$agent" ] && [ -n "${FORGE_ROOT:-}${FORGE_PHASE:-}" ]; then
        deny polling "$tool in the main agent of a forge-launched session; wait for the agent's completion notification; don't poll"
      fi
      ;;
    Edit | Write | NotebookEdit)
      [ -n "$path" ] || exit 0
      real=$(expand "$path" "$cwd")
      if [ -n "$cint" ]; then
        froot "$real"
        case $real in "$frt" | "$frt"/*) ;; *) deny forge-internals "$tool of $real, outside the forge repo $frt and its worktrees, writes content that $cint; run the forge command itself (for example forge done N) instead of sourcing or redefining forge's internals, and report a gate it cannot pass" ;; esac
      fi
      if [ -n "$tn$te" ] && [ "${real##*/}" = TESTING.md ] && ! tn_free "$real"; then
        case $tool in
          Edit) [ -z "$tn" ] && ! tn_edit "$real" || tn_deny "$tool of $real" "$real" ;;
          Write) [ -f "$real" ] && grep -qE '^- All tests: none[[:space:]]*$' -- "$real" 2>/dev/null || tn_deny "$tool of $real" "$real" ;;
        esac
      fi
      planning_rule "$real"
      write_rules "$real"
      code_rule "$real"
      fwrite "$real" "$tool"
      ;;
    Bash)
      [ -z "$fint" ] || deny forge-internals "this command $fint; run the forge command itself (for example forge done N) instead of sourcing or redefining forge's internals, and report a gate it cannot pass"
      dir=$cwd
      dstk=()
      lps=
      pq=()
      tnf=0
      for s in "${segs[@]}"; do eval "$s"; done
      [ -z "$tb" ] || [ "$tnf" -ge "$tc" ] || tn_deny "this command" "the TESTING.md it names"
      ;;
  esac
  exit 0
}

(main "$@")
s=$?
case $s in
  0) exit 0 ;;
  42) exit 2 ;;
esac
echo "forge-guard: internal error (exit $s); denied" >&2
exit 2

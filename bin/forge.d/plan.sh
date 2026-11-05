ready() {
  pair "$@"
  local out
  out=$(project '$p.tracks[$t] | select(.status == "open") | .features[] | select(.feature == $f)
    | unmet($p; $t; .) | if length == 0 then "ready" else "waiting on: " + join(", ") end' --arg t "$t" --arg f "$f")
  [ -n "$out" ] || die "no open feature $t/$f" 2
  echo "$out"
  [ "$out" = ready ]
}

replan() {
  retry_keep "$1"
  rm -rf "$1"/{plan.json,tasks,tests}
}

retry_keep() {
  local x
  rm -f "$1/result.json"
  for x in "$1"/tasks/*.json; do
    [ -f "$x" ] || continue
    if jq -e '.status == "unmet"' "$x" >/dev/null; then
      rm "$x"
    else
      [ $? = 1 ] || die "cannot read $x"
    fi
  done
}

refusals() {
  local s c r x u v e
  if [ -f "$fd/requirements.json" ]; then
    x=$(jq -r --slurpfile r "$fd/requirements.json" '
      ([$r[0].requirements[] | select((.owner // "agent") != "agent") | {key: .id, value: .owner}] | from_entries) as $o
      | first(.phases[] | .slug as $s | .requirements[] | select($o[.])
        | "phase \($s): requirement \(.) is owned by \($o[.]), not agent; a phase takes only agent requirements") // empty' "$fd/split.json") \
      || die "cannot read $fd/requirements.json"
    [ -z "$x" ] || die "$x"
  fi
  while read -r s r; do
    x=$(repo_path "$r" 2>&1) || die "phase $s: ${x#forge: }"
    [ -d "$x/.forge" ] || die "phase $s: repo ${r:-${root##*/}} at $x has no .forge/"
  done < <(jq -r '.phases[] | "\(.slug) \(.repo // "")"' "$fd/split.json")
  repo_order
  x=$(jq -r '
    .phases as $ps
    | def up: . as $d | [.[], ($ps[] | select(IN(.slug; $d[])) | .depends[])] | unique;
    def tr: gsub("^\\s+|\\s+$"; "");
    first($ps[] | .slug as $s | ([$s] | until(up == .; up)) as $d | (.consumes[]? | tr) as $i
      | $ps[] | select(.slug != $s and (IN(.slug; $d[]) | not) and any(.creates[]?; tr == $i))
      | "phase \($s) consumes \($i), which phase \(.slug) creates, but does not depend on \(.slug)") // empty' "$fd/split.json")
  [ -z "$x" ] || die "$x"
  x=$(jq -r --arg p "${root##*/}" -L "$D" 'include "forge";
    .phases as $ps
    | def up: . as $d | [.[], ($ps[] | select(IN(.slug; $d[])) | .depends[])] | unique;
    def tr: gsub("^\\s+|\\s+$"; "");
    def key: if .repo == null or .repo == $p then "" else .repo end;
    def files: .repo as $r | [.spec[] | select(startswith("Files:")) | entries($r)[]];
    ([$ps[] | {key: .slug, value: ([.slug] | until(up == .; up))}] | from_entries) as $d
    | range(0; $ps | length) as $i | range($i + 1; $ps | length) as $j
    | $ps[$i] as $a | $ps[$j] as $b
    | select((IN($b.slug; $d[$a.slug][]) or IN($a.slug; $d[$b.slug][])) | not)
    | ((select(($a | key) == ($b | key)) | ($b | files) as $fb | $a | files | unique[] | select(IN($fb[])) | ["f", ($a | key), .]),
       ([$b.creates[]? | tr] as $cb | [$a.creates[]? | tr] | unique[] | select(IN($cb[])) | ["c", "", .]))
    | [.[0], $a.slug, $b.slug, .[1], .[2]] | join("\u001f")' "$fd/split.json") || die "cannot read $fd/split.json"
  [ -z "$x" ] || while IFS=$'\x1f' read -r c s u r e; do
    [ "$c" = f ] || die "phase $s and phase $u both create $e with no dependency path"
    { IFS= read -r -d '' _ && IFS= read -r -d '' _ && IFS= read -r -d '' v; } < <(git -C "$(repo_path "$r")" check-attr -z merge -- "$e" 2>/dev/null) || v=
    [ "$v" = union ] || die "phase $s and phase $u both plan ${r:+$r:}$e with no dependency path; add one to the later phase's depends"
  done <<<"$x"
}

alloc() {
  pair "$@"
  lock
  [ -f "$fd/split.json" ] || die "no $fd/split.json"
  local max=-1 x n dir k at='{}' fs='{}' o r b es=()
  for n in $(numbers); do es+=("$state"/phases/"$n"-*/events.jsonl); done
  x=false
  [ ${#es[@]} -eq 0 ] || x=$(jq -s 'any(.step == "start")' "${es[@]}") || die "cannot read the events of $t/$f"
  if [ "$x" = true ]; then
    x=$(sessions --names) || die "cannot list the sessions of $t/$f"
    [ -z "$x" ] || die "$t/$f has a live session ${x//$'\n'/, }; alloc after it ends"
  fi
  refusals
  for x in tracks/*.json; do
    o=${x#tracks/} o=${o%.json} b=$(branch_of "$o/$f")
    [ "$o" != "$t" ] || continue
    ! jq -e --arg f "$f" 'any(.features[]?; .feature == $f)' "$x" >/dev/null || die "feature slug $f is already open as $o/$f; pick another name for $t/$f"
    [ -d "$state/archive/$o-$f" ] || continue
    for r in "${os[@]}"; do
      ! git -C "$r" show-ref -q --verify "refs/heads/$b" || git -C "$r" merge-base --is-ancestor "$b" main 2>/dev/null ||
        die "feature slug $f is archived as $o/$f with $b unmerged in $r; pick another name for $t/$f"
    done
  done
  [ ! -f "$fd/spec.json" ] || fs=$(jq -c . "$fd/spec.json")
  for x in "$state"/phases/[0-9]* "$state"/archive/*/phases/[0-9]*; do
    n=${x##*/} n=${n%%-*}
    [[ $n =~ ^[0-9]+$ ]] && ((10#$n > max)) && max=$((10#$n))
  done
  jq --argjson next $((max + 1)) '
    .phases |= (reduce .[] as $ph ({out: [], n: $next};
      if $ph.number then .out += [$ph]
      else .out += [$ph + {number: (.n | tostring | if length < 2 then "0" + . else . end)}] | .n += 1 end) | .out)' \
    "$fd/split.json" >"$fd/split.json.new"
  mv "$fd/split.json.new" "$fd/split.json"
  while IFS= read -r k; do
    at=$(jq -c --arg k "$k" --arg v "$(repo_path "$k")" '.[$k] = $v' <<<"$at")
  done < <(jq -r '.phases[] | .repo // ""' "$fd/split.json" | sort -u)
  jq -c --arg t "$t" --arg f "$f" --argjson at "$at" --argjson fs "$fs" '
    (.phases | map({(.slug): .number}) | add) as $num
    | (.phases | map({(.slug): $at[.repo // ""]}) | add) as $in
    | .phases[] | $at[.repo // ""] as $own | [.depends[] | $in[.] | select(. != $own)] as $up
    | [$ARGS.positional[] | select(IN(.; $up[])) | "Reference (read-only): \(split("/") | last) feature worktree \(.)/.claude/worktrees/\($t)-\($f)"] as $refs
    | {track: $t, feature: $f, number, slug} + (if .repo then {repo} else {} end)
      + {goal, spec: ($refs + .spec), requirements, depends: [.depends[] | $num[.]]}
      + (if .focus then {focus: (.focus | sort)} else {} end)
      + (if $fs.targets and any(.focus[]?; . == "scaling") then {targets: ($fs.targets | to_entries | sort_by(.key) | from_entries)} else {} end)
      + (if $fs.pii_fields and any(.focus[]?; . == "pii") then {pii_fields: $fs.pii_fields} else {} end)' \
    "$fd/split.json" --args "${os[@]}" | while IFS= read -r x; do
    dir=$state/phases/$(jq -r '"\(.number)-\(.slug)"' <<<"$x")
    compgen -G "$state/archive/*/phases/${dir##*/}" >/dev/null && continue
    if [ -e "$dir" ]; then
      [ "$(jq -cS . "$dir/spec.json")" = "$(jq -cS . <<<"$x")" ] && continue
      jq . <<<"$x" >"$dir/spec.json"
      replan "$dir"
      rm -rf "$dir"/{gaps.json,research.json,research,scout.json}
      [ ! -f "$dir/events.jsonl" ] || event "$dir" replan "spec changed"
      echo "replan $dir"
      continue
    fi
    mkdir -p "$dir"
    jq . <<<"$x" >"$dir/spec.json"
    echo "$dir"
  done
}

archive() {
  pair "$@"
  [ -f "$fd/ship.json" ] || die "$t/$f has no $fd/ship.json"
  [ -f "tracks/$t.json" ] || die "no tracks/$t.json"
  local dest=$state/archive/$t-$f nums date n x r b rs=("$root")
  lock
  [ ! -e "$dest" ] || die "$dest exists"
  x=$(blocking "$fd") || exit 1
  [ -z "$x" ] || die "$t/$f has pending review parts or open high or medium review findings; run the fallback forge-reviewer for each pending part, append its findings to the review record and delete pending, and fix each finding, or set deferred to todo or dismissed with a reason, before archive (a high security-class finding is closed by dismissed only with a settled: <operator's words> dismissal written after asking the operator and cannot be deferred to todo; Codex-only mediums are advisory and do not block):
$x"
  landed
  [ ! -f "$fd/split.json" ] || phase_repos
  nums=$(jq -c '[.phases[]?.number // empty]' "$fd/split.json" 2>/dev/null || echo '[]')
  date=$(jq -r .date "$fd/ship.json")
  mkdir -p "$state/archive"
  mv "$fd" "$dest"
  mkdir "$dest/phases"
  for n in $(jq -r '.[]' <<<"$nums"); do
    for x in "$state"/phases/"$n"-*/; do mv "${x%/}" "$dest/phases/"; done
  done
  jq --arg f "$f" --argjson nums "$nums" --arg date "$date" \
    '.features |= map(select(.feature != $f)) | .shipped += [{feature: $f, phases: $nums, date: $date}]' \
    "tracks/$t.json" >"tracks/$t.json.new"
  mv "tracks/$t.json.new" "tracks/$t.json"
  for r in "${rs[@]}"; do
    b=$(branch_of "$t/$f")
    git -C "$r" show-ref -q --verify "refs/heads/$b" || b=forge/$f
    git -C "$r" show-ref -q --verify "refs/heads/$b" && git -C "$r" merge-base --is-ancestor "$b" main || continue
    git -C "$r" branch -q -d "$b" || echo "forge: warning: kept $b in $r" >&2
  done
  for r in "${rs[@]}"; do leftover "$r"; done
  for r in "${rs[@]}"; do
    n=0
    { x=$(FORGE_ROOT=$r "$D/../forge" gc --apply </dev/null 2>&1 >&3) || n=$?; } 3>&1
    if [ "$n" = 0 ]; then
      [ -z "$x" ] || echo "$x" >&2
    else
      x=$(sed -n '$s/^forge: //;$p' <<<"$x")
      echo "forge: warning: forge gc failed in $r: ${x:-exit $n}" >&2
    fi
  done
}

leftover() {
  local r=$1 x b
  x=$(git -C "$r" for-each-ref --format='%(refname:short)' "refs/heads/forge/$t-$f" "refs/heads/forge/$t-$f-[0-9]*")
  for b in $x; do echo "forge: leftover: branch $b in $r" >&2; done
  x=$(git -C "$r" worktree list --porcelain)
  while IFS= read -r b; do
    [[ $b == "worktree "*/.claude/worktrees/"$t-$f" || $b == "worktree "*/.claude/worktrees/"$t-$f"-[0-9]* ]] || continue
    echo "forge: leftover: $b" >&2
  done <<<"$x"
  if [ "$(git -C "$r" config --bool forge.pushMain)" = true ] && git -C "$r" remote get-url origin >/dev/null 2>&1; then
    if x=$(GIT_TERMINAL_PROMPT=0 git -C "$r" ls-remote --heads origin 'refs/heads/forge/*'); then
      while read -r _ b; do
        b=${b#refs/heads/}
        [[ $b == "forge/$t-$f" || $b == "forge/$t-$f"-[0-9]* ]] || continue
        echo "forge: leftover: origin branch $b in $r" >&2
      done <<<"$x"
    else
      echo "forge: warning: cannot list the forge branches on origin in $r" >&2
    fi
  fi
  x=$(git -C "$r" -c core.quotePath=false status --porcelain --untracked-files=no -- . ':(exclude).forge')
  while IFS= read -r b; do
    [ -z "$b" ] || echo "forge: leftover: uncommitted ${b:3} in $r" >&2
  done <<<"$x"
}

repos() {
  declare -gA dirs=()
  local d
  for d in "$root"/*/; do
    [ -e "$d.git" ] && dirs[$(basename "$d")]=${d%/}
  done
  [ ${#dirs[@]} -gt 0 ] || dirs[$(basename "$root")]=$root
}

concerns_md() {
  jq -j -L "$D" --rawfile tpl "$T/CONCERNS.md" 'include "forge"; concerns_doc($tpl)' "$1/concerns.json" >"$1/CONCERNS.md"
}

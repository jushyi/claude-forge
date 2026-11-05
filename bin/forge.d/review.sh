event() {
  jq -cn --arg time "$(date -u +%FT%TZ)" --arg step "$2" --arg message "$3" --arg offset "${4:-}" --arg session "${5:-}" --arg dead "${6:-}" --arg verify "${7:-}" '{$time, $step, $message} + if $offset == "" then {} else {offset: ($offset | tonumber)} end + if $session == "" then {} else {$session} end + ($dead | split(",") | map(gsub(" "; "")) | map(select(. != "")) | if . == [] then {} else {dead: .} end) + if $verify == "" then {} else {$verify} end' >>"$1/events.jsonl"
}

codex() {
  local before after s=0
  before=$(codex_broker "$1") || { echo "forge: cannot read the codex broker state for $1; leaving its broker running" >&2; before=-; }
  (cd "$1" && CLAUDE_PLUGIN_DATA=$HOME/.claude/plugins/data/codex-openai-codex node "$cx" "${@:2}" </dev/null) || s=$?
  if [ "$before" != - ]; then
    after=$(codex_broker "$1") || { echo "forge: cannot read the codex broker state for $1; leaving its broker running" >&2; after=$before; }
    [ -z "$after" ] || [ "$after" = "$before" ] || codex_stop "$1"
  fi
  return $s
}

codex_broker() {
  (cd "$1" && CLAUDE_PLUGIN_DATA=$HOME/.claude/plugins/data/codex-openai-codex node --input-type=module \
    -e 'const { loadBrokerSession } = await import(process.argv[1]); console.log(loadBrokerSession(process.cwd())?.endpoint ?? "")' \
    "${cx%/*}/lib/broker-lifecycle.mjs" </dev/null)
}

codex_stop() {
  jq -cn --arg cwd "$1" '{$cwd}' | (cd "$1" && env -u CODEX_COMPANION_SESSION_ID -u CODEX_COMPANION_APP_SERVER_ENDPOINT \
    CLAUDE_PLUGIN_DATA=$HOME/.claude/plugins/data/codex-openai-codex node "${cx%/*}/session-lifecycle-hook.mjs" SessionEnd) >&2 \
    || echo "forge: codex broker teardown in $1 failed" >&2
}

codex_login() {
  local u=forge-codex-login.service
  timeout 10 systemctl --user stop "$u" </dev/null 2>/dev/null || :
  timeout 10 systemd-run --user --quiet --collect --unit="$u" codex login </dev/null ||
    echo "forge: warning: cannot start the Codex login unit $u through systemd-run" >&2
}

codex_quota() {
  local st=$HOME/.claude/plugins/data/codex-openai-codex/state nf=$HOME/.local/state/forge/codex-quota-notified af=$HOME/.codex/auth.json win=${1:-5} files job text log msg at auth=
  [ -d "$st" ] || return 0
  [ ! -e "$af" ] || auth=$(date -u -r "$af" +%FT%T.%3NZ) || echo "forge: warning: cannot read the time of $af; a new Codex login does not clear the check" >&2
  if [ -f "$nf" ] && at=$(<"$nf") && [ "${at:0:10}" = "$(date -u +%F)" ] && ! [ "$auth" \> "$at" ]; then
    mapfile -t files < <(find "$st" -path '*/jobs/*.json')
    if [ ${#files[@]} -eq 0 ] || [ "$(jq -s --arg at "$at" 'map(select(.completedAt and .completedAt > $at and .status != "failed")) | length' "${files[@]}" 2>/dev/null)" = 0 ]; then
      cause="Codex usage limit: out of credits at $at; skipping Codex for the rest of today (delete $nf to retry)"
      return 1
    fi
  fi
  mapfile -t files < <(find "$st" -path '*/jobs/*.json' -mmin "-$win")
  [ ${#files[@]} -gt 0 ] || return 0
  job=$(jq -cs 'map(select(.completedAt)) | max_by(.completedAt) // empty | select(.status == "failed")' "${files[@]}") \
    || { echo "forge: cannot read the Codex job records under $st" >&2; return 0; }
  [ -n "$job" ] || return 0
  text=$(jq -r '.result.parseError?, .errorMessage? | strings' <<<"$job")
  log=$(jq -r '.logFile // empty' <<<"$job")
  [ ! -f "$log" ] || text+=$'\n'$(sed -n 's/^\[[^]]*\] Codex error: //p' "$log")
  msg=$(grep -iE -m1 'out of credits|usage limit' <<<"$text") || return 0
  at=$(jq -r .completedAt <<<"$job")
  ! [ "$auth" \> "$at" ] || return 0
  cause="the last Codex job, at $at, failed: $msg"
  [ ! -f "$nf" ] || [ "$(<"$nf")" != "$at" ] || return 1
  if notify "forge: Codex out of credits" "$msg; switch Codex seats; reviews use the fallback reviewer until then"; then
    { mkdir -p "${nf%/*}" && printf '%s\n' "$at" >"$nf"; } || echo "forge: warning: cannot record the notified Codex job in $nf" >&2
    codex_login
  else
    echo "forge: warning: cannot send the Codex out-of-credits notice through forge notify" >&2
  fi
  return 1
}

codex_ready() {
  local out s=0
  cx=$(jq -r '.plugins["codex@openai-codex"][0].installPath // empty' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null) || cx=
  [ -n "$cx" ] || { cause="no codex@openai-codex plugin in installed_plugins.json"; return 1; }
  cx+=/scripts/codex-companion.mjs
  [ -f "$cx" ] || { cause="no companion at $cx"; return 1; }
  codex_quota || return 1
  out=$(codex "$1" setup --json) || s=$?
  [ $s -eq 0 ] || { cause="setup --json exited $s"; return 1; }
  cause=$(jq -rs '.[0] | if .codex.available != true then "Codex is not available"
    elif .auth.loggedIn != true then "Codex is not logged in" else empty end' <<<"$out" 2>/dev/null) \
    || cause="setup --json printed no JSON"
  [ -z "$cause" ]
}

codex_cause() {
  local c
  c=$(jq -r '.parseError // (.codex.stderr | select(. != "")) // empty' <<<"$2" 2>/dev/null) || c=
  [ -n "$c" ] || c=$(awk 'NF { l = $0 } END { print l }' "$3")
  c=${c//$'\n'/ }
  cause="$1${c:+: ${c:0:240}}"
}

codex_review() {
  local out s=0 real log
  log=$(git -C "$1" rev-parse --absolute-git-dir) || { cause="no git dir for $1"; return 1; }
  log+=/forge-codex.log
  out=$(codex "$1" adversarial-review --base "$2" --wait --json "$3" 2>"$log") || s=$?
  [ $s -eq 0 ] || codex_cause "adversarial-review exited $s" "$out" "$log"
  printf '%s\n' "$out" >>"$log"
  [ $s -eq 0 ] || return 1
  jq -e . <<<"$out" >/dev/null 2>&1 || { cause="adversarial-review printed no JSON"; return 1; }
  cause=$(jq -r '.parseError // empty | "parseError: \(.)" | gsub("\n"; " ")' <<<"$out")
  [ -z "$cause" ] || return 1
  real=$(cd "$1" && pwd -P)
  found=$(jq -c --arg w "$1/" --arg r "$real/" '.result.findings
    | select(type == "array" and all(.[]; (.line_start | type == "number" and . >= 1 and . == floor)
      and (.severity | IN("critical", "high", "medium", "low")) and (.file | type == "string")))
    | map({file: (.file | ltrimstr($r) | ltrimstr($w)), line: .line_start, severity: (if .severity == "critical" then "high" else .severity end),
      summary: "\(.title): \(.body)", fixed: false, source: "codex"})' <<<"$out")
  [ -n "$found" ] || { cause="output has no findings with a line_start"; return 1; }
}

is_ui() {
  pair "$1"
  [ -d "$fd" ] || die "no $fd" 2
  [ -f "$fd/design.json" ]
}

prior_check() {
  local py
  [ -f "$prior" ] && [ -r "$prior" ] || die "cannot read the prior record $prior"
  py=$(validator) || exit
  "$py" "$D/validate.py" --schemafile "$S/review.schema.json" "$prior" || die "the prior record $prior is not a valid review record"
  ptree=$(jq -r '.tree // empty' "$prior") || die "cannot read the prior record $prior"
  [ -z "$ptree" ] || git -C "$wt" cat-file -e "$ptree^{tree}" 2>/dev/null || die "no tree $ptree of the prior record $prior in $wt"
}

carry() {
  local f d hunks='{}'
  while IFS= read -r f; do
    d=$(git -C "$wt" diff --no-ext-diff --no-color -U0 "$ptree" 'HEAD^{tree}' -- "$f") || die "cannot diff $f in $wt since $ptree"
    hunks=$(jq -c --arg f "$f" --arg d "$d" '.[$f] = [$d | scan("(?m)^@@ -([0-9]+)(?:,([0-9]+))? \\+([0-9]+)(?:,([0-9]+))? @@")
      | (.[0] | tonumber) as $a | ((.[1] // "1") | tonumber) as $b | (.[2] | tonumber) as $c | ((.[3] // "1") | tonumber) as $e
      | [$a, $a + $b, (if $b > 0 then $a + $b else $a + 1 end), $e - $b, $c, $c + $e]]' <<<"$hunks")
  done < <(jq -r --slurpfile p "$prior" '[.[] | .file as $f | select(any($p[0].findings[]; .file == $f)) | .file] | unique[]' <<<"$found")
  found=$(jq -c --slurpfile p "$prior" --argjson h "$hunks" 'def title: .summary | split(": ")[0];
    def body: .summary | split(": ")[1:] | join(": ");
    def unchanged($l; $s; $e): all(.[]?; $l < .[$s] or $l >= .[$e]);
    def shifted($hs): . as $l | $l + ([$hs[]? | select(.[2] <= $l) | .[3]] | add // 0);
    def rank: {low: 1, medium: 2, high: 3}[.severity]; map(. as $x
    | ($p[0].findings | map(select(.file == $x.file and .line == $x.line))) as $s
    | ($s | map(select(title == ($x | title))) | first) as $m
    | if $s != [] and ($x.summary | contains("New evidence:") | not)
        and all($h[$x.file][]?; $x.line < .[0] or $x.line >= .[1])
        and ([$h[$x.file][]? | select(.[2] <= $x.line) | .[3]] | add // 0) == 0
      then .severity = if $m != null then $m.severity else ($s + [$x] | max_by(rank) | .severity) end else . end
    | ($p[0].findings | map(select(.file == $x.file and title == ($x | title) and (.line | shifted($h[$x.file])) == $x.line)) | first) as $d
    | if ($d.dismissed | type) == "string" and $d.dismissed != "" and ($x | body | startswith("New evidence:") | not)
        and ($h[$x.file] | unchanged($x.line; 4; 5) and unchanged($d.line; 0; 1))
      then .dismissed = $d.dismissed else . end)' <<<"$found")
}

review() {
  local wt base spec dest found='[]' cause x lines=() ftext tree prior=${3:-} ptree='' c rec=${4:-} rp
  pair "$1"
  spec=$fd/spec.json dest=$fd base=${2:-main}
  [ -f "$spec" ] || die "no $spec"
  [ -z "$rec" ] || [ -d "${rec%/*}/" ] || die "no directory ${rec%/*} for $rec"
  wt=$(git -C "$start" rev-parse --show-toplevel 2>/dev/null) || die "$start is not in a git worktree"
  [ -z "${2:-}" ] || git -C "$wt" rev-parse -q --verify "$base^{commit}" >/dev/null || die "no commit $base in $wt"
  tree=$(git -C "$wt" rev-parse 'HEAD^{tree}') || die "cannot read the HEAD tree of $wt"
  [ -z "$prior" ] || prior_check
  rp=$rec
  [ -n "$rec" ] || rec=$dest/review.json rp=$dest/review.json
  ftext="Report only defects that this diff introduces against $base; ignore pre-existing code, style and anything outside the diff. The diff implements the spec in $spec."
  focus_text "$spec"
  x=$(jq -r '.decisions // [] | .[]' "$spec") || die "cannot read $spec"
  [ -z "$x" ] || ft+=$'\n\n'"Operator decisions of this feature, one per line; they are not defects, so do not report the behavior they decide:"$'\n'"$x"
  ft+=$'\n\n'"A finding about an authentication, authorization, secret, injection or personal-data defect starts its title with \"[security]\", \"[pii]\" or \"[auth]\"."
  [ -z "$prior" ] || ft+=$'\n\n'"Findings of the previous review round, one <file>:<line> <severity>: <summary> each:"$'\n'"$(jq -r '.findings[] | "\(.file):\(.line) \(.severity): \(.summary)\(if (.dismissed | type) == "string" and .dismissed != "" then " (dismissed: \(.dismissed))" else "" end)"' "$prior")"$'\n\n'"A finding at the same file in a hunk unchanged since that round keeps that round's severity, unless its body starts \"New evidence:\" and names what is new. A finding that repeats one of those findings keeps that finding's title word for word. A finding that repeats a dismissed finding keeps its title word for word and stays dismissed unless its body starts \"New evidence:\" and names what is new."
  if ! codex_ready "$wt"; then
    lines+=("codex: $cause")
  elif ! codex_review "$wt" "$base" "$ft"; then
    found='[]'
    lines+=("codex: $cause")
    codex_quota || :
  else
    [ -z "$ptree" ] || carry
  fi
  jq --arg tree "$tree" '{findings: .} + if $ARGS.positional == [] then {} else {pending: $ARGS.positional} end
    + {$tree}' --args "${lines[@]}" <<<"$found" >"$rec"
  [ ${#lines[@]} -eq 0 ] || printf '%s\n' "${lines[@]}"
  c=$(review_ctx "$dest") || die "cannot read the review context of $dest"
  jq -r --arg p "$rp" --argjson c "$c" "$review_defs"'(.pending // [] | map(sub(":.*"; "")) | join(", ")) as $w
    | .findings | group_by([.file, .line, .summary]) | map(select(any(.[]; closed($c)) | not))
    | (map(select(advisory)) | length) as $k | map(select(advisory | not) | .[0])
    | "findings: \(length) open (\(map(select(.severity == "high")) | length) high, \(map(select(.severity == "medium")) | length) medium, \(map(select(.severity == "low")) | length) low)\(if $w == "" then "" else ", pending \($w)" end)\(if $k == 0 then "" else ", \($k) advisory" end) in \($p)"' "$rec"
  [ ${#lines[@]} -eq 0 ] || exit 3
}

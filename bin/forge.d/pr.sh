bare() {
  if [[ $1 =~ ^([a-z][a-z0-9+.-]*://)?[^/]*@(.*)$ ]]; then
    echo "${BASH_REMATCH[1]}${BASH_REMATCH[2]}"
  else
    echo "$1"
  fi
}

forgejo_env() {
  local - l v
  set +x
  env=${FORGE_FORGEJO_ENV:-$HOME/.config/forgejo/forge.env} FORGEJO_URL= FORGEJO_TOKEN=
  [ -f "$env" ] || die "no Forgejo env file at $env"
  (( (8#$(stat -L -c %a "$env") & 8#044) == 0 )) || die "Forgejo env file $env is group- or other-readable"
  while IFS= read -r l || [ -n "$l" ]; do
    [[ $l =~ ^(FORGEJO_URL|FORGEJO_TOKEN)=(.*)$ ]] || continue
    v=${BASH_REMATCH[2]}
    [[ ! $v =~ ^\"(.*)\"$ && ! $v =~ ^\'(.*)\'$ ]] || v=${BASH_REMATCH[1]}
    printf -v "${l%%=*}" '%s' "$v"
  done <"$env"
  [ -n "$FORGEJO_URL" ] || die "FORGEJO_URL missing from $env"
  [ -n "$FORGEJO_TOKEN" ] || die "FORGEJO_TOKEN missing from $env"
  [[ $FORGEJO_URL == https://* ]] || die "FORGEJO_URL in $env is not https"
}

forgejo() {
  local - method=$1 path=$2 data=$3 want=$4 env FORGEJO_URL FORGEJO_TOKEN code msg err h t st i=0 d=() x=()
  set +x
  [ "$method" = POST ] || x=(-X "$method")
  [ "$method" = GET ] || x+=(--data-binary @-)
  if [ "$method" = POST ] && [[ $path == */merge ]]; then
    read -ra d <<<"${FORGE_FORGEJO_MERGE_DELAYS:-3 10 30}"
    [ "${#d[@]}" = 3 ] && [[ "${d[*]}" =~ ^[0-9]+\ [0-9]+\ [0-9]+$ ]] ||
      die "FORGE_FORGEJO_MERGE_DELAYS must be three whole numbers of seconds, got '${FORGE_FORGEJO_MERGE_DELAYS:-}'"
  fi
  forgejo_env
  h=$(forgejo_host)
  [ "${want%:*}" = "$h" ] || die "host $want is not the Forgejo host $h from $env"
  while :; do
    resp=$(printf '%s' "$data" | curl -q -sS "${x[@]}" \
      -H @<(printf 'Authorization: token %s\n' "$FORGEJO_TOKEN") \
      -H 'Content-Type: application/json' -H 'Accept: application/json' \
      -w '\n%{http_code}' "${FORGEJO_URL%/}/api/v1/repos$path") \
      || die "Forgejo API $method $path: request to $(bare "$FORGEJO_URL") failed"
    code=${resp##*$'\n'} resp=${resp%$'\n'*}
    [[ $code =~ ^2[0-9][0-9]$ ]] && return
    msg=$(jq -r '.message // empty' <<<"$resp" 2>/dev/null) || msg=
    err="Forgejo API $method $path failed with HTTP $code: ${msg:-$resp}"
    [ "$code" = 405 ] && [ "${#d[@]}" = 3 ] || die "$err"
    t=
    if [ "$msg" = "Please try again later" ] && [ "$i" -lt 3 ]; then
      t=${d[i]} i=$((i + 1))
      echo "forge: Forgejo merge HTTP 405 (Please try again later); retry $i/3 in $t s" >&2
      sleep "$t"
    fi
    forgejo GET "${path%/merge}" "" "$want"
    if jq -e '.merged == true' <<<"$resp" >/dev/null 2>&1; then
      echo "forge: Forgejo pull request ${path%/merge} was already merged" >&2
      return 0
    fi
    st=$(jq -r '.state // empty' <<<"$resp" 2>/dev/null) || st=
    [ "$st" = open ] || die "Forgejo pull request ${path%/merge} is ${st:-in an unknown state}, not open; not merging"
    [ -n "$t" ] || die "$err"
  done
}

forgejo_host() {
  local - h
  set +x
  h=${FORGEJO_URL#https://} h=${h%%/*} h=${h##*@} h=${h%:*}
  echo "${h,,}"
}

forgejo_file() {
  local - path=$1 out=$2 want=$3 env FORGEJO_URL FORGEJO_TOKEN h url
  set +x
  forgejo_env
  h=$(forgejo_host)
  [ "${want%:*}" = "$h" ] || die "host $want is not the Forgejo host $h from $env"
  url=${FORGEJO_URL%/}/api/packages$path
  code=$(curl -q -sS -H @<(printf 'Authorization: token %s\n' "$FORGEJO_TOKEN") -o "$out" -w '%{http_code}' "$url") ||
    die "Forgejo package GET $(bare "$url") failed"
  [[ $code =~ ^[0-9]{3}$ ]] || die "Forgejo package GET $(bare "$url") gave no HTTP code"
}

ghr() {
  local i=0 s err st d m
  for d in 10 30 90 ''; do
    s=0
    { err=$(gh "$@" 2>&1 >&3) || s=$?; } 3>&1
    [ -z "$err" ] || printf '%s\n' "$err" >&2
    [ "$s" != 0 ] || return 0
    [ -n "$d" ] && [[ $err =~ (connection\ reset|[Tt]imeout|timed\ out|EOF|HTTP\ 5[0-9][0-9])[^$'\n']* ]] || return "$s"
    m=${BASH_REMATCH[0]}
    if [ "$1 $2" = "pr merge" ]; then
      st=$(ghr pr view "$3" --json state) || {
        echo "forge: cannot tell whether $3 merged after a gh transport error ($m); not retrying gh pr merge" >&2
        return "$s"
      }
      [ "$(jq -r '.state // empty' <<<"$st")" != MERGED ] || return 0
    fi
    i=$((i + 1))
    echo "forge: gh transport error ($m); retry $i/3 in $d s" >&2
    sleep "$d"
  done
}

pr_checks() {
  local url=$1 print=$2 wait=${FORGE_PR_CHECK_WAIT:-150} grace=${FORGE_PR_CHECK_GRACE:-60} every=${FORGE_PR_CHECK_INTERVAL:-10} t0=$SECONDS g0=$SECONDS seen= rows
  [[ $wait =~ ^[0-9]+$ ]] || die "FORGE_PR_CHECK_WAIT must be a whole number of minutes, got '$wait'"
  [[ $grace =~ ^[0-9]+$ ]] || die "FORGE_PR_CHECK_GRACE must be a whole number of seconds, got '$grace'"
  [[ $every =~ ^[0-9]+([.][0-9]+)?$ ]] || die "FORGE_PR_CHECK_INTERVAL must be a number of seconds, got '$every'"
  while :; do
    view=$(ghr pr view "$url" --json statusCheckRollup,headRefOid) || exit 1
    head=$(jq -er '.headRefOid | strings | select(. != "")' <<<"$view") || die "gh returned no head commit for $url"
    [ "$head" = "$seen" ] || seen=$head g0=$SECONDS
    rows=$(jq -r '
      [.statusCheckRollup // [] | .[]
        | (if .__typename == "StatusContext" then .state elif .status == "COMPLETED" then .conclusion else .status end) as $s
        | {name: (.name // .context), wf: (.workflowName // ""), link: (.detailsUrl // .targetUrl // ""), t: (.startedAt // ""),
           b: (if $s == "SUCCESS" or $s == "SKIPPED" or $s == "NEUTRAL" then "pass"
               elif $s == "FAILURE" or $s == "ERROR" or $s == "CANCELLED" or $s == "TIMED_OUT" or $s == "ACTION_REQUIRED" or $s == "STARTUP_FAILURE" or $s == "STALE" then "fail"
               else "pending" end)}]
      | group_by([.name, .wf]) | map(max_by([.b == "pending", .t])) | .[]
      | "\(.b)\t\(.name)\t\(.link)"' <<<"$view") || die "cannot read the checks of $url from gh"
    if [ -z "$rows" ]; then
      [ $((SECONDS - g0)) -lt "$grace" ] || break
      [ $((SECONDS - t0)) -lt $((10#$wait * 60)) ] || die "no checks reported yet on $url" 4
    elif [ $((SECONDS - t0)) -ge $((10#$wait * 60)) ] ||
      { ! grep -q '^pending' <<<"$rows" && { grep -q '^fail' <<<"$rows" || [ $((SECONDS - g0)) -ge "$grace" ]; }; }; then
      break
    fi
    sleep "$every"
  done
  [ -z "$print" ] || [ -z "$rows" ] || printf '%s\n' "$rows"
  if grep -q '^fail' <<<"$rows"; then
    while IFS=$'\t' read -r _ c _; do echo "forge: check failed: $c" >&2; done < <(grep '^fail' <<<"$rows")
    exit 3
  fi
  if grep -q '^pending' <<<"$rows"; then
    while IFS=$'\t' read -r _ c _; do echo "forge: check still pending: $c" >&2; done < <(grep '^pending' <<<"$rows")
    exit 4
  fi
}

merge_ready() {
  local q out
  printf -v q %q "$2"
  out=$(cd "$3" && bash -c "${1//\{sha\}/"$q"}" 2>&1 </dev/null) || {
    [ -z "$out" ] || printf '%s\n' "$out" >&2
    die "Merge ready refused head $2" 3
  }
}

merge_fresh() {
  local top=$1 head=$2 e b f
  e=$(GIT_TERMINAL_PROMPT=0 git -C "$top" fetch -q origin +refs/heads/main:refs/remotes/origin/main 2>&1) ||
    die "cannot fetch main from origin in $top${e:+: ${e##*$'\n'}}; nothing merged"
  git -C "$top" rev-parse -q --verify "$head^{commit}" >/dev/null ||
    die "head ${head:0:7} is not in $top; run forge pr merge from the worktree that pushed it; nothing merged"
  b=$(git -C "$top" merge-base "$head" refs/remotes/origin/main) ||
    die "head ${head:0:7} shares no history with origin/main; nothing merged"
  f=$(git -C "$top" diff --name-only --no-renames "$b" refs/remotes/origin/main | sed '\#^\.forge/TESTING\.md$#b; \#^\.forge/#d') ||
    die "cannot diff origin/main against head ${head:0:7} in $top; nothing merged"
  [ -z "$f" ] || die "origin/main moved outside .forge/ since head ${head:0:7}: ${f%%$'\n'*}; merge origin/main into the branch and retest" 5
}

ci_stamp() {
  local url=$1 name=$2 top=$3 me=$4 v=$5 why h
  why=$(jq -r --arg n "$name" '
    (.statusCheckRollup // []) as $all
    | [$all[] | select(.__typename == "CheckRun" and .name == $n and (.workflowName // "") != "")] as $r
    | if $r == [] then
        if any($all[]; .__typename == "CheckRun" and .name == $n) then "check \($n) has no workflowName, not a GitHub Actions check run"
        elif any($all[]; .__typename == "StatusContext" and .context == $n) then "\($n) is a status context, not a GitHub Actions check run"
        else "check \($n) not reported" end
      elif ($r | length) > 1 and ([$r[] | .startedAt // ""] | sort | .[0] == "" or .[-1] == .[-2]) then
        "check \($n) has \($r | length) runs and no single newest one"
      else ($r | max_by(.startedAt // "")) as $c
        | if $c.status == "COMPLETED" and $c.conclusion == "SUCCESS" then ""
          elif $c.status != "COMPLETED" then "check \($n) is \($c.status // "unknown" | ascii_downcase)"
          else "check \($n) \($c.conclusion // "unknown" | ascii_downcase)" end
      end' <<<"$v") || die "cannot read the checks of $url from gh"
  [ -z "$why" ] || die "CI full suite: $why; run forge test" 6
  h=$(jq -r '.headRefOid // "none"' <<<"$v") || die "cannot read the head commit of $url from gh"
  [ "$h" = "$me" ] || die "CI full suite: head ${h:0:7} is not W's HEAD ${me:0:7}; run forge test" 6
  ci_pass "$top" "$me" "$name"
}

ci_pass() {
  local top=$1 me=$2 name=$3 tree st
  tree=$(git -C "$top" rev-parse "$me^{tree}") || die "cannot read the tree of $me in $top"
  st=$(host_stamps "$top") || exit
  { mkdir -p "$st" && : >"$st/$tree"; } || die "cannot write the test stamp $st/$tree"
  echo "forge: tests passed ($(git -C "$top" rev-parse --short "$tree")), CI check $name" >&2
}

fjq() {
  jq "${@:1:$#-1}" "def ts: (strings | capture(\"^(?<d>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})([.][0-9]+)?(?<z>Z|[+-][0-9]{2}:[0-9]{2})$\")
    | (.d + \"Z\" | fromdateiso8601) - (if .z == \"Z\" then 0 else (.z[0:1] + \"1\" | tonumber) * ((.z[1:3] | tonumber) * 3600 + (.z[4:6] | tonumber) * 60) end)) // empty; ${!#}"
}

forgejo_list() {
  local path=$1 want=$2 since=$3 p=1 n=0 q='?' page all= s
  [[ $path != *\?* ]] || q='&'
  while :; do
    forgejo GET "$path${q}limit=50&page=$p" "" "$want"
    page=$(jq -ce '.workflow_runs | arrays' <<<"$resp") || die "Forgejo returned no list for ${path%%\?*}"
    all+=$page$'\n' n=$((n + $(jq length <<<"$page"))) s=0
    fjq -e --argjson n "$n" --arg s "$since" '.workflow_runs != [] and $n < (.total_count // 0)
      and ($s == "" or ([.workflow_runs[].created_at | ts] | min) >= ($s | tonumber))' <<<"$resp" >/dev/null || s=$?
    [ "$s" = 0 ] || [ "$s" = 1 ] || die "cannot read the Forgejo list ${path%%\?*}"
    [ "$s" = 0 ] || break
    p=$((p + 1))
  done
  jq -cs 'add' <<<"$all"
}

forgejo_full() {
  local url=$1 repo=$2 n=$3 name=$4 top=$5 me=$6 fh=$7 wait=${FORGE_PR_CHECK_WAIT:-150} grace=${FORGE_PR_CHECK_GRACE:-60} every=${FORGE_PR_CHECK_INTERVAL:-10} t0=$SECONDS head runs tasks since v
  [[ $wait =~ ^[0-9]+$ ]] || die "FORGE_PR_CHECK_WAIT must be a whole number of minutes, got '$wait'"
  [[ $grace =~ ^[0-9]+$ ]] || die "FORGE_PR_CHECK_GRACE must be a whole number of seconds, got '$grace'"
  [[ $every =~ ^[0-9]+([.][0-9]+)?$ ]] || die "FORGE_PR_CHECK_INTERVAL must be a number of seconds, got '$every'"
  while :; do
    forgejo GET "/$repo/pulls/$n" "" "$fh"
    head=$(jq -r '.head.sha // empty' <<<"$resp") && [[ $head =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]] || die "Forgejo returned no head SHA for $url"
    [ "$head" = "$me" ] || die "CI full suite: head ${head:0:7} is not W's HEAD ${me:0:7}; run forge test" 6
    runs=$(forgejo_list "/$repo/actions/runs?head_sha=$head" "$fh" "") || exit
    tasks=[] v=
    if [ "$runs" = "[]" ] && [ $((SECONDS - t0)) -lt "$grace" ]; then
      v=pending
    elif [ "$runs" != "[]" ]; then
      since=$(fjq -r '[.[].created | ts] | min // ""' <<<"$runs") || die "cannot read the Actions runs of $url"
      tasks=$(forgejo_list "/$repo/actions/tasks" "$fh" "$since") || exit
    fi
    [ -n "$v" ] || v=$(printf '%s\n%s\n' "$runs" "$tasks" | jq -rs --arg n "$name" --arg h "$head" '
      def pend: . == "unknown" or . == "waiting" or . == "running" or . == "blocked";
      .[0] as $r | [.[1][] | select(.name == $n and .head_sha == $h)] as $m | ([$m[].workflow_id] | unique) as $w
      | if ($w | length) > 1 then "6\ttask \($n) of head \($h[0:7]) runs in more than one workflow (\($w | join(", ")))"
        elif $m == [] then
          if any($r[]; .status | pend) then "pending" else "6\tno Forgejo Actions task \($n) on head \($h[0:7])" end
        else ($m | max_by(.id)) as $t | [$r[] | select(.index_in_repo == $t.run_number)] as $k | [$m[] | select(.run_number == $t.run_number)] as $s
          | if ($t.status | pend) or any($k[]; .status | pend) then "pending"
            elif $k == [] then "6\ttask \($n) of head \($h[0:7]) has no run \($t.run_number) of that head"
            elif $t.status == "success" and (all($s[]; .status == "success") or $k[0].status == "success") then "ok"
            elif $t.status == "success" then "6\trun \($t.run_number) of head \($h[0:7]) is \($k[0].status // "unknown") with \($s | length) tasks \($n), not all passed, and a rerun cannot be told from another job of that name"
            elif $t.status == "failure" then "fail\t\($t.url // "")"
            else "6\ttask \($n) was \($t.status // "unknown")" end
        end') || die "cannot read the Actions tasks of $url from Forgejo"
    case $v in
      ok) break ;;
      fail$'\t'*)
        printf 'fail\t%s\t%s\n' "$name" "${v#fail$'\t'}"
        echo "forge: check failed: $name" >&2
        exit 3
        ;;
      6$'\t'*) die "CI full suite: ${v#6$'\t'}; run forge test" 6 ;;
    esac
    if [ $((SECONDS - t0)) -ge $((10#$wait * 60)) ]; then
      echo "forge: check still pending: $name" >&2
      exit 4
    fi
    sleep "$every"
  done
  ci_pass "$top" "$me" "$name"
}

pr_origin() {
  local resolve= p
  u=$(git remote get-url origin) || die "no origin remote in $PWD"
  if [[ $u =~ ^([a-z][a-z0-9+.-]*)://([^@/]*@)?([^/:]+)(:[0-9]*)?/(.+)$ ]]; then
    host=${BASH_REMATCH[3]} path=${BASH_REMATCH[5]}
    [ "${BASH_REMATCH[1]}" != ssh ] || resolve=1
  elif [[ $u =~ ^([^@/]*@)?([^/:]+):(.+)$ ]]; then
    host=${BASH_REMATCH[2]} path=${BASH_REMATCH[3]} resolve=1
  else
    die "cannot read a host and repo from origin $(bare "$u")"
  fi
  [ -z "$resolve" ] || host=$(ssh -G -- "$host" 2>/dev/null | sed -n 's/^hostname //p') || host=
  [ -n "$host" ] || die "ssh -G cannot resolve the host of origin $(bare "$u")"
  host=${host,,} p=${path%/} p=${p%.git} repo=
  [[ ! $p =~ ([^/]+/[^/]+)$ ]] || repo=${BASH_REMATCH[1]}
}

pr() {
  local sub=${1:-} u host path repo n body url head view fh top ready full= ci me h labels= out l lab=() pre
  case $sub in
    push)
      shift
      top=$(git rev-parse --show-toplevel) || die "cannot find the top of the git checkout in $PWD"
      pre=$(test_line "$top" "Pre-push") || exit
      [ -z "$pre" ] || (cd "$top" && bash -c "$pre" </dev/null) || die "Pre-push failed (exit $?); nothing pushed" 3
      git push "$@" || exit 1
      return
      ;;
    create) [ $# -eq 4 ] || usage ;;
    checks)
      if [ $# -eq 3 ] && [ "$2" = --full ]; then
        full=1
        set -- checks "$3"
      else
        [ $# -eq 2 ] && [ "$2" != --full ] || usage
      fi
      ;;
    merge | close | state) [ $# -eq 2 ] || usage ;;
    *) usage ;;
  esac
  pr_origin
  [ "$sub" != create ] || [ -f "$4" ] || die "no body file $4"
  if [ "$sub" = create ]; then
    top=$(git rev-parse --show-toplevel) || die "cannot find the top of the git checkout in $PWD"
    labels=$(test_line "$top" "PR labels") || exit
  fi
  if [ "$sub" = merge ]; then
    top=$(git rev-parse --show-toplevel) || die "cannot find the top of the git checkout in $PWD"
    ready=$(test_line "$top" "Merge ready") || exit
  fi
  if [ -n "$full" ]; then
    top=$(git rev-parse --show-toplevel) || die "cannot find the top of the git checkout in $PWD"
    ci=$(test_line "$top" "CI full suite") || exit
    [ -n "$ci" ] || die "CI full suite: no CI full suite line in $top/.forge/TESTING.md; run forge test" 6
    me=$(git -C "$top" rev-parse HEAD) || die "cannot read HEAD in $top"
    git -C "$top" show "$me:.forge/TESTING.md" 2>/dev/null | cmp -s - "$top/.forge/TESTING.md" ||
      die "CI full suite: .forge/TESTING.md differs from HEAD's; run forge test" 6
    if [ "$host" != github.com ]; then
      [ -n "$repo" ] && [[ ${2,,} =~ ^https://([^/]+)/([^/]+/[^/]+)/pulls/([0-9]+)/?$ ]] && [ "${BASH_REMATCH[2]}" = "${repo,,}" ] ||
        die "CI full suite: $2 is not a pull request of origin's ${repo:-repo}; run forge test" 6
      n=${BASH_REMATCH[3]} fh=${BASH_REMATCH[1]%:*}
      h=$(forgejo_env && forgejo_host) || exit
      [ "$fh" = "$h" ] || die "CI full suite: $2 is not on the Forgejo host $h; run forge test" 6
      ci_job "$top" "$ci" || :
      [ "$CI_FILES" -le 1 ] || die "CI full suite: $ci is defined in $CI_FILES workflow files; run forge test" 6
      forgejo_full "$2" "$repo" "$n" "$ci" "$top" "$me" "$fh"
      return
    fi
    [[ ${path%/} =~ ([^/]+/[^/]+)$ ]] && repo=${BASH_REMATCH[1]%.git} &&
      [[ ${2,,} =~ ^https://github\.com/([^/]+/[^/]+)/pull/[0-9]+/?$ ]] && [ "${BASH_REMATCH[1]}" = "${repo,,}" ] ||
      die "CI full suite: $2 is not a pull request of origin's ${repo:-repo}; run forge test" 6
  fi
  if [ "$host" = github.com ]; then
    if [ -n "$labels" ]; then
      out=$(cd "$top" && bash -c "$labels" </dev/null) || die "PR labels command failed (exit $?): $labels"
      while IFS= read -r l; do
        [ -z "$l" ] || lab+=(--label "$l")
      done <<<"$out"
    fi
    case $sub in
      create) gh pr create --head "$2" --base main --title "$3" --body-file "$4" "${lab[@]}" ;;
      checks) pr_checks "$2" 1 && { [ -z "$full" ] || ci_stamp "$2" "$ci" "$top" "$me" "$view"; } ;;
      merge)
        pr_checks "$2" "" && { [ -z "$ready" ] || merge_ready "$ready" "$head" "$top"; } &&
          merge_fresh "$top" "$head" && ghr pr merge "$2" --merge --match-head-commit "$head"
        ;;
      close) gh pr close "$2" ;;
      state)
        body=$(ghr pr view "$2" --json state,mergeable,mergeStateStatus) || exit 1
        jq -er '(.state | strings | select(. != "")) + " " + (.mergeStateStatus // "" | if . == "" then "UNKNOWN" else . end)' <<<"$body" ||
          die "gh returned no state for $2"
        ;;
    esac || exit 1
    return
  fi
  [ -n "$repo" ] || die "cannot read <owner>/<repo> from origin $(bare "$u")"
  path=/$repo/pulls
  if [ "$sub" = create ]; then
    [ -z "$labels" ] || echo "forge: warning: $host is not GitHub; PR labels not applied" >&2
    body=$(jq -n --arg head "$2" --arg title "$3" --rawfile body "$4" '{head: $head, base: "main", title: $title, body: $body}')
    forgejo POST "$path" "$body" "$host"
    url=$(jq -er '.html_url | strings | select(. != "")' <<<"$resp") || die "Forgejo returned no html_url for the new pull request"
    echo "$url"
    return
  fi
  [[ $2 =~ ^https?://([^/]+)/([^/]+/[^/]+)/pulls/([0-9]+)/?$ ]] || die "not a Forgejo pull request URL: $2"
  [ "${BASH_REMATCH[2],,}" = "${repo,,}" ] || die "pull request $2 is in ${BASH_REMATCH[2]}, not origin's $repo"
  n=${BASH_REMATCH[3]} fh=${BASH_REMATCH[1],,}
  if [ "$sub" = checks ]; then
    echo "forge: warning: $host is not GitHub; no checks to wait for" >&2
  elif [ "$sub" = state ]; then
    forgejo GET "$path/$n" "" "$fh"
    jq -er '(.state | ascii_upcase) as $s
      | (if .merged == true then "MERGED" else $s end) + " "
        + (if $s == "OPEN" and .merged != true and .mergeable == false then "DIRTY" else "UNKNOWN" end)' <<<"$resp" ||
      die "Forgejo returned no state for $2"
  elif [ "$sub" = merge ]; then
    echo "forge: warning: $host is not GitHub; merging without waiting for checks" >&2
    forgejo GET "$path/$n" "" "$fh"
    head=$(jq -er '.head.sha | strings | select(. != "")' <<<"$resp") || die "Forgejo returned no head SHA for $2"
    [ -z "$ready" ] || merge_ready "$ready" "$head" "$top"
    merge_fresh "$top" "$head"
    body=$(jq -cn --arg h "$head" '{Do: "merge", head_commit_id: $h}')
    forgejo POST "$path/$n/merge" "$body" "$fh"
  else
    forgejo PATCH "$path/$n" '{"state": "closed"}' "$fh"
  fi
}

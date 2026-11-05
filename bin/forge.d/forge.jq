def dash: if . == null or . == "" then "—" else . end;
def bullets: map("- " + .) | join("\n");
def csv: if length == 0 then "—" else join(", ") end;
def first_more: if length > 1 then "\(.[0]) +\(length - 1)" else csv end;
def table($head): if length == 0 then "" else $head + "\n" + join("\n") end;
def pad($n): . + ([range(length; $n) | " "] | join(""));
def grid($head):
  if length == 0 then "" else
    ([$head] + map(map(tostring))) as $rows
    | [range($head | length) as $i | [$rows[][$i] | length] | max] as $w
    | ($rows | map([range($w | length) as $i | " " + (.[$i] | pad($w[$i])) + " "] | "|" + join("|") + "|")) as $l
    | [$l[0], "|" + ($w | map([range(. + 2) | "-"] | join("")) | join("|")) + "|"] + $l[1:] | join("\n")
  end;
def cell: gsub("\\|"; "\\|") | gsub("\\s*[\r\n]+\\s*"; " ");
def paras: map(select(. != "")) | join("\n\n");

def strip: sub(":[0-9]+(-[0-9]+)?$"; "") | sub("/+$"; "") | select(test("^[^\\s]+$"));
def clean: strip | select(test("[/.]"));
def entries($r): if test("`") then [scan("`([^`]+)`")[0]] else ltrimstr("Files:") | split(",") | map(sub("^\\s+"; "") | sub("\\s+\\(.*$"; "") | sub("[\\s.]+$"; "")) end
  | [.[] | if $r then ltrimstr($r + ":") else . end | strip];

def load($s; $r):
  reduce inputs as $x ({tracks: {}, features: {}, phases: {}};
    (input_filename | ltrimstr($s + "/") | ltrimstr($r + "/") | split("/")) as $p
    | if $p[0] == "tracks" then .tracks[$p[1] | rtrimstr(".json")] = $x
      elif $p[0] == "features" and $p[2] == "events.jsonl" then .features[$p[1]].events += [$x]
      elif $p[0] == "features" then .features[$p[1]][$p[2] | rtrimstr(".json")] = $x
      elif $p[0] == "archive" then .archive[$p[1]][$p[2] | rtrimstr(".json")] = $x
      elif $p[2] == "tasks" then .phases[$p[1]].tasks += [$x]
      elif $p[2] == "events.jsonl" then .phases[$p[1]].events += [$x]
      else .phases[$p[1]][$p[2] | rtrimstr(".json")] = $x end);

def shipped($p): [$p.tracks[] | .track as $t | .shipped[] | "\($t)/\(.feature)"];
def qual($t): if contains("/") then . else "\($t)/\(.)" end;
def fdir($p; $t; $f): $p.features["\($t)-\($f)"];
def pdone($p; $t; $f):
  [fdir($p; $t; $f).split.phases[] | .number // empty] as $n
  | [$p.phases[] | select(.spec.track == $t and .spec.feature == $f and (.spec.number | IN($n[])) and .result.status == "done")] | length;
def progress($p; $t; $f):
  (fdir($p; $t; $f).split.phases // null) as $s
  | if $s == null then "—" else "\(pdone($p; $t; $f))/\($s | length)" end;
def fstatus($p; $t; $f):
  (fdir($p; $t; $f) // {}) as $d
  | if ("\($t)/\($f)" | IN(shipped($p)[])) or $d.ship then "shipped"
    elif $d.verify then "ship"
    elif $d.split then (if pdone($p; $t; $f) >= ($d.split.phases | length) then "verify" else "discussed" end)
    elif $d.spec or $d.research then "discussing"
    else "todo" end;
def stalled($p; $t; $f):
  any($p.phases[] | select(.spec.track == $t and .spec.feature == $f and .result.status != "done") | .events // [] | last
      | select(. != null) | .step == "stall" and (.message | endswith("; operator notified")); .);
def unmet($p; $t; $fe): [$fe.depends[] | select(qual($t) | IN(shipped($p)[]) | not)];
def open($p): [$p.tracks[] | select(.status == "open")];
def fcell($p; $t; $f): if stalled($p; $t; $f) then "stalled" else fstatus($p; $t; $f) end;

def day: try (strptime("%Y-%m-%d") | mktime) catch empty;
def intake($in; $now):
  ($now | if . == null then null else strflocaltime("%Y-%m-%d") | day end) as $today
  | [$in | group_by(.repo)[] | {repo: .[0].repo, todos: [.[].todos // [] | .[]], seeds: [.[].seeds // [] | .[]], concerns: [.[].concerns // [] | .[]]}
     | select((.todos | length) + (.seeds | length) + (.concerns | length) > 0)
     | [(.todos + .seeds + .concerns)[] | .date // empty | day] as $d
     | [.repo, (.todos | length), (.seeds | length), (.concerns | length),
        (if ($d | length) == 0 then "—" elif $today == null then "unknown" else ($today - ($d | min)) / 86400 | floor end)]]
  | if length == 0 then "" else "\n\n## Intake\n\n" + grid(["Repo", "Todos", "Seeds", "Concerns", "Oldest"]) end;
def status($p; $in; $now):
  open($p) as $open
  | "## Tracks\n\n"
  + ($open | map([.track, (.features | length), (.shipped | length)])
     | grid(["Track", "Open features", "Shipped"]) | dash)
  + "\n\n## Features\n\n"
  + ([$open[] | .track as $t | .features[]
      | [$t, .feature, fcell($p; $t; .feature), progress($p; $t; .feature), (.depends | first_more), (unmet($p; $t; .) | first_more)]]
     | grid(["Track", "Feature", "Status", "Phases", "Depends on", "Waiting on"]) | dash)
  + intake($in; $now);

def reqs: [(.requirements // [])[] | {id, text, done}];
def todo_line:
  (capture("^(?<date>[0-9]{4}-[0-9]{2}-[0-9]{2}) (?<text>.*)$") // {text: .})
  | . + {concern: [.text | capture(" — concern: (?<c>[^ :]+:C-[0-9]{2,})$").c][0]};
def todo_items: [split("\n")[] | rtrimstr("\r") | select(startswith("- ")) | .[2:] | todo_line];
def cphase($p; $t; $f):
  first(fdir($p; $t; $f).split.phases[] | select(.number != null) | .number as $n
    | select(any($p.phases[]; .spec.track == $t and .spec.feature == $f and .spec.number == $n and .result.status == "done") | not)
    | {number: ($n | tonumber), name: .slug}) // null;
def lastact($p; $t; $f):
  [($p.phases[] | select(.spec.track == $t and .spec.feature == $f) | .events // [] | .[]), (fdir($p; $t; $f).events // [] | .[])
   | .time // empty] | max;
def shipped_json($p; $t):
  [.shipped[] | {feature, date,
   requirements: ($p.archive["\($t)-\(.feature)"].requirements // fdir($p; $t; .feature).requirements | reqs)}];
def status_json($p; $todo; $seeds; $c; $h):
  {tracks: [open($p)[] | .track as $t
     | {track: $t, goal,
        features: [.features[] | .feature as $f | fdir($p; $t; $f) as $d | fcell($p; $t; $f) as $s
          | (($s | IN("verify", "ship", "stalled")) or ($s == "discussed" and $d.split.phases != null)) as $now
          | {feature: $f, delivers, status: $s,
             phases: ($d.split.phases // null | if . == null then null else {done: pdone($p; $t; $f), total: length} end),
             depends, waiting: unmet($p; $t; .),
             current_phase: (if $now then cphase($p; $t; $f) else null end),
             last_activity: (if $now then lastact($p; $t; $f) else null end),
             requirements: ($d.requirements | reqs)}],
        shipped: shipped_json($p; $t)}],
   closed_tracks: [$p.tracks[] | select(.status == "closed") | .track as $t | {track: $t, goal, shipped: shipped_json($p; $t)}],
   quicks: [$h.quicks[] | {slug, task, repos, date, source: (.source // "forge")}],
   debugs: [$h.debugs[] | {slug, symptom, cause, repos, date, source: (.source // "forge")}],
   gsd_history: [$h.repos[] | {repo, milestones: [.milestones[] | {version, name, shipped, phases: [.phases[] | {number, name}]}]}],
   todos: ($todo | todo_items | map({text, concern})),
   seeds: ($seeds | todo_items | map({text})),
   concerns: $c};

def research:
  map("- \(.question) — \(.answer)" + (if (.sources | length) > 0 then " (\(.sources | join(", ")))" else "" end))
  | join("\n");

def feature_view($p; $t; $f):
  first($p.tracks[] | select(.track == $t)) as $tr
  | first(($tr.features[], $tr.shipped[]) | select(.feature == $f)) as $fe
  | (fdir($p; $t; $f) // $p.archive["\($t)-\($f)"] // {}) as $d
  | "# \($t) / \($f)\n\n\($fe.delivers | dash)\n\n"
  + "Status: \(fcell($p; $t; $f))\nDepends on: \($fe.depends // [] | csv)\nFocus: \($d.spec.focus // [] | csv)\n\n"
  + ([["Decisions", ($d.spec.decisions // [] | bullets)],
      ["Spec", ($d.spec.spec // [] | bullets)],
      ["Requirements", ($d.requirements.requirements // []
        | map("- [\(if .done then "x" else " " end)] \(.id) (\(.owner // "agent")): \(.text)" + (if .accepted then " — accepted: \(.accepted)" else "" end) + (if .concern then " — concern: \(.concern)" else "" end))
        | join("\n"))],
      ["Research", ($d.research.questions // [] | research)],
      ["Design", (if $d.design then
          [($d.design.brief // [] | bullets),
           ($d.design.mockups // []
            | map("- \(.path) — \(if .approved then "approved" else "not approved" end) — \(.notes | join("; ") | dash)")
            | join("\n"))] | paras
        else "" end)],
      ["Phases", ($d.split.phases // []
        | map(.number as $n
          | "| \(if $n then "\($n)-\(.slug)" else .slug end) | \(.goal | cell) | \(.depends | csv) | \(.requirements | csv) | \(
              first($p.phases[] | select(.spec.track == $t and .spec.feature == $f and $n != null and .spec.number == $n) | .result.status) // "—") |")
        | table("| Phase | Goal | Depends on | Requirements | Status |\n|---|---|---|---|---|"))],
      ["Manual test", (if $d.verify then
          [($d.verify.manual_test // [] | to_entries | map("\(.key + 1). \(.value)") | join("\n")),
           "Result: \($d.verify.result)",
           ($d.verify.gaps // [] | map("\(.phase): \(.gap)") | bullets)] | paras
        else "" end)],
      ["Final review", ($d.ship.final_review // [] | bullets)],
      ["PR", ($d.ship.pr // "")]]
     | map("## \(.[0])\n\(.[1] | dash)") | join("\n\n"));

def sentences:
  explode as $c
  | reduce range($c | length) as $i ({out: [], cur: [], code: false, skip: false};
      $c[$i] as $x
      | if .skip and $x == 32 then . else
          .skip = false | .cur += [$x]
          | if $x == 96 then .code |= not else . end
          | if (.code | not) and ($x | IN(46, 63, 33)) and $c[$i + 1] == 32
              and ([$c[$i + 1:][] | select(. != 32)][0] // 32 | . == 96 or ([.] | implode | test("^\\p{Lu}$")))
              and ($x != 46 or (.cur | implode | test("(^|[^A-Za-z])(e\\.g|i\\.e|etc|vs|Dr|No)\\.$") | not))
            then .out += [.cur | implode] | .cur = [] | .skip = true
            else . end
        end)
  | .out[], (if .cur == [] then empty else .cur | implode end);

def sentence_lines($p): $p + ([sentences] | join("\n" + ("" | pad($p | length))));

def sentence_bullet:
  "- " + . | split("\n")
  | map(capture("^(?<p> *(?:[-*+] |[0-9]+[.)] )?)(?<t>.*)$")
    | .p as $p | .t | sentence_lines($p))
  | join("\n");

def map_doc($tpl):
  ($tpl | split("\n## ")[0] | rtrimstr("\n")) + "\n\n"
  + (.sections | map("## \(.heading)\n\n\(.bullets | map(sentence_bullet) | join("\n") | dash)") | join("\n\n")) + "\n";

def concerns_doc($tpl):
  ($tpl | rtrimstr("\n")) + "\n\n"
  + (.concerns | map(select(.status == "open")) | map("- \(.id) — \(.area) — \(.files | csv) — \(.severity) — \(.focus | csv) — \(.evidence | map("`\(.)`") | csv) — \(.status)\(if .text then " — \(.text)" else "" end)")
     | join("\n") | dash) + "\n";

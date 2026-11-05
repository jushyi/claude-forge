def prune($p):
  if ($p | length) < 2 then .
  else $p[:-1] as $q
    | if getpath($q) == {} then delpaths([$q]) | prune($q) else . end
  end;
def strip($rec):
  (reduce ($rec.added // [])[] as $a (.;
    if (try getpath($a.path) catch null) == $a.value then delpaths([$a.path]) | prune($a.path) else . end))
  | (reduce ($rec.hooks // [])[] as $h (.;
      if (.hooks[$h.event]? | type) == "array" then
        .hooks[$h.event] |= map(select(. != $h.entry))
        | if .hooks[$h.event] == [] then del(.hooks[$h.event]) else . end
        | if .hooks == {} then del(.hooks) else . end
      else . end));
def fill($w):
  reduce ($w | keys_unsorted[]) as $k (.;
    if has($k) then
      if (.[$k] | type) == "object" and ($w[$k] | type) == "object" then .[$k] |= fill($w[$k]) else . end
    else .[$k] = $w[$k] end);
def commands: [.hooks[]?.command];
def newhooks($u; $w):
  [($w.hooks // {}) | to_entries[] | .key as $e | .value[]
    | . as $entry | (commands) as $c
    | select([($u.hooks[$e]? // [])[] | commands] | index([$c]) | not)
    | {event: $e, entry: $entry}];
def merged($w):
  . as $u
  | fill($w | del(.hooks))
  | reduce newhooks($u; $w)[] as $h (.; .hooks[$h.event] = ((.hooks[$h.event]? // []) + [$h.entry]));
def added($u; $w):
  [$w | del(.hooks) | . as $d | paths(type != "object" or length == 0) as $p
    | select((try ($u | getpath($p)) catch 0) == null)
    | {path: $p, value: ($d | getpath($p))}];

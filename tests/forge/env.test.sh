#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/../forge-common.sh"

envsh=$root/bin/forge.d/env.sh
if want load; then
probe() { FORGE_ENV=$1 bash -c 'set -euo pipefail; . "$1"; forge_host_env; printenv "$2" || echo unset' _ "$envsh" "$2" 2>"$tmp/err"; }
e=$tmp/env
printf '# host\n\nFORGE_MAX_SESSIONS=20\nFORGE_TEST_SLOTS=6\n' >"$e"
[ "$(probe "$e" FORGE_MAX_SESSIONS)" = 20 ] && [ ! -s "$tmp/err" ] || fail "a FORGE_ line is exported: $(cat "$tmp/err")"
[ "$(FORGE_MAX_SESSIONS=12 probe "$e" FORGE_MAX_SESSIONS)" = 20 ] || fail "the host file overrides an inherited value such as global/settings.json's"
[ "$(probe "$e" FORGE_TEST_SLOTS)" = 6 ] || fail "every FORGE_ line is exported"
[ "$(probe "$tmp/none" FORGE_MAX_SESSIONS)" = unset ] && [ ! -s "$tmp/err" ] || fail "a missing file exports nothing and says nothing: $(cat "$tmp/err")"
printf 'PATH=/x\nFORGE_A=$(id)\nFORGE_B=`id`\nexport FORGE_C=1\nFORGE_ENV=/y\nFORGE_D=ok\n' >"$e"
[ "$(probe "$e" FORGE_D)" = ok ] || fail "valid lines still apply beside invalid ones: $(cat "$tmp/err")"
[ "$(grep -c '^forge: warning: .*: ignoring line ' "$tmp/err")" = 5 ] || fail "each non-FORGE_, substituting, export or FORGE_ENV line is ignored with a warning: $(cat "$tmp/err")"
for v in PATH FORGE_A FORGE_B FORGE_C; do
  [ "$(probe "$e" "$v")" != /x ] && [ "$(probe "$e" "$v")" = "$(printenv "$v" || echo unset)" ] || fail "$v is not set from an ignored line"
done
ok load
fi

if want forge; then
mkdir -p "$tmp/xdg/forge" "$tmp/plain"
printf 'FORGE_MAX_SESSIONS=21\n' >"$tmp/xdg/forge/env"
mkdir -p "$tmp/jbin"
printf '#!/usr/bin/env bash\nexec printenv FORGE_MAX_SESSIONS\n' >"$tmp/jbin/notify-send" && chmod +x "$tmp/jbin/notify-send"
got=$(cd "$tmp/plain" && env -u FORGE_ENV PATH="$tmp/jbin:$PATH" XDG_CONFIG_HOME="$tmp/xdg" "$forge" notify t b 2>"$tmp/err") || fail "forge notify ran: $(cat "$tmp/err")"
[ "$got" = 21 ] || fail "forge reads \$XDG_CONFIG_HOME/forge/env without FORGE_ENV: got '$got' $(cat "$tmp/err")"
got=$(cd "$tmp/plain" && PATH="$tmp/jbin:$PATH" XDG_CONFIG_HOME="$tmp/xdg" "$forge" notify t b 2>"$tmp/err") || got=unset
[ "$got" = unset ] || fail "FORGE_ENV=/dev/null from the test helper keeps the host file out: got '$got'"
ok forge
fi

if want host; then
common=$root/tests/forge-common.sh
hen() { XDG_CONFIG_HOME=$1 bash -c 'set -euo pipefail; if [ -n "$3" ]; then export FORGE_ENV=$3; else unset FORGE_ENV; fi; . "$1"; forge_host_env; [ "${FORGE_HEN_UNKNOWN:-}" = 1 ] && [ "${FORGE_TEST_CPU_PRESSURE:-}" = 100 ] || { echo "not exported"; exit 0; }; bash -c "set -euo pipefail; . \"\$1\"; printenv FORGE_HEN_UNKNOWN FORGE_TEST_CPU_PRESSURE || echo none" _ "$2"' _ "$envsh" "$common" "${2:-}" 2>"$tmp/err"; }
mkdir -p "$tmp/hx/forge" "$tmp/hxe"
printf 'FORGE_HEN_UNKNOWN=1\nFORGE_TEST_CPU_PRESSURE=100\n' >"$tmp/hx/forge/env"
cp "$tmp/hx/forge/env" "$tmp/henv"
got=$(hen "$tmp/hx") || fail "a suite sourcing forge-common.sh runs under the XDG host file: $(cat "$tmp/err")"
[ "$got" = none ] || fail "keys of \$XDG_CONFIG_HOME/forge/env never reach a suite: got '$got' $(cat "$tmp/err")"
got=$(hen "$tmp/hxe" "$tmp/henv") || fail "a suite sourcing forge-common.sh runs under an inherited FORGE_ENV file: $(cat "$tmp/err")"
[ "$got" = none ] || fail "keys of an inherited FORGE_ENV file never reach a suite: got '$got' $(cat "$tmp/err")"
rt=$tmp/rt
mkdir -p "$rt/tests" && git -C "$rt" init -q && cp "$root/tests/forge.test.sh" "$common" "$rt/tests/"
printf '#!/usr/bin/env bash\nset -euo pipefail\n. "$(dirname "$0")/forge-common.sh"\nprintenv FORGE_HEN_UNKNOWN FORGE_TEST_CPU_PRESSURE || echo none\n' >"$rt/tests/probe.test.sh" && chmod +x "$rt/tests/probe.test.sh"
XDG_CONFIG_HOME="$tmp/hxe" FORGE_ENV="$tmp/henv" FORGE_TEST_LOG_DIR="$tmp/rtl" bash -c 'set -euo pipefail; . "$1"; forge_host_env; [ "${FORGE_HEN_UNKNOWN:-}" = 1 ] || exit 3; exec "$2"' _ "$envsh" "$rt/tests/forge.test.sh" >"$tmp/out" 2>&1 || fail "the runner starts a suite under an inherited FORGE_ENV file: $(cat "$tmp/out")"
[ "$(cat "$tmp/rtl/probe.log")" = none ] || fail "keys of an inherited FORGE_ENV file never reach a suite the runner starts: got '$(cat "$tmp/rtl/probe.log")'"
printf 'FORGE_HEN_UNKNOWN=1\n' >"$tmp/hunread" && chmod 000 "$tmp/hunread"
for f in "$tmp/none" "$tmp/hunread"; do
  got=$(FORGE_ENV="$f" XDG_CONFIG_HOME="$tmp/hxe" bash -c '. "$1"; echo sourced' _ "$common" 2>"$tmp/err") || got=failed
  [ "$got" = sourced ] || fail "a missing or unreadable host env file never fails a suite: $f got '$got' $(cat "$tmp/err")"
done
ok host
fi

mem() {
  local want=$1 what=$2 fn=${3:-forge_mem_available} s=0
  bash -c 'set -euo pipefail; . "$1"; "$2"' _ "$envsh" "$fn" >"$tmp/out" 2>"$tmp/err" || s=$?
  if [ -z "$want" ]; then
    [ "$s" = 1 ] || fail "$fn with $what must return 1, got $s: $(cat "$tmp/out")"
    [ ! -s "$tmp/out" ] || fail "$fn with $what must print nothing: $(cat "$tmp/out")"
  else
    [ "$s" = 0 ] || fail "$fn with $what must return 0, got $s: $(cat "$tmp/err")"
    [ "$(cat "$tmp/out")" = "$want" ] || fail "$fn with $what must print $want, got: $(cat "$tmp/out")"
  fi
  [ ! -s "$tmp/err" ] || fail "$fn with $what must print nothing on stderr: $(cat "$tmp/err")"
}

if want mem-available; then
rm -rf "$FORGE_PROC_ROOT"; mkdir -p "$FORGE_PROC_ROOT"
printf 'MemTotal:       32768000 kB\nMemFree:         1024000 kB\nMemAvailable:   16384000 kB\nBuffers:          204800 kB\n' >"$FORGE_PROC_ROOT/meminfo"
mem 16384000 "MemAvailable 16384000 kB"
printf 'MemTotal:       32768000 kB\nMemFree:         1024000 kB\n' >"$FORGE_PROC_ROOT/meminfo"
mem "" "no MemAvailable line"
printf 'MemTotal:       32768000 kB\nMemAvailable:   lots kB\n' >"$FORGE_PROC_ROOT/meminfo"
mem "" "a non-numeric MemAvailable"
rm -f "$FORGE_PROC_ROOT/meminfo"
mem "" "no meminfo"
ok mem-available
fi

if want mem-total; then
mkdir -p "$FORGE_PROC_ROOT"
printf 'MemFree:         1024000 kB\nMemTotal:       32768000 kB\nMemAvailable:   16384000 kB\n' >"$FORGE_PROC_ROOT/meminfo"
mem 32768000 "MemTotal 32768000 kB" forge_mem_total
printf 'MemFree:         1024000 kB\nMemAvailable:   16384000 kB\n' >"$FORGE_PROC_ROOT/meminfo"
mem "" "no MemTotal line" forge_mem_total
printf 'MemTotal:       lots kB\nMemAvailable:   16384000 kB\n' >"$FORGE_PROC_ROOT/meminfo"
mem "" "a non-numeric MemTotal" forge_mem_total
rm -f "$FORGE_PROC_ROOT/meminfo"
mem "" "no meminfo" forge_mem_total
ok mem-total
fi
finish

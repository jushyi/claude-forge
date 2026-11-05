#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
only=${1:-}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export HOME=$tmp/home LC_ALL=C
mkdir -p "$HOME" "$tmp/run/systemd/system" "$tmp/nosd" "$tmp/proc"
fail() { echo "preflight: FAIL $*" >&2; exit 1; }
want() { [ -z "$only" ] || [ "$only" = "$1" ]; }
ok() { echo "preflight $1: ok"; [ "$1" != "$only" ] || exit 0; }
refused() {
  local s=0 mode
  for mode in --apply ""; do
    s=0
    env "$@" "$root/port" ${mode:+"$mode"} >"$tmp/out" 2>&1 || s=$?
    [ "$s" = 1 ] || fail "port ${mode:-dry run} must refuse with exit 1 under $*, got $s: $(cat "$tmp/out")"
    [ -z "$(ls -A "$HOME")" ] || fail "port must change nothing when refused under $*: $(ls -A "$HOME")"
    grep -q '^port: nothing changed' "$tmp/out" || fail "port must say nothing changed under $*: $(cat "$tmp/out")"
  done
}

if want "native windows refused"; then
for u in MINGW64_NT-10.0-22631 MSYS_NT-10.0 CYGWIN_NT-10.0; do
  refused FORGE_UNAME="$u"
  grep -q 'does not run on native Windows' "$tmp/out" && grep -q 'wsl --install' "$tmp/out" || fail "$u must point at WSL2: $(cat "$tmp/out")"
done
ok "native windows refused"
fi

if want "linux without systemd refused"; then
refused FORGE_UNAME=Linux FORGE_PROC_ROOT="$tmp/proc" FORGE_RUN_ROOT="$tmp/nosd"
grep -q 'Linux without systemd is unsupported' "$tmp/out" || fail "must state Linux without systemd is unsupported: $(cat "$tmp/out")"
ok "linux without systemd refused"
fi

if want "wsl without systemd gets the fix"; then
echo 'Linux version 5.15.153.1-microsoft-standard-WSL2' >"$tmp/proc/version"
refused FORGE_UNAME=Linux FORGE_PROC_ROOT="$tmp/proc" FORGE_RUN_ROOT="$tmp/nosd"
grep -qxF '[boot]' "$tmp/out" && grep -qxF 'systemd=true' "$tmp/out" && grep -q '/etc/wsl.conf' "$tmp/out" || fail "WSL2 must print the wsl.conf fix: $(cat "$tmp/out")"
rm "$tmp/proc/version"
ok "wsl without systemd gets the fix"
fi

if want "unknown system refused"; then
refused FORGE_UNAME=FreeBSD
grep -q 'unsupported' "$tmp/out" || fail "an unknown system must be refused: $(cat "$tmp/out")"
ok "unknown system refused"
fi

if want "missing tools each print one install line"; then
mkdir "$tmp/bin"
for t in bash dirname uname grep sed env cat git python3 curl flock sha256sum timeout readlink; do
  ln -s "$(command -v "$t")" "$tmp/bin/$t"
done
refused PATH="$tmp/bin" FORGE_UNAME=Linux FORGE_PROC_ROOT="$tmp/proc" FORGE_RUN_ROOT="$tmp/run"
for t in jq rsync "Claude Code" check-jsonschema; do
  [ "$(grep -c "^install $t" "$tmp/out")" = 1 ] || fail "missing $t must print one install line: $(cat "$tmp/out")"
done
! grep -q '^install git' "$tmp/out" || fail "a present tool must print no line: $(cat "$tmp/out")"
ok "missing tools each print one install line"
fi

if want "mac asks for Homebrew tools"; then
ln -sf "$(command -v true)" "$tmp/bin/jq"
refused PATH="$tmp/bin" FORGE_UNAME=Darwin
grep -q 'brew install' "$tmp/out" || fail "macOS must print brew lines: $(cat "$tmp/out")"
ok "mac asks for Homebrew tools"
fi

[ -z "$only" ] || fail "no case $only"

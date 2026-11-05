unset FORGE_TEST_MIN_SECS
export FORGE_TEST_POLL_SECS=0.02
tlinks() { local l; for l in /tmp/fg-*; do if [ -L "$l" ] && [[ $(readlink "$l") == "$tmp"/* ]]; then rm -f "$l"; fi; done; }
trap 'tlinks; rm -rf "$tmp"' EXIT
mkdir -p "$tmp/path"
IFS=: read -ra dirs <<<"$PATH"
for d in "${dirs[@]}"; do [ ! -d "$d" ] || ln -s -t "$tmp/path" "$d"/* 2>/dev/null || true; done
rm -f "$tmp/path/systemd-run" "$tmp/path/systemctl"
export PATH=$tmp/path

fail() { echo "$suite: FAIL $*" >&2; exit 1; }
only=${1:-}
ok() { echo "$suite $1: ok"; [ "$1" != "$only" ] || exit 0; }
want() { [ -z "$only" ] || [ "$only" = "$1" ]; }
want_any() { local c; [ -n "$only" ] || return 0; for c; do [ "$only" != "$c" ] || return 0; done; return 1; }
code() { local s=0; "$@" >"$tmp/out" 2>&1 || s=$?; echo $s; }
lastline() { tail -n1 "$tmp/out"; }
gitinit() { git init -q -b main "$1" && git -C "$1" config user.name forge && git -C "$1" config user.email forge@example.com; }
skey() { printf 'k%s' "$(git -C "$1" rev-parse --absolute-git-dir | tr -d '\n' | sha256sum | cut -c1-12)"; }

hid=$(tr -d '[:space:]' </etc/machine-id)
"$forge" --help >"$tmp/forge-help" || fail "forge --help exits 0"

lint() { bash -c 'set -euo pipefail; shopt -s nullglob; for m in "$1"/bin/forge.d/*.sh; do . "$m"; done; test_lint "$2"' _ "$root" "$1"; }
lr=$tmp/lint
mkdir -p "$lr"
lintdoc() { rm -rf "$lr/$1"; mkdir -p "$lr/$1/.forge"; printf '%s\n' "# Testing" "" "## Commands" "${@:2}" >"$lr/$1/.forge/TESTING.md"; }
names_line() { grep -qwF "$1" "$tmp/out" || grep -qF -- "$2" "$tmp/out"; }
pstart() { local l a; read -r l <"/proc/$1/stat"; read -ra a <<<"${l##*) }"; echo "${a[19]}"; }

r=$tmp/r
gitinit "$r"
mkdir -p "$r/.forge" "$r/sub"
printf '# Testing\n\n## Commands\n- Unit: `false`\n- All tests: `./t.sh` from the top.\n- All tests: `false`\n' >"$r/.forge/TESTING.md"
cat >"$r/t.sh" <<'EOF'
#!/usr/bin/env bash
echo "ran in $PWD"
[ -z "${T_MUTATE:-}" ] || echo mutated >>a.txt
exit "$(cat "$T_EXIT")"
EOF
chmod +x "$r/t.sh"
echo a >"$r/a.txt"
git -C "$r" add -A && git -C "$r" commit -q -m init
export T_EXIT=$tmp/exit
echo 0 >"$T_EXIT"
log=$r/.git/forge-test.log
tree() { git -C "$r" rev-parse HEAD^{tree}; }
short() { git -C "$r" rev-parse --short HEAD^{tree}; }
hk=0123456789abcdef0123456789abcdef
[ "$hk" != "$hid" ] || hk=fedcba9876543210fedcba9876543210
mfs=(package.json package-lock.json pnpm-lock.yaml pnpm-workspace.yaml yarn.lock pyproject.toml uv.lock poetry.lock 'requirements*.txt' Cargo.toml Cargo.lock go.mod go.sum)
shash() { { echo "$2" && (cd "$1" && git ls-files -z -co --exclude-standard -- "${mfs[@]/#/:(glob)**/}" | LC_ALL=C sort -zu | xargs -0r sha256sum --); } | sha256sum | cut -d' ' -f1; }
x=$tmp/x
gitinit "$x"
mkdir -p "$x/.forge"
printf '# Testing\n\n## Commands\n- All tests: `./t.sh all`\n- Test: `./t.sh one {test}`\n- Changed tests: `./t.sh changed {files}`\n' >"$x/.forge/TESTING.md"
cat >"$x/t.sh" <<'EOF'
#!/usr/bin/env bash
printf '[%s]' "$@" >>"$T_LOG"
echo >>"$T_LOG"
[ -z "${T_FDS:-}" ] || ls -l /proc/$$/fd >"$T_FDS"
[ -z "${T_ENV:-}" ] || echo "${FORGE_TEST_SLOT_HELD-unset}" >"$T_ENV"
[ -z "${T_HOLD:-}" ] || until [ -f "$T_HOLD" ]; do sleep 0.1; done
[ -z "${T_FULL:-}" ] || : >"$FORGE_TEST_LOG_DIR/.full"
echo "ran $*"
exit "$(cat "$T_EXIT")"
EOF
chmod +x "$x/t.sh"
echo a >"$x/a.txt" && echo '*.log' >"$x/.gitignore"
git -C "$x" add -A && git -C "$x" commit -q -m init && git -C "$x" checkout -q -b side
export T_LOG=$tmp/t.log
st=$x/.git/forge-test
xtree() { git -C "$x" rev-parse HEAD^{tree}; }
xshort() { git -C "$x" rev-parse --short HEAD^{tree}; }
ran() { cat "$T_LOG" 2>/dev/null || true; }
mkdir -p "$tmp/fake"
rd=$(command -v date)
cat >"$tmp/fake/date" <<EOF
#!/usr/bin/env bash
[ "\$*" = +%s ] || exec "$rd" "\$@"
n=\$(cat "$tmp/now" 2>/dev/null || echo 1000000)
echo \$((n + 61)) >"$tmp/now"
echo "\$n"
EOF
chmod +x "$tmp/fake/date"
mkdir -p "$tmp/cpubin"
printf '#!/usr/bin/env bash\necho "$NPROC"\n' >"$tmp/cpubin/nproc"
chmod +x "$tmp/cpubin/nproc"
sd=$tmp/sd
mkdir -p "$sd"
cat >"$sd/systemd-run" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$SD_LOG"
e=1
while [ $# -gt 0 ] && [ "$1" != -- ]; do [ "$1" != --expand-environment=no ] || e=; shift; done
shift
[ -z "$e" ] || set -- "${@//\$/}"
[ "$*" != true ] || exit "$(cat "$SD_PROBE")"
s=0
"$@" || s=$?
c=$(head -n1 "$SD_CODES")
sed -i 1d "$SD_CODES"
exit "${c:-$s}"
EOF
cat >"$sd/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$SC_LOG"
[ -z "${SC_FAIL:-}" ] || { echo "Failed to connect to bus" >&2; exit 1; }
[ "$2" = show ] || exit 0
[ "$4" != MemoryPeak ] || { echo "[not set]"; exit 0; }
[ -z "${SC_OOM_UNIT:-}" ] || [[ $6 == $SC_OOM_UNIT ]] || { echo success; exit 0; }
k=$(cat "$SC_OOM")
if [ "$k" -gt 0 ]; then echo $((k - 1)) >"$SC_OOM"; echo oom-kill; else echo success; fi
EOF
chmod +x "$sd"/*
export SD_LOG=$tmp/sd.log SC_LOG=$tmp/sc.log SD_PROBE=$tmp/sd.probe SD_CODES=$tmp/sd.codes SC_OOM=$tmp/sc.oom
mem() { : >"$T_LOG"; : >"$SD_LOG"; : >"$SC_LOG"; echo "${1:-0}" >"$SD_PROBE"; printf '%s' "${2:-}" >"$SD_CODES"; echo "${3:-0}" >"$SC_OOM"; }
units() { sed -n 's/.*--unit=\([^ ]*\).*/\1/p' "$SD_LOG"; }
reset() { local u; for u in $(units); do grep -qxF -- "--user reset-failed $u.scope" "$SC_LOG" || return 1; done; }
scopes() { grep -- "^--user --scope" "$SD_LOG" || true; }
props() { echo "--expand-environment=no -p MemoryMax=$1 -p MemoryHigh=$2 -p MemorySwapMax=0"; }
p4=$(props 4G 3774873K)
mkdir -p "$tmp/sbin"
for c in systemd-run systemctl; do
  printf '#!/usr/bin/env bash\n{ printf %%s %s; printf "[%%s]" "$@"; echo; } >>"$K_LOG"\necho "%s stub output"\n' "$c" "$c" >"$tmp/sbin/$c"
done
echo 'exit "$(cat "$SR_EXIT")"' >>"$tmp/sbin/systemd-run"
cat >"$tmp/sbin/systemctl" <<'EOF'
#!/usr/bin/env bash
{ printf %s systemctl; printf "[%s]" "$@"; echo; } >>"$K_LOG"
[ "$2" != is-active ] || { echo inactive; exit 3; }
echo "systemctl stub output"
e=$(head -n1 "$SC_EXIT")
[ "$(wc -l <"$SC_EXIT")" -le 1 ] || sed -i 1d "$SC_EXIT"
exit "$e"
EOF
chmod +x "$tmp"/sbin/*
export K_LOG=$tmp/k.log ST_EXIT=$tmp/stexit SR_EXIT=$tmp/srexit SC_EXIT=$tmp/scexit
echo 0 >"$ST_EXIT" && echo 0 >"$SR_EXIT" && echo 0 >"$SC_EXIT"
mkdir -p "$tmp/tsbin"
cat >"$tmp/tsbin/systemctl" <<'EOF'
#!/usr/bin/env bash
u=${!#}
case " $* " in
*" stop "*) e=$(head -n1 "$TS_STOP"); [ "$(wc -l <"$TS_STOP")" -le 1 ] || sed -i 1d "$TS_STOP"; exit "$e" ;;
*" is-active "*) [ ! -s "$TS_BUS" ] || { echo "Failed to connect to user scope bus" >&2; exit 1; }; if [ "$u" = "$(cat "$TS_ACTIVE")" ]; then echo active; exit 0; fi; echo inactive; exit 3 ;;
*" show "*) if [ "$u" = "$(cat "$TS_ACTIVE")" ]; then echo active; else echo inactive; fi ;;
esac
exit 0
EOF
chmod +x "$tmp/tsbin/systemctl"
export TS_STOP=$tmp/ts-stop TS_ACTIVE=$tmp/ts-active TS_BUS=$tmp/ts-bus
printf '0\n1\n' >"$TS_STOP" && : >"$TS_ACTIVE" && : >"$TS_BUS"

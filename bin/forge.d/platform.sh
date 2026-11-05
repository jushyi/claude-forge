forge_os() {
  case ${FORGE_UNAME:-$(uname -s)} in
    Darwin) echo mac ;;
    MINGW* | MSYS* | CYGWIN*) echo windows ;;
    Linux)
      if grep -qsi microsoft "${FORGE_PROC_ROOT:-/proc}/version"; then echo wsl; else echo linux; fi ;;
    *) echo unknown ;;
  esac
}

forge_gnubin() {
  [ "$(forge_os)" = mac ] || return 0
  local b g
  for b in /usr/local /opt/homebrew; do
    [ -d "$b" ] || continue
    PATH=$b/bin:$PATH
    for g in coreutils findutils gnu-sed; do
      [ ! -d "$b/opt/$g/libexec/gnubin" ] || PATH=$b/opt/$g/libexec/gnubin:$PATH
    done
    for g in flock rsync; do
      [ ! -d "$b/opt/$g/bin" ] || PATH=$b/opt/$g/bin:$PATH
    done
  done
  export PATH
}

forge_install_line() {
  local os=$1 tool=$2 p=$2
  case $tool in
    claude) echo "install Claude Code: npm install -g @anthropic-ai/claude-code"; return ;;
    check-jsonschema) echo "install check-jsonschema: pipx install check-jsonschema"; return ;;
    python3) [ "$os" != mac ] || p=python ;;
    flock) [ "$os" = mac ] || p=util-linux ;;
    sha256sum | timeout) p=coreutils ;;
    gnu-sed) p=gnu-sed ;;
    findutils) p=findutils ;;
  esac
  if [ "$os" = mac ]; then echo "install $tool: brew install $p"
  elif command -v apt-get >/dev/null; then echo "install $tool: sudo apt-get install -y $p"
  elif command -v dnf >/dev/null; then echo "install $tool: sudo dnf install -y $p"
  elif command -v pacman >/dev/null; then echo "install $tool: sudo pacman -S --needed $p"
  else echo "install $tool with your package manager"
  fi
}

forge_preflight() {
  local os t bad=0 run=${FORGE_RUN_ROOT:-/run}
  os=$(forge_os)
  case $os in
    windows)
      echo "forge does not run on native Windows. Use WSL2: run 'wsl --install -d Ubuntu' in an administrator PowerShell, enable systemd in /etc/wsl.conf, then clone and install forge inside WSL."
      return 1 ;;
    unknown)
      echo "forge supports Linux with systemd, macOS and Windows through WSL2; this system is unsupported."
      return 1 ;;
    wsl)
      [ -d "$run/systemd/system" ] || {
        printf 'forge needs systemd in WSL2. Add these lines to /etc/wsl.conf, run "wsl --shutdown" in Windows, then reopen WSL:\n[boot]\nsystemd=true\n'
        return 1
      } ;;
    linux)
      [ -d "$run/systemd/system" ] || {
        echo "forge needs systemd for its watchdog and test limits. Linux without systemd is unsupported."
        return 1
      } ;;
  esac
  for t in git jq rsync flock python3 curl claude check-jsonschema sha256sum timeout; do
    command -v "$t" >/dev/null && continue
    forge_install_line "$os" "$t"
    bad=1
  done
  if [ "$os" = mac ]; then
    sed --version >/dev/null 2>&1 || { forge_install_line mac gnu-sed; bad=1; }
    find --version >/dev/null 2>&1 || { forge_install_line mac findutils; bad=1; }
    command -v bash >/dev/null && [ "$(bash -c 'echo ${BASH_VERSINFO[0]}')" -ge 4 ] || { forge_install_line mac bash; bad=1; }
  fi
  return "$bad"
}

#!/bin/zsh
# Builds Crewshelf from source and installs it to ~/Applications/Crewshelf.app (or the folder given with --dir).
# The build compiles everything and runs the whole test suite first, printing each step. Safe to run again: it
# quits that installed copy if it is running and replaces it. Any other Crewshelf process (a --demo, a test
# instance, a copy somewhere else) is left alone. It never touches your Claude Code settings: the plugin is
# installed from inside Claude Code.
#
#   ./install.sh [--dir <folder>] [--no-tests] [--universal]
set -euo pipefail
cd "${0:A:h}"

dest="$HOME/Applications"
build_args=()
while (( $# )); do
  case $1 in
    --dir)
      (( $# >= 2 )) || { print -u2 "usage: ./install.sh [--dir <folder>] [--no-tests] [--universal]"; exit 2 }
      dest=${2:a}; shift 2 ;;
    *) build_args+=("$1"); shift ;;
  esac
done
app="$dest/Crewshelf.app"
exe="$app/Contents/MacOS/Crewshelf"

# Pids of processes running exactly this executable (any arguments), never another copy of Crewshelf.
pids_of() {
  ps -axo pid=,command= | awk -v exe="$1" '{ pid = $1; sub(/^ *[0-9]+ /, ""); if ($0 == exe || index($0, exe " ") == 1) print pid }'
}

./build.sh "${build_args[@]}"

mkdir -p "$dest"
pids=($(pids_of "$exe"))
if (( ${#pids} )); then
  print "== quitting the installed Crewshelf (pid ${pids[*]})"
  kill -TERM "${pids[@]}" 2>/dev/null || true       # it quits cleanly on SIGTERM, like the menu's Quit
  for _ in {1..25}; do (( ${#$(pids_of "$exe")} )) || break; sleep 0.2; done
fi
rm -rf "$app"
ditto build/Crewshelf.app "$app"
print "== installed $app"

others=($(pgrep -x Crewshelf || true))
if (( ${#others} )); then
  print "note: another Crewshelf is running (pid ${others[*]}): a --demo, a test instance or a copy elsewhere. It was"
  print "      left alone. If it is an older install, quit it, or the new copy will find it on the socket and quit."
fi

cat <<NEXT

Next:
  1. Open Crewshelf:  open "$app"
     (right-click the shelf > Launch at login to start it with your Mac)
  2. In Claude Code, add the plugin:
       /plugin marketplace add aaliismail/crewshelf
       /plugin install crewshelf@crewshelf
NEXT

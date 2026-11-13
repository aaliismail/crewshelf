#!/bin/zsh
# Removes Crewshelf: quits it, turns off its login item, deletes the app and its support folder and settings.
# Looks in ~/Applications and /Applications, plus the folder given with --dir. Only processes running one of those
# copies are quit; a --demo or a test instance is left alone. The Claude Code plugin is removed from inside Claude
# Code (the commands are printed at the end).
#
#   ./uninstall.sh [--dir <folder>]
set -uo pipefail

support="$HOME/Library/Application Support/Crewshelf"
bundle=io.github.aaliismail.crewshelf
dirs=("$HOME/Applications" /Applications)
if [[ ${1:-} == --dir ]]; then
  [[ -n ${2:-} ]] || { print -u2 "usage: ./uninstall.sh [--dir <folder>]"; exit 2 }
  dirs=("${2:a}" "${dirs[@]}")
fi

pids_of() {
  ps -axo pid=,command= | awk -v exe="$1" '{ pid = $1; sub(/^ *[0-9]+ /, ""); if ($0 == exe || index($0, exe " ") == 1) print pid }'
}

for d in "${dirs[@]}"; do
  app="$d/Crewshelf.app"
  [[ -d $app ]] || continue
  exe="$app/Contents/MacOS/Crewshelf"
  pids=($(pids_of "$exe"))
  if (( ${#pids} )); then
    kill -TERM "${pids[@]}" 2>/dev/null       # it quits cleanly on SIGTERM, like the menu's Quit
    for _ in {1..25}; do (( ${#$(pids_of "$exe")} )) || break; sleep 0.2; done
  fi
  # The login item is an SMAppService registration of the app itself: only that copy can unregister it.
  "$exe" --remove-login-item 2>/dev/null | sed 's/^/  /'
  rm -rf "$app" && print "removed $app"
done
if [[ -d $support ]]; then
  rm -rf "$support" && print "removed $support"
fi
defaults delete "$bundle" >/dev/null 2>&1 && print "removed settings ($bundle)"

others=($(pgrep -x Crewshelf))
(( ${#others} )) && print "note: a Crewshelf not installed in those folders is still running (pid ${others[*]}); quit it yourself."

cat <<'NEXT'

To remove the plugin, in Claude Code:
  /plugin uninstall crewshelf@crewshelf
  /plugin marketplace remove crewshelf
NEXT

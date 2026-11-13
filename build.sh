#!/bin/zsh
# Builds and tests Crewshelf with swiftc only (no Xcode project, no SwiftPM, no network).
# Output: build/Crewshelf.app (LSUIElement agent app, with the plugin's hook client crewshelf-hook inside) and
# build/crewshelf-tests.
#
#   ./build.sh               tests, then the app for this Mac's architecture
#   ./build.sh --universal   the app for arm64 and x86_64 (lipo); tests run natively
#   ./build.sh --zip         also writes build/Crewshelf-<version>.zip (ditto, for a release)
#   ./build.sh --no-tests    skip the tests
set -euo pipefail
cd "${0:A:h}"

VERSION=1.0.0
universal=0 zip=0 tests=1
for a in "$@"; do
  case $a in
    --universal) universal=1 ;;
    --zip) zip=1 ;;
    --no-tests) tests=0 ;;
    *) print -u2 "usage: ./build.sh [--universal] [--zip] [--no-tests]"; exit 2 ;;
  esac
done

host=$(uname -m)
[[ $host == arm64 ]] || host=x86_64
archs=($host)
(( universal )) && archs=(arm64 x86_64)

common=(-O -swift-version 5 -module-cache-path build/.module-cache)
CORE=(Sources/Core/*.swift)
HOOK=(Sources/Core/HookProtocol.swift Sources/Core/HookSocket.swift Sources/Core/HookClient.swift Sources/Core/ProcInfo.swift
      Sources/Core/TerminalEnv.swift Sources/Hook/main.swift)
APP=build/Crewshelf.app

# swiftc for one architecture: compile <arch> <output> <sources...>
compile() {
  local arch=$1 out=$2; shift 2
  swiftc "${common[@]}" -target "$arch-apple-macos13.0" "$@" -o "$out"
}

# One binary per architecture, then lipo when there are two: build_bin <name> <sources...>
build_bin() {
  local name=$1; shift
  local parts=()
  for arch in $archs; do
    compile $arch "build/$name-$arch" "$@"
    parts+=("build/$name-$arch")
  done
  if (( ${#parts} > 1 )); then lipo -create "${parts[@]}" -output "build/$name"; else cp "${parts[1]}" "build/$name"; fi
}

mkdir -p build
print "== hook client (${archs[*]})"
build_bin crewshelf-hook "${HOOK[@]}"

if (( tests )); then
  print "== tests"
  # The hook tests exec build/crewshelf-hook, so it must run on this Mac (a universal one does).
  compile $host build/crewshelf-tests "${CORE[@]}" Tests/*.swift
  build/crewshelf-tests Tests/Fixtures
fi

print "== app (${archs[*]})"
build_bin Crewshelf "${CORE[@]}" Sources/App/*.swift
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mv build/Crewshelf "$APP/Contents/MacOS/Crewshelf"
cp build/crewshelf-hook "$APP/Contents/MacOS/crewshelf-hook"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>io.github.aaliismail.crewshelf</string>
  <key>CFBundleName</key><string>Crewshelf</string>
  <key>CFBundleDisplayName</key><string>Crewshelf</string>
  <key>CFBundleExecutable</key><string>Crewshelf</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Copyright 2026 Ali Ismail. MIT License.</string>
  <key>NSAppleEventsUsageDescription</key><string>Open brings an agent's tab to the front in iTerm2, Terminal or Ghostty.</string>
</dict>
</plist>
PLIST
# Ad-hoc signatures (no Apple Developer ID): the hook client first, then the bundle around it.
codesign --force --sign - "$APP/Contents/MacOS/crewshelf-hook" >/dev/null 2>&1 || true
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
print "built $APP ($(lipo -archs "$APP/Contents/MacOS/Crewshelf" 2>/dev/null))"

if (( zip )); then
  out=build/Crewshelf-$VERSION.zip
  rm -f "$out"
  ditto -c -k --norsrc --noextattr --keepParent "$APP" "$out"
  print "zipped $out"
fi

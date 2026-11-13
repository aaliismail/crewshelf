# Contributing

Issues and pull requests are welcome. For a security problem, see [SECURITY.md](SECURITY.md) instead.

## Two rules that are not up for debate

1. **Never auto-approve.** No code path may allow a tool call without an explicit click (Approve, or Send for a
   question). Every failure (timeout, error, crash, unknown reply, closed socket) must mean "no output". Changes to
   `Sources/Core/HookProtocol.swift`, `HookCenter.swift`, `HookServer.swift` or `HookClient.swift` need tests for
   the failure paths, not just the happy path.
2. **No network.** No HTTP, no telemetry, no update checks, no new dependencies that phone home.

## Build and test

Requirements: macOS 13 or later and the Xcode Command Line Tools (`xcode-select --install`). There is no Xcode
project and no package manager; `build.sh` calls `swiftc` directly and downloads nothing.

```sh
./build.sh                    # runs the tests, then builds build/Crewshelf.app for this Mac
./build.sh --universal --zip  # arm64 + x86_64, and build/Crewshelf-<version>.zip (what a release ships)
```

Some tests need things a sandboxed shell or a CI runner may not have (binding a Unix socket in `$TMPDIR`, tmux,
iTerm2, `defaults` across processes). They print a `SKIP` line with the reason instead of failing. Run
`./build.sh` in a normal Terminal for the full suite before sending a change to the hook path.

### A test instance

Never test against your real setup. A separate instance has its own socket, settings and no roster:

```sh
cp -R build/Crewshelf.app "$TMPDIR/Crewshelf.app"
export CREWSHELF_SUPPORT_DIR="$TMPDIR/cs-test"        # socket and files (keep the path short: sockets max 104 bytes)
CREWSHELF_DEFAULTS=io.github.aaliismail.crewshelf.test CREWSHELF_NO_ROSTER=1 CREWSHELF_TEST_CONTROL=1 \
  "$TMPDIR/Crewshelf.app/Contents/MacOS/Crewshelf" &
claude -p --plugin-dir ./plugin --model haiku "run: echo hello"     # this session reports to the test instance
"$TMPDIR/Crewshelf.app/Contents/MacOS/Crewshelf" --ctl list
```

| Variable | Effect |
| --- | --- |
| `CREWSHELF_SUPPORT_DIR` | where the socket, `app-path` and `dismissed.json` live (the plugin's shim reads it too) |
| `CREWSHELF_DEFAULTS` | the settings suite |
| `CREWSHELF_NO_ROSTER=1` | do not show sessions from `claude agents --json` |
| `CREWSHELF_TEST_CONTROL=1` | allow `--ctl decide`, `answer`, `tap`, `open`, clicks, drags, menu picks, snapshots |
| `CREWSHELF_QUIET=1` | count sounds and banners (`--ctl layout`) instead of playing or showing them |
| `CREWSHELF_FORCE_ON_SCREEN=1` | keep animating with the screen locked (CPU measurements) |
| `CREWSHELF_FORCE_SOCKET_TESTS=1` | make the socket tests fail instead of skipping |

`Crewshelf --ctl` with no arguments prints every command, and `Crewshelf --help` every option. `Crewshelf --demo`
runs five made-up agents in its own folder and settings; talk to it with `Crewshelf --demo --ctl ...`. Never put a
screenshot of a real session in the repo.

### The README images

`docs/img/` is made from a demo started with test control on (`snapshot` and `record` need it), at 2x:

```sh
export CREWSHELF_SUPPORT_DIR=/tmp/cs-demo CREWSHELF_DEFAULTS=io.github.aaliismail.crewshelf.imgs CREWSHELF_TEST_CONTROL=1
C=build/Crewshelf.app/Contents/MacOS/Crewshelf
$C --demo &
$C --demo --ctl record docs/img/demo.gif 18 8 2         # from the start: 18 s at 8 fps
# for each still: wait for the state (--ctl layout), freeze the demo, then capture both windows over a backdrop
$C --demo --ctl demo freeze
$C --demo --ctl snapshot docs/img/permission.png both 2
$C --demo --ctl demo run
```

`permission.png` is rate-limit's Bash request, `question.png` billing-ui's question, `shelf.png` the shelf with
"Bubbles open on their own" off (so the `!` shows), `collapsed.png` the same after "Collapse shelf" (`--ctl menu ""
"Collapse shelf"`). Quit the demo and `defaults delete` its suite afterwards.

## Code layout

| Path | What |
| --- | --- |
| `Sources/Core/` | Everything testable, no UI: the hook wire format (`HookProtocol`), socket (`HookSocket`, `HookServer`), hook client (`HookClient`), the decision center (`HookCenter`), the roster (`Roster`, `Engine`, `HookMerge`), bubble queue (`Bubbles`), alert rules (`Calm`), shelf geometry (`Placement`), terminal adapters (`Terminals`, `Open`, `Cmux`, `TerminalEnv`, `ProcInfo`), the sprite (`Sprite`), demo agents (`Demo`) |
| `Sources/App/` | The AppKit + SwiftUI app: windows and test control (`main`), state (`Model`), views (`Views`), right-click menu (`Menu`), sound and banners (`Notifier`), login item, GIF capture |
| `Sources/Hook/` | `crewshelf-hook`, the plugin's hook client (bundled inside the app) |
| `Tests/` | A plain test runner (`Tests/main.swift`) with `check` and `eq`; fixtures in `Tests/Fixtures/` are synthetic |
| `plugin/` | The Claude Code plugin: `hooks/hooks.json` and `bin/crewshelf-shim` |
| `.claude-plugin/marketplace.json` | The marketplace, so `/plugin marketplace add aaliismail/crewshelf` works |

## Style

- Swift 5 language mode, no third-party packages.
- Keep `Sources/Core` free of AppKit and SwiftUI so it stays testable.
- The pixel characters (their pixels, colors and animation) are part of the design; change them only on purpose.
- Fixtures and examples use made-up paths (`/Users/demo/...`) and ids. A test (`privacyTests`) fails on a real home
  path in the tree.
- Run `claude plugin validate .` and `claude plugin validate plugin` after touching the manifests.

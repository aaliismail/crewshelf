# Pre-release review (1.0.0)

Four independent reviews ran against the tree before its first push: security, design, hygiene, and a stranger
following the README from a clean clone. This page lists every finding, its severity and what happened to it.

Status: **fixed** (changed, with tests where it is code), **not real** (checked, and why), **open** (left for a
decision or for a step that can only happen later).

Test totals after the fixes: 933 passed, 0 failed in a normal shell; 779 passed, 0 failed in a sandboxed shell
(socket, `defaults`, tmux and owner-walk tests print SKIP there). `Tests/ReviewTests.swift` holds the new tests.

## Security

| # | Severity | Finding | Status |
| --- | --- | --- | --- |
| 1 | Medium | A long file path was cut to 3 lines in the bubble but could still be approved, so its end was never seen. | **Fixed.** The subtitle has no line limit. A file path or URL longer than 6 wrapped rows (newlines included) is cut in `permissionPreview` and the request can't be approved ("Path too long to show in full: Approve is off"); a long Bash description is cut but stays approvable, since the command itself is shown whole. |
| 2 | Low | Home shortening used `hasPrefix(home)`, so with home `/home/al` the folder `/home/alice` showed as `~ice`. | **Fixed.** `~` only for home itself or a path under `home + "/"`. |
| 3 | Low | A NUL in agent text (a banner summary) reached `Process.run`, whose exception kills the app. | **Fixed.** `run()` refuses any argument with a NUL, and banner text loses its control characters (`bannerSafe`) before it reaches `osascript` or UserNotifications. |
| 4 | Low | The shim ran whatever `crewshelf-hook` `app-path` pointed at, and the hook never checked the server's uid. | **Fixed.** The shim runs the hook only when `app-path` and the bundle, from its top folder down to the binary, are owned by you or root and not group- or world-writable. The hook client checks the server's uid with `getpeereid`. `CREWSHELF_SUPPORT_DIR` stays (the tests need it); the same checks apply to it. |
| 5 | Low | No cap on connections: one thread per connection, up to 16 MB per request line. | **Fixed.** At most 64 connections are served at once; more are closed unread and counted as refused. Same-user only, as before. |
| 6 | Low | `cmux new-surface --command "<claude> attach <id>"` was built without quoting. | **Fixed.** Both words go through `shellQuote`. |
| 7 | Low | CI: `actions/checkout@v4` pinned to a tag, and the token stayed in `.git/config` during the build. | **Fixed.** Pinned to the v6.1.0 commit (`d23441a4…`) with `persist-credentials: false` in both workflows. |

Checked and fine by the reviewer (no change): socket modes and peer check, parsing limits, request ids, hook output,
test-control gating, button arming, AppleScript escaping, argv passing, install scripts, workflow inputs, no secrets.

## Design

| # | Severity | Finding | Status |
| --- | --- | --- | --- |
| 1 | High | Approve looked no more important than Open. | **Fixed.** Approve (and Send) is a solid orange button with dark text when armed; Deny is outlined; in a prompt bubble Open is dim. |
| 2 | High | The done bubble cut its only content to one line, had no Open, and said "done" twice. | **Fixed.** Up to 3 lines, Open and Hide below it, no "Done" label in the body. |
| 3 | Medium | Orange everywhere on a calm shelf (pill outlines, check marks). | **Fixed.** Pill outlines are `Palette.line`, the check is green. The working dots keep their colors and motion. |
| 4 | Medium | A warning chip looked like a question's header chip. | **Fixed.** Only "Runs OUTSIDE the sandbox" is a solid orange chip; other warnings are outlined; the question header is a neutral outlined tag. (No demo request carries a warning, so this was checked in code.) |
| 5 | Medium | Consequences in the faintest text (2.57:1). | **Fixed.** "No terminal: if you don't answer here, it is denied." and "· no plugin" are `Palette.dim` (about 7:1). |
| 6 | Medium | One install command wrapped and looked like two. | **Fixed.** A `›` marker per command with a hanging indent. |
| 7 | Medium | Two timers counting opposite ways, and "blocked" in the header. | **Fixed.** The header says "waiting 21s" and turns into "Ns left" in the same spot in the last minute; the separate countdown is gone. The hover tooltip says "waiting" too. |
| 8 | Low | A wrapped diff line lost its `+`/`-` marker. | **Fixed.** A fixed marker column beside the text. |
| 9 | Low | Failed steps were dimmer than successful ones. | **Fixed.** An orange `×` before the step, its text in `Palette.dim`. |
| 10 | Low | Six type sizes in one bubble. | **Partly fixed.** 9 pt is gone (now 9.5). 10 pt stays for code and step rows, because the preview's height estimate is tuned to it; the system font stays for prose. |
| 11 | Low | The install hint could not be reopened. | **Fixed.** "Install the plugin…" in the right-click menu until the plugin first reports in. |

## Hygiene

| # | Severity | Finding | Status |
| --- | --- | --- | --- |
| 1 | High | The characters closely follow Anthropic's Claude Code mascot (body plan, and the first palette color is `#D97757`), while the README called them "original pixel art". The plugin icon is that character alone. | **Fixed in part.** The "Unofficial" notice (top and end of the README, and `plugin/README.md`) now says the characters are fan-made pixel art inspired by Claude Code's mascot, not Anthropic artwork, and not reviewed or approved by Anthropic; the inaccurate "original pixel art" sentence was removed. The plugin icon is now the crew: three characters side by side on the shelf in teal, plum and sage, rendered from `Sources/Core/Sprite.swift`, none in the clay color. **Kept, the maintainer's choice:** the sprite shape, the animations and the first palette color (`#D97757`) stay as they are. |
| 2 | Low | Undocumented debug switches in the release build: `--select`, `--notify-test`, `--jump`, `--done`, `CREWSHELF_DEBUG`. | **Fixed.** `--select` and `CREWSHELF_DEBUG` are removed. `--notify-test`, `--jump` and `--done` are listed by the new `Crewshelf --help` (`--done` is a command you type yourself, like End). |
| 3 | Low | Nothing on screen says test control is on. | **Fixed.** A non-demo instance with `CREWSHELF_TEST_CONTROL=1` shows a `test` tag on its shelf. |
| 4 | Low | `.gitignore` listed `evidence/` and `screenshot-*.png`. | **Fixed.** Removed. |
| 5 | Low | "Apple M2" in the README unverified. | **Not real.** `sysctl -n machdep.cpu.brand_string` says Apple M2. |
| 6 | Low | `actions/checkout@v4` not pinned to a SHA. | **Fixed** (security 7). |
| 7 | Pass | Privacy: nothing identifying. | No action. Re-checked after the fixes: `git grep` and `strings` on the binaries are still clean, and the regenerated images show only demo agents. |
| 8 | Pass | Licensing. | No action. |
| 9 | Pass | Leftovers. | No action. |

## Stranger

| # | Severity | Finding | Status |
| --- | --- | --- | --- |
| 1 | Medium | README said "`--dump` prints what the shelf sees", but it reads `~/.claude` itself and printed real sessions while a demo ran. | **Fixed.** README and `--help` say what it reads and to check it before sharing; its first output line says the same. It still reads `~/.claude` by design. |
| 2 | Low | `--help` or any unknown option started a full instance. | **Fixed.** `--help`/`-h` prints usage; an unknown `--option` prints usage and exits 2 before anything starts. AppKit's own `-NS…` arguments are left alone. |
| 3 | Low | No documented way to talk to the demo. | **Fixed.** `Crewshelf --demo --ctl <cmd>` talks to the running demo (and never resets its settings); documented in README and CONTRIBUTING. |
| 4 | Low | Quitting the demo with SIGTERM left its socket. | **Fixed.** SIGTERM and SIGINT quit like the menu's Quit; a demo removes its socket, its file and its folder. Checked live. |
| 5 | Low | README never said bubbles only appear for prompts Claude Code would show. | **Fixed.** In "Use it" and Troubleshooting (auto mode, `bypassPermissions`, `acceptEdits`, allow rules). |
| 6 | Low | `install.sh` had no install-folder option and killed every `Crewshelf` process. | **Fixed.** `--dir <folder>`; it quits only processes running the installed copy (by executable path, with SIGTERM) and says when another Crewshelf is left running. `uninstall.sh` does the same and takes `--dir`. Checked against a fake `HOME` with a demo running alongside. |
| 7 | Low | README didn't say `install.sh` compiles and runs the whole suite. | **Fixed.** Said, plus `--no-tests`. |
| 8 | Low | "About 10 ms" when the app isn't running didn't match measurements. | **Fixed.** Now "well under 100 ms (the tests fail above that)". |
| 9 | Low | `/plugin marketplace add aaliismail/crewshelf`, the clone URL and the Releases link can't be checked before the repo exists. | **Fixed in part.** A fresh `git clone` from GitHub built and passed 933 tests, and the v1.0.0 Releases page has the zip and `SHA256SUMS.txt`. **Open:** `/plugin marketplace add` and `/plugin install` have not been run against the public repo. |
| 10 | Low | CI only checked the manifests with `json.tool`, never ran, and uses `macos-15` (Swift 6.0/6.1) while the build used Swift 6.2.3. | **Fixed.** CI now also runs `claude plugin validate` on the plugin and the marketplace (via `npx @anthropic-ai/claude-code@stable`; it needs no login). It ran green on the first push: `macos-15`, Swift 6.1.2, 925 passed, 0 failed, with 4 SKIP lines (Ghostty, iTerm2, tmux and the owner walk), so the Swift version gap caused no failure. |
| 11 | Info | `open`, the Gatekeeper steps and `uninstall.sh` against the real home were not run. "Apple M2" confirmed. | **Fixed in part.** The v1.0.0 zip downloaded from the release passed `codesign` verification and ran `--demo`; `install.sh` worked against a scratch `HOME`, and `uninstall.sh` was run against a fake `HOME`. **Open, for the maintainer:** the Gatekeeper "Open Anyway" steps are untested with a quarantined download. |

## Builder's known gaps

| # | Gap | Status |
| --- | --- | --- |
| 1 | CI had never run (`macos-15`, older Swift). | Closed: green on the first push, and the v1.0.0 release workflow ran green and attached the zip and the checksum file (stranger 10). |
| 2 | Terminal.app, Ghostty and iTerm2 Open adapters are unit-tested only. | Open: driving them live needs Automation prompts on the maintainer's screen. The README table says exactly this. |
| 3 | Gatekeeper steps for a downloaded zip untested. | Open: the downloaded zip verifies and runs, but "Open Anyway" on a quarantined copy is untested (stranger 11). |
| 4 | Tests leave `io.github.aaliismail.crewshelf.tests.*.plist` until the next run removes them. | Open, unchanged (cfprefsd writes them after the process exits). |
| 5 | "Apple M2" in the README. | Confirmed (hygiene 5). |

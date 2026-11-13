# Changelog

## 1.0.0 (2026-11-13)

First public release.

- A shelf of pixel characters, one per running Claude Code session: terminal tabs, `claude --bg` agents and
  headless `claude -p` runs. Working, waiting, done and idle each look different.
- Approve or deny permission requests, and answer `AskUserQuestion` prompts, from a speech bubble, through the
  `crewshelf` Claude Code plugin's hooks. Works for background agents with no terminal.
- Fail-safe by design: a timeout, an error, a crash or a quit app never approves anything. With the app not running
  the hooks exit at once with no output.
- One bubble at a time, a collapsible and movable shelf that remembers its place per display, calm alerts (one soft
  sound, optional banners, Do Not Disturb, per-agent mute, macOS Focus respected).
- Open an agent's terminal tab in cmux, iTerm2, Terminal.app, Ghostty or tmux, with a fallback that brings the
  owning app to the front.
- Launch at login, hide idle agents, corner placement, a demo mode with made-up agents.
- Moving characters are drawn by Core Animation: about 1% CPU with five agents animating.
- `install.sh`, `uninstall.sh`, a universal (arm64 + x86_64) release zip.

# Security

Crewshelf can approve tool calls for Claude Code, so its whole design starts from one rule: **nothing is approved
without an explicit click by you.** This page says what it protects, how, and what it does not try to protect.

## Reporting a vulnerability

Please report privately through GitHub: **Security > Report a vulnerability** on
[aaliismail/crewshelf](https://github.com/aaliismail/crewshelf/security/advisories/new) (a private security
advisory). Do not open a public issue for a security problem. Include the version, macOS version, and the steps that
show it. You will get an answer as soon as the report has been read, and credit in the advisory if you want it.

## Threat model

**What Crewshelf protects:**

- **No approval without a decision.** A permission is allowed only when you click Approve (or Send, for a question)
  in a bubble. A timeout, an error, a crash, a garbled or unknown reply, a closed socket, or the app not running
  always means *no output* from the hook, which Claude Code treats as "no decision": the terminal prompt appears, or
  a background session denies the call. The JSON the hook prints is pinned by golden tests.
- **No misclicks.** A request's buttons arm 0.6 s after it comes on screen, so a click aimed at one request cannot
  land on another that just took its place. Input too long to show in full cannot be approved from the bubble, and
  neither can a file path or URL too long to show in full (the part you can't see could point anywhere).
- **No late approvals.** The app stops accepting decisions 2 s before the hook gives up, so an accepted decision
  always reaches the hook in time; a later click says "Too late" and approves nothing.

**The socket.** The plugin's hook client talks to the app over a Unix-domain socket at
`~/Library/Application Support/Crewshelf/crewshelf.sock`:

- the socket file is mode `0600`, inside a directory set to `0700`;
- every accepted connection's peer is checked with `getpeereid`, and closed unread unless its uid is yours;
- the hook client checks the other way too: it only talks to a server whose uid is yours;
- at most 64 connections are served at once; more are closed unread (that hook prints nothing);
- there is no TCP listener and no network code at all.

**The hook client.** The plugin's shim reads the app's path from `app-path` in the support folder and runs the
`crewshelf-hook` inside that bundle, but only when the `app-path` file and the bundle, from its top folder down to
the binary, are owned by you (or root) and not writable by group or others. So a copy of Crewshelf kept in a shared
folder can't have its hook client swapped by another user. `CREWSHELF_SUPPORT_DIR` moves the support folder (the
tests use it); the same ownership checks apply there.

**Test control is off by default.** `Crewshelf --ctl` talks to the same socket. Without
`CREWSHELF_TEST_CONTROL=1` in the app's own environment it can only read (`list`, `layout`, `plan`, `menu` without a
pick): `decide`, `answer`, `tap`, `open`, synthetic clicks and drags, menu picks, `notice`, `screen`, `snapshot`
and `record` are all refused. Otherwise any process running as you could approve requests through the socket. An
instance started with test control on shows a `test` tag on its shelf, so it can't go unnoticed.

**What it does not protect against:** a process that already runs as your user. Such a process can read your files,
start the app with test control on, or talk to Claude Code directly; a local socket cannot defend against it, and
neither can Claude Code's own terminal prompt. Crewshelf does not make that boundary weaker: the socket accepts only
your uid, and test control has to be set in the environment of the app itself.

## What Crewshelf never does

- No network access, no telemetry, no analytics, no update checks.
- Never auto-approves, never offers "always allow", never types into a terminal.
- Never runs `claude rm` or deletes anything of Claude Code's. **End** runs `claude stop <id>` for a background
  agent after a second click.
- Never edits your Claude Code settings. The plugin is installed and removed from inside Claude Code.

## What it reads

- Hook events the plugin sends (the hook's JSON input, plus an allowlist of terminal variables: `TERM_PROGRAM`,
  `TERM_SESSION_ID`, `ITERM_SESSION_ID`, `LC_TERMINAL`, `TMUX`, `TMUX_PANE`, `CMUX_WORKSPACE_ID`, `CMUX_SURFACE_ID`,
  `__CFBundleIdentifier`, and the tty and pid of the claude process).
- `claude agents --json`, `~/.claude/sessions/*.json`, `~/.claude/jobs/*/state.json` and the tail of a session's
  transcript, for sessions without the plugin and to notice a prompt answered in the terminal.
- `cmux tree --all --json` when cmux is the frontmost app (to skip alerts for the tab you are looking at), and the
  macOS Focus state files in `~/Library/DoNotDisturb/DB`.

Everything stays in memory, except your settings (`defaults read io.github.aaliismail.crewshelf`) and the list of
dismissed bubbles in the support folder.

## Builds

Release zips are built by GitHub Actions from the tagged commit (`.github/workflows/release.yml`) and are ad-hoc
signed, not notarized: there is no Apple Developer ID behind them. If you would rather not trust a binary, build from
source with `./install.sh`; it uses only `swiftc` from the Xcode Command Line Tools and downloads nothing.

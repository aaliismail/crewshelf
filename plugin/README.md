# crewshelf (Claude Code plugin)

The Claude Code half of [Crewshelf](https://github.com/aaliismail/crewshelf), a macOS desktop shelf of pixel
characters, one for every running Claude Code session. With this plugin installed, permission requests and
`AskUserQuestion` prompts open as a speech bubble on the shelf, and you answer them there: Approve, Deny, or pick an
answer.

The hooks run `bin/crewshelf-shim`, which hands each hook event to the Crewshelf app over a local Unix socket. When
the app is not running, every hook exits 0 with no output in a few milliseconds, so Claude Code behaves exactly as if
the plugin were not installed. Nothing is ever approved without your click, and nothing leaves your Mac.

Install the app first (see the main README), then in Claude Code:

```
/plugin marketplace add aaliismail/crewshelf
/plugin install crewshelf@crewshelf
```

Unofficial. Not affiliated with or endorsed by Anthropic. The characters are fan-made pixel art inspired by Claude
Code's mascot, not Anthropic artwork, and Anthropic has not reviewed or approved them.

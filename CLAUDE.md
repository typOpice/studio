See [AGENTS.md](AGENTS.md) for the engineering contract: build and test commands,
architecture invariants, recipes for common changes, and known limitations.

Quick version: `swift run StudioApp --selftest` runs 1855 headless checks and must
pass before any change is considered done. There is no Xcode on this machine, so
Metal shaders compile at runtime, and Luau, Wren and Jolt Physics are vendored as
source (Sources/CLuau, CWren, CJolt) — don't "fix" any of it.

Scripting policy: **Luau is primary** and gets every new feature first; **Wren**
catches up on alternate major releases. Don't let Wren work block a Luau change.

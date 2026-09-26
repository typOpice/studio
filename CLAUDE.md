See [AGENTS.md](AGENTS.md) for the engineering contract: build and test commands,
architecture invariants, recipes for common changes, and known limitations.

Quick version: `swift run StudioApp --selftest` runs 2506 headless checks and must
pass before any change is considered done. Xcode 27 is installed and selected (Swift
6.4), but the project doesn't depend on it: it stays a plain Swift package that
Command Line Tools alone can build — Metal shaders compile at runtime, and Luau, Wren
and Jolt Physics are vendored as source (Sources/CLuau, CWren, CJolt). Don't turn it
into an Xcode project or "fix" any of that.

Scripting policy: **Luau is primary** and gets every new feature first; **Wren**
catches up on alternate major releases. Don't let Wren work block a Luau change.

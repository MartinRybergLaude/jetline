# Jetforge

A SwiftUI macOS app that wraps `claude` / `codex` CLIs in an embedded terminal,
with workspace = git worktree management on top.

This is a pared-down, native rewrite of [Jetforge](https://github.com/dohooo/jetforge).
The custom chat UI / streaming pipeline / sidecar is gone — the agent runs in
its own terminal and the changes panel is computed from `git diff` instead of
parsing agent events.

## Status

- Repo + worktree management ✅
- SQLite persistence (workspaces, sessions, settings) ✅
- Sidebar with repos & workspaces, new-workspace sheet ✅
- Embedded terminal hosting `claude` / `codex` ✅ (SwiftTerm-backed)
- Changes panel from `git diff` against base branch ✅
- FSEvents watcher → live diff refresh ✅
- Settings (default agent, binary paths, terminal font) ✅
- libghostty as the terminal backend ⏳ stubbed; see migration plan below
- File editor, Conductor import, GitHub auth ❌ explicitly out of scope

## Build

Requires:
- macOS 14+
- Xcode command-line tools
- Swift 5.10+ (5.10 / 6.x both work)

```bash
make app    # debug build, produces dist/Jetforge.app
make run    # build + open
make release ; # release config
make test
```

`swift build` directly works too, but produces a plain executable rather than
an `.app` bundle.

### Note on dependency resolution

If your global git config has `url.<...>.insteadOf` rewrites pointing
`https://` → `ssh://` (common for users who clone via SSH by default), SPM's
version resolver silently fails because it can't authenticate against
github/gitlab via SSH from a subprocess. The `Makefile` works around this by
running SwiftPM with `GIT_CONFIG_GLOBAL=/dev/null`. If you invoke `swift`
directly, prepend the same env var.

## Architecture

```
Sources/JetforgeApp/
├── JetforgeApp.swift           ─ @main / WindowGroup / SettingsScene
├── AppState.swift            ─ ObservableObject root state
├── Models/
│   ├── Repository.swift
│   ├── Workspace.swift
│   ├── Session.swift
│   └── AppSettings.swift
├── Database/
│   ├── Database.swift        ─ GRDB DatabasePool, data dir resolution
│   ├── Schema.swift          ─ migrations
│   └── Repositories.swift    ─ typed read/write helpers
├── Git/
│   ├── GitRunner.swift       ─ async Process wrapper around system `git`
│   ├── Worktree.swift        ─ branch + worktree create/remove
│   ├── Diff.swift            ─ DiffSnapshot + unified-diff parser
│   └── Watcher.swift         ─ FSEvents → coalesced refresh
├── Terminal/
│   ├── TerminalEmulator.swift─ backend protocol + selector
│   ├── SwiftTermEmulator.swift  ─ default impl (working)
│   ├── GhosttyEmulator.swift    ─ stub + migration plan
│   ├── AgentLauncher.swift   ─ resolve `claude`/`codex` binary paths
│   └── PTYSession.swift      ─ owns one terminal view + child process
└── Views/
    ├── Shell/AppShell.swift  ─ NavigationSplitView layout
    ├── Sidebar/              ─ repos + workspaces + new-workspace sheet
    ├── Terminal/TerminalArea ─ host an emulator + session tabs
    ├── Inspector/            ─ Changes panel (git diff)
    ├── Settings/             ─ TabView'd preferences
    └── Welcome/              ─ empty state
```

### Data flow

```
sidebar → AppState.selectWorkspace → ensure PTYSession → spawn `claude`/`codex`
                                  ↘ start FSEventsWatcher → throttle → DiffComputer
                                                                     → refresh inspector
```

Workspaces live in `~/.jetforge/worktrees/<repoId>/<workspaceId>`. The
SQLite db lives at `~/.jetforge/jetforge.sqlite`. Override the data dir
with the `JETFORGE_DATA_DIR` env var.

## Swapping SwiftTerm for libghostty

This is documented in detail in
`Sources/JetforgeApp/Terminal/GhosttyEmulator.swift` (header comment).

Short version:

1. `git submodule add https://github.com/ghostty-org/ghostty Vendor/ghostty`,
   pinned to a known good commit. Requires Zig 0.13+.
2. Add a `Makefile` target that runs `zig build -Doptimize=ReleaseFast` in
   the submodule and copies `GhosttyKit.xcframework` to
   `Frameworks/GhosttyKit.xcframework`.
3. In `Package.swift`, add a `.binaryTarget` for the xcframework and depend
   on it from `JetforgeApp`.
4. Port the relevant pieces of Ghostty's own
   `macos/Sources/Ghostty/{Ghostty.App, SurfaceView_AppKit}.swift` into
   `GhosttyEmulator.swift` — enough to make a `ghostty_app_t` once and a
   `ghostty_surface_t` per terminal view.
5. Pass `command = claude` / `codex` and `working-directory = <worktree path>`
   in the surface config so Ghostty spawns the agent inside its own PTY.
6. Flip `TerminalBackend.default` to `.ghostty`. Drop SwiftTerm from the
   package once parity is verified.

The `TerminalEmulatorView` protocol is the entire surface area you need to
re-implement, so the swap is contained.

## License

MIT (placeholder; replace before publishing).

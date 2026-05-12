# Jetline

A SwiftUI macOS app that wraps `claude` / `codex` / `vibe` CLIs in an
embedded terminal, with workspace = git worktree management on top, plus a
GitHub-aware inspector (live diff, PR + checks, branch position) and a git
action bar that fast-paths the common things and hands the rest to an agent.

## Status

- Repo + worktree management ✅
- Import an existing branch or PR as a workspace ✅
- SQLite persistence (workspaces, settings, PR snapshots) ✅
- Sidebar with repos & workspaces, drag-reorder, per-repo settings ✅
- Embedded terminal hosting `claude` / `codex` / `vibe` / shell ✅ (libghostty-backed)
- Multiple session tabs per workspace, ⌘1…⌘9 / ⌘⌥← →, drag-reorder ✅
- Inspector: changes (combined / PR / local), PR + checks, run output ✅
- FSEvents watcher → live diff refresh + PR poll kick ✅
- Git action bar: commit / create PR / pull / rebase / fix CI / fix comments / review / merge ✅
- Fast-path rebase + pull (no agent token spend on the no-conflict case) ✅
- Per-repo setup / run / archive scripts, exclusive run ✅
- Settings: agents, binary paths, prompt overrides (global + per-repo), theme, terminal font ✅
- File editor, Conductor import ❌ explicitly out of scope

## Build

Requires:
- macOS 14+
- Xcode command-line tools
- Swift 5.10+ (5.10 / 6.x both work)

```bash
make app    # debug build, produces dist/Jetline.app
make run    # build + open (kills any running copy first)
make release ; # release config
make test
```

`swift build` directly works too, but produces a plain executable rather than
an `.app` bundle (so no menu bar, dock icon, or Liquid Glass app icon).

### Note on dependency resolution

If your global git config has `url.<...>.insteadOf` rewrites pointing
`https://` → `ssh://` (common for users who clone via SSH by default), SPM's
version resolver silently fails because it can't authenticate against
github/gitlab via SSH from a subprocess. The `Makefile` works around this by
running SwiftPM with `GIT_CONFIG_GLOBAL=/dev/null`. If you invoke `swift`
directly, prepend the same env var.

## Architecture

```
Sources/JetlineApp/
├── JetlineApp.swift          ─ @main / WindowGroup / SettingsScene
├── AppState.swift            ─ ObservableObject root state
├── Models/
│   ├── Repository.swift          ─ repo + per-repo prompt/script overrides
│   ├── Workspace.swift           ─ worktree + agent kind
│   ├── WorkspaceState.swift      ─ per-workspace mutable state (not @Published)
│   ├── AppSettings.swift
│   ├── GitAction.swift           ─ commit/createPR/pull/rebase/fixCI/fixComments/review/mergePR
│   ├── GitActionPrompts.swift    ─ default templates + render
│   ├── GitActionState.swift      ─ in-flight action tracking
│   └── OpenInApp.swift           ─ Finder/Terminal/iTerm/VSCode/...
├── Database/
│   ├── Database.swift            ─ GRDB DatabasePool, data dir resolution
│   ├── Schema.swift              ─ migrations
│   ├── Repositories.swift        ─ typed read/write helpers
│   └── PRSnapshots.swift         ─ on-disk PR-snapshot cache
├── Git/
│   ├── GitRunner.swift           ─ async Process wrapper around system `git`
│   ├── Worktree.swift            ─ branch + worktree create/import/remove
│   ├── Diff.swift                ─ DiffSnapshot + unified-diff parser, modes
│   ├── Watcher.swift             ─ FSEvents → coalesced refresh
│   ├── BaseBranchSync.swift      ─ keeps repo.defaultBranch fresh
│   ├── BranchPosition.swift      ─ ahead/behind vs base + remote
│   ├── GitHub.swift              ─ `gh` wrapper: PR / checks / merge
│   └── PRTracker.swift           ─ poll loop, kicks, status
├── Terminal/
│   ├── TerminalEmulator.swift    ─ emulator protocol + factory
│   ├── GhosttyEmulator.swift     ─ libghostty-backed implementation
│   ├── PTYProcess.swift          ─ forkpty/execve, drain, exit reaping
│   ├── AgentLauncher.swift       ─ resolve `claude`/`codex`/`vibe` binary paths
│   ├── PTYSession.swift          ─ owns one terminal view + child process
│   └── TerminalIncubator.swift   ─ keeps detached views alive across reparents
├── Repository/
│   ├── ScriptRunner.swift        ─ shared launcher for setup/run/archive
│   ├── SetupController.swift     ─ first-run setup script + transcript
│   └── RunController.swift       ─ long-lived run script + restart
├── Utilities/
│   ├── RepoIconLoader.swift      ─ async repo icon BFS
│   └── Subprocess.swift
└── Views/
    ├── Shell/AppShell.swift      ─ NavigationSplitView layout, hotkeys
    ├── Sidebar/                  ─ repos, workspaces, new/import sheets, repo settings
    ├── Terminal/TerminalArea     ─ session tabs + git action menu
    ├── Inspector/                ─ Changes / PR / Run tabs
    ├── Settings/                 ─ TabView'd preferences (incl. action prompts)
    ├── Shared/                   ─ CapsuleTabs etc.
    └── Welcome/                  ─ empty state
```

### Data flow

```
sidebar → AppState.selectWorkspace → ensure PTYSession → spawn agent
                                  ↘ start FSEventsWatcher → throttle → DiffComputer
                                                                     → WorkspaceState
                                                                     → inspector views

PRTracker (timer + kicks) → gh pr view / gh pr checks → AppState.applyPR
                                                      → on-disk PRSnapshots cache

git action bar → GitActionPrompts.render → new PTYSession with initial prompt
              ↘ mergePR → gh pr merge (no agent)
              ↘ rebase / pull → fast-path git, fall back to agent on conflict
```

Workspaces live in `~/.jetline/worktrees/<repoId>/<workspaceId>`. The
SQLite db lives at `~/.jetline/jetline.sqlite`. PR snapshots are cached
alongside it. Override the data dir with the `JETLINE_DATA_DIR` env var.

Per-workspace mutable state (diff snapshots, PR snapshot, sessions, branch
position, run/setup controllers) lives on `WorkspaceState` instances looked
up via `AppState.workspaceState(for:)`, *not* in `@Published` dicts on
`AppState` — so a single workspace's poll/diff update only invalidates the
views that actually read it.

## License

EUPL v1.2

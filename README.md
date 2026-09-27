# Jetline

A SwiftUI macOS app that wraps `claude` / `codex` / `vibe` CLIs in an
embedded terminal, with workspace = git worktree management on top, plus a
GitHub-aware inspector (live diff, PR + checks, branch position) and a git
action bar that fast-paths the common things and hands the rest to an agent.

## Status

- Repo + worktree management ✅
- Import an existing branch or PR as a workspace ✅
- SQLite persistence (workspaces, settings, PR snapshots) ✅
- Sidebar with repos & workspaces, drag-reorder of repo sections and workspace rows (hold to lift, drag, release; within one repo), per-repo settings ✅
- Embedded terminal hosting `claude` / `codex` / `vibe` / shell ✅ (libghostty-backed)
- Multiple session tabs per workspace, ⌘N new workspace, ⌘1…⌘9 tabs, ⌘⇧←/→ (or ⌘⇧H/L) terminals, ⌘⇧↑/↓ (or ⌘⇧J/K) workspaces, native macOS window tabs (drag-reorder, tab overview) ✅ — the ⌘⇧ shortcuts yield to standard text selection while repo or app settings are being edited
- Close a workspace from its sidebar row (✕ on hover) or by closing its last tab — ends its sessions and drops it from ⌘⇧↑/↓ cycling ✅
- Inspector: changes (combined / PR / local) opening full-file diff tabs, PR + checks + conversation, run output ✅
- FSEvents watcher → live diff refresh + PR poll kick ✅
- Git action bar: commit / create PR / pull / rebase / fix CI / fix comments / review / merge ✅
- Fast-path rebase + pull (no agent token spend on the no-conflict case) ✅
- Per-repo branch naming controls, setup / run / archive scripts, exclusive run ✅
- Settings: agents, binary paths, prompt overrides (global + per-repo), theme, terminal font ✅
- Remote engine: run everything on a Linux box (`jetlined`) and drive it from the Mac over ssh ✅
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

## Running workspaces on another machine

Jetline is split into an **engine** — repositories, git worktrees, agent
processes, terminals, run scripts, PR tracking, the database — and the
**app**, which only renders the engine's state and sends it requests. By
default the engine runs inside the app. Point the app at `jetlined` on
another machine instead and everything runs *there*: the Mac is just a
window onto it. Close the laptop and the agents keep working; reconnect
and every terminal, chat and run picks up where it was (terminal output is
replayed from where the app last saw it).

### Set up a Linux host

The host needs `git`, and whatever you use there: `gh` (logged in), the
`claude` / `codex` CLIs (logged in), your toolchains. Then, from a Jetline
checkout on the Mac:

```bash
make deploy-daemon HOST=devbox        # anything ssh accepts: alias, user@host
```

That builds `jetlined` for the host's architecture in Docker (glibc ≥ 2.35:
Ubuntu 22.04+, Debian 12+; no other runtime dependencies) and installs it as
`~/.jetline/bin/jetlined` on the host. `make linux-daemon ARCH=x86_64|aarch64`
just builds `dist/jetlined-linux-<arch>` if you'd rather copy it yourself.
Building on the host works too: install Swift 6.2+ and `libsqlite3-dev`, then
`swift build -c release --product jetlined`.

### Connect

Settings → **Remote** → *A remote machine*, enter the ssh host (the same
thing you'd type after `ssh`), **Connect**. The app runs
`ssh -T <host> '~/.jetline/bin/jetlined attach'`, which starts the engine on
the host if it isn't running and bridges the connection to it; your ssh
config, keys, ProxyJump and so on apply. (A custom command works too — any
command whose stdin/stdout reach `jetlined attach`.) The sidebar shows the
link, and reconnects on its own when it drops.

Things that follow from the engine living elsewhere:

- *Add repository* browses the host's filesystem; worktrees live in the
  host's `~/.jetline/worktrees`.
- Chat images and files dropped on a terminal are uploaded to the host;
  images in a transcript are fetched from it.
- *Open in* offers editors that can open a folder over ssh (VS Code,
  Cursor, Zed) and opens the worktree on the host.
- Quitting the app no longer ends anything. `jetlined stop` on the host
  does (it stops every agent and terminal it's running).
- Dev servers run on the host. Reach them the way you would any service
  there — an ssh `LocalForward`/`DynamicForward` in your ssh config applies
  to Jetline's connection as well.

### On the host

```text
jetlined serve     run in the foreground (e.g. under systemd)
jetlined attach    what the app runs; starts the engine in the background if needed
jetlined status    running?
jetlined stop      stop it and everything it runs
jetlined rpc M J   send one request (see Protocol/API.swift) — scripting/debugging
```

Data lives in `~/.jetline` on the host (`JETLINE_DATA_DIR` overrides); the
engine logs to `~/.jetline/jetlined.log`. A Mac can be a host too:
`/Applications/Jetline.app/Contents/MacOS/jetline daemon attach`.

## Architecture

One library module, `JetlineApp`, and two thin executables: `jetline` (the
Mac app) and `jetlined` (the daemon). UI sources are fenced with
`#if os(macOS)`, so on Linux the module builds with only the engine inside.

```
Engine (in-process, or jetlined)            App (macOS)
────────────────────────────────            ─────────────────────────────
Engine          repos, workspaces, git      AppState      mirror + selection/tabs
EngineWorkspace diff / PR / runtime         WorkspaceState per-workspace mirror
EngineTerminal  PTY + offset-indexed buffer PTYSession    Ghostty surface ⇄ TerminalChannel
ChatEngine      agent CLI, transcript       ChatSession   transcript mirror
ScriptRun       setup / run scripts         Run/SetupController
PRTracker, PRConversationLoader             PRTrackerProxy, PRConversationStore
        │                                           ▲
        └── EngineServer ── FramedConnection ── EngineClient / EngineConnection
            (RPCs, observation-driven events,   (socketpair locally; ssh pipes
             binary terminal frames)             or a unix socket remotely)
```

The protocol (`Protocol/`) is typed RPCs (`API.*`) plus `EngineEvent`s the
engine pushes as its state changes: app-wide state and per-workspace slices
as whole values, chat transcripts as patches (streamed text as appends), and
terminal output as raw frames carrying byte offsets. Local mode runs the
same protocol over a socketpair, so there is one code path.

```
Sources/JetlineApp/
├── JetlineApp.swift          ─ SwiftUI App (entered from JetlineMain)
├── AppState.swift            ─ client root state: engine mirror + UI state
├── Engine/                   ─ Engine, EngineWorkspace, EngineTerminal, ChatEngine, ScriptRun
├── Server/                   ─ EngineServer, ObservationPump, ChatPublisher, TerminalHub
├── Protocol/                 ─ Wire envelopes + snapshots, API catalogue, framing
├── Client/                   ─ EngineClient, EngineConnection, ChatSession mirror, TerminalChannel
├── Daemon/                   ─ `jetlined` commands (serve / attach / status / stop / rpc)
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
│   ├── Watcher.swift             ─ FSEvents (inotify on Linux) → coalesced refresh
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
    ├── Shell/AppShell.swift      ─ per-tab-window AppKit split: sidebar | tab | inspector
    ├── Shell/TabWindows.swift    ─ native window tabs (one NSWindow per tab), menu-first hotkeys
    ├── Shell/TabToolbar.swift    ─ AppKit toolbar per tab window: title, git, open in, run
    ├── Sidebar/                  ─ repos, workspaces, new/import sheets, repo settings
    ├── Terminal/TerminalArea     ─ one tab's content (terminal, chat or diff)
    ├── Terminal/NewTabPage       ─ what the tab bar's + opens: pick a chat, terminal or closed chat
    ├── Inspector/                ─ Changes / PR / Run tabs (segmented accessory, Xcode-style)
    ├── Settings/                 ─ TabView'd preferences (incl. action prompts)
    ├── Shared/                   ─ CapsuleTabs etc.
    └── Welcome/                  ─ empty state
```

### Data flow

```
sidebar → AppState.selectWorkspace → ActivateWorkspace (engine) → restore chats / spawn a tab
                                                                ↘ start watcher → DiffComputer
                                                                                → EngineWorkspace
        ← workspaceStatus / workspaceDiff events ← ObservationPump ←───────────────┘
        → AppState mirror → WorkspaceState → views

PRTracker (timer + kicks) → reconcile branch/upstream → gh GraphQL PR poll
                          → PR number/url identity + on-disk PRSnapshots cache
                          → Engine.applyPR → workspacePR event

git action bar → GitActionPrompts.render → new PTYSession with initial prompt
              ↘ mergePR → gh pr merge (no agent)
              ↘ rebase / pull → fast-path git, fall back to agent on conflict
```

Workspaces live in `~/.jetline/worktrees/<repoId>/<workspaceId>`. The
SQLite db lives at `~/.jetline/jetline.sqlite`. PR identities and snapshots are
cached alongside it. Terminal receive diagnostics are written to
`~/.jetline/jetline-terminal-receive.log` and rotated at 5 MB. Override the
data dir with the `JETLINE_DATA_DIR` env var.

Clicking a repository header in the sidebar opens the repository's base
checkout (`repo.path`) in the same terminal/inspector view as a workspace,
with its own in-memory terminal tabs. These base-repo tabs are not persisted
as workspace rows and are not included in PR polling.

Merged PRs auto-archive their workspace and, by default, delete the local
worktree/branch; this can be disabled in Settings. Reusing a branch name
after an old PR merged is guarded by the PR merge timestamp, and branch
creation/import offers an explicit override if that branch is still checked
out in another worktree.

Per-workspace mutable state (diff snapshots, PR snapshot, sessions, branch
position, run/setup controllers) lives on `WorkspaceState` instances looked
up via `AppState.workspaceState(for:)`, *not* in `@Published` dicts on
`AppState` — so a single workspace's poll/diff update only invalidates the
views that actually read it. The engine side mirrors that split
(`EngineWorkspace`), and publishes each slice separately.

`make test` runs on macOS; the engine's tests also run on Linux
(`scripts/linux/build-daemon.sh` shows the Docker setup), including an
end-to-end one that drives a real engine through the protocol.

## License

EUPL v1.2

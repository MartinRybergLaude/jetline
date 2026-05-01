import AppKit

/// libghostty-backed terminal — STUB.
///
/// **Status:** intentionally not implemented. Ghostty's embedder C API
/// (`include/ghostty.h`) and Swift wrappers (`macos/Sources/Ghostty/*.swift`)
/// are tightly coupled to their own app shell and not yet a stable third-party
/// embedding surface. Wiring this up well is a 2–3 week project on its own.
///
/// **Migration plan to swap from SwiftTerm to libghostty:**
///
/// 1. Add Ghostty as a git submodule under `Vendor/ghostty`:
///        git submodule add https://github.com/ghostty-org/ghostty Vendor/ghostty
///    Pin to a known-good commit. Ghostty requires Zig 0.13+ to build.
///
/// 2. Add a `Makefile` target that runs `zig build -Doptimize=ReleaseFast` in the
///    submodule and copies `zig-out/.../GhosttyKit.xcframework` to
///    `Frameworks/GhosttyKit.xcframework`.
///
/// 3. Reference the xcframework as a `.binaryTarget` in `Package.swift`:
///
///        .binaryTarget(name: "GhosttyKit", path: "Frameworks/GhosttyKit.xcframework")
///
///    Add `"GhosttyKit"` to the JetforgeApp executable target's dependencies.
///
/// 4. Replace the body below by porting the relevant pieces of
///    `macos/Sources/Ghostty/Ghostty.App.swift`,
///    `macos/Sources/Ghostty/Ghostty.SurfaceView.swift`, and
///    `macos/Sources/Ghostty/SurfaceView_AppKit.swift` from the Ghostty repo —
///    enough to construct one `ghostty_app_t`, attach a single
///    `ghostty_surface_t` per terminal view, and feed it config + input.
///
/// 5. Spawn the agent CLI by passing `command` in the surface config (Ghostty's
///    embedder API runs the program inside its own PTY). Set `working-directory`
///    to the worktree path. See `apprt/embedded.zig` for available config keys.
///
/// 6. Flip `TerminalBackend.default` to `.ghostty` and remove the SwiftTerm
///    dependency from `Package.swift` once parity is verified.
///
/// Until then, this stub fatalErrors on use so we can't accidentally ship it.
@MainActor
final class GhosttyEmulator: TerminalEmulatorView {
    var nsView: NSView { _placeholder }
    private let _placeholder: NSView = {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.1).cgColor
        return v
    }()

    func spawn(executable: String, args: [String], cwd: String, env: [String: String]) {
        fatalError("GhosttyEmulator is a stub — see migration plan in this file's header.")
    }

    func sendInterrupt() {}
    func write(_ string: String) {}
    func updateFont(family: String, size: CGFloat) {}
    func terminate() {}
}

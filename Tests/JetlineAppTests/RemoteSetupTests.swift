#if os(macOS)
import XCTest
@testable import JetlineApp

/// Connecting a machine: the installer's probe verdicts and shell quoting,
/// remote targets, and which host owns a workspace.
@MainActor
final class RemoteSetupTests: XCTestCase {
    private typealias Probe = RemoteInstaller.Probe

    private func probe(
        os: Probe.OS = .linux,
        version: String? = JetlineVersion.current,
        protocolVersion: Int? = Wire.protocolVersion,
        features: [String]? = API.features
    ) -> Probe {
        Probe(
            os: os, arch: "x86_64", daemonVersion: version, daemonProtocol: protocolVersion,
            daemonFeatures: features, daemonRunning: false, macAppDaemon: nil, missingTools: []
        )
    }

    // MARK: Probe verdicts

    func testNothingInstalledIsNeitherCompatibleNorCurrent() {
        let p = probe(version: nil, protocolVersion: nil, features: nil)
        XCTAssertFalse(p.isInstalled)
        XCTAssertFalse(p.isCompatible)
        XCTAssertFalse(p.isCurrent)
    }

    func testTheSameBuildIsCurrent() {
        let p = probe()
        XCTAssertTrue(p.isInstalled)
        XCTAssertTrue(p.isCompatible)
        XCTAssertTrue(p.isCurrent)
    }

    func testCompatibilityFollowsTheProtocolNotTheVersion() {
        let older = probe(version: "0.0.1")
        XCTAssertTrue(older.isCompatible, "same protocol, older version: it can still serve")
        XCTAssertFalse(older.isCurrent)
        let otherProtocol = probe(protocolVersion: Wire.protocolVersion + 1)
        XCTAssertFalse(otherProtocol.isCompatible)
    }

    /// Daemons from before `jetlined info` report no protocol.
    func testWithoutAProtocolOnlyTheSameVersionIsCompatible() {
        XCTAssertTrue(probe(protocolVersion: nil).isCompatible)
        XCTAssertFalse(probe(version: "0.0.1", protocolVersion: nil).isCompatible)
    }

    func testALinuxBuildMissingAFeatureIsOutdated() {
        let lacking = probe(features: [])
        XCTAssertTrue(lacking.isCompatible)
        XCTAssertFalse(lacking.isCurrent, "same version, but without tunnels: reinstall")
        XCTAssertFalse(probe(features: nil).isCurrent, "no feature list on Linux means a pre-feature build")
        XCTAssertTrue(probe(features: API.features + ["somethingNewer"]).isCurrent)
    }

    func testAMacAppDaemonsVersionStandsWithoutFeatures() {
        XCTAssertTrue(probe(os: .macOS, features: nil).isCurrent)
        XCTAssertFalse(probe(os: .macOS, features: []).isCurrent)
    }

    // MARK: Installer helpers

    func testRemotePathsExpandHomeAndQuoteTheRest() {
        XCTAssertEqual(RemoteInstaller.remotePathExpression("~/.jetline/bin/jetlined"), "\"$HOME\"/.jetline/bin/jetlined")
        XCTAssertEqual(RemoteInstaller.remotePathExpression("  ~/my tools/jetlined "), "\"$HOME\"/'my tools/jetlined'")
        XCTAssertEqual(RemoteInstaller.remotePathExpression("/opt/jetline/jetlined"), "/opt/jetline/jetlined")
        XCTAssertEqual(RemoteInstaller.remotePathExpression("/opt/it's here"), "'/opt/it'\\''s here'")
        // `~user` isn't ours to expand.
        XCTAssertEqual(RemoteInstaller.remotePathExpression("~bob/jetlined"), "~bob/jetlined")
    }

    func testArchitecturesNormalize() {
        XCTAssertEqual(RemoteInstaller.normalize(arch: "x86_64"), "x86_64")
        XCTAssertEqual(RemoteInstaller.normalize(arch: "amd64"), "x86_64")
        XCTAssertEqual(RemoteInstaller.normalize(arch: " arm64 "), "aarch64")
        XCTAssertEqual(RemoteInstaller.normalize(arch: "aarch64"), "aarch64")
        XCTAssertEqual(RemoteInstaller.normalize(arch: "riscv64"), "riscv64")
    }

    func testSSHErrorsAreExplained() {
        XCTAssertTrue(RemoteInstaller.explain("user@box: Permission denied (publickey).", status: 255).hasPrefix("ssh couldn't log in without a password"))
        XCTAssertTrue(RemoteInstaller.explain("ssh: Could not resolve hostname nowhere: nodename nor servname provided", status: 255).hasPrefix("Unknown host"))
        XCTAssertTrue(RemoteInstaller.explain("ssh: connect to host box port 22: Connection refused", status: 255).hasPrefix("The machine can't be reached"))
        XCTAssertTrue(RemoteInstaller.explain("ssh: connect to host box port 22: Operation timed out", status: 255).hasPrefix("The machine can't be reached"))
        XCTAssertEqual(RemoteInstaller.explain("  \n", status: 7), "ssh exited with status 7.")
        XCTAssertEqual(RemoteInstaller.explain("gunzip: stdin: not in gzip format\n", status: 1), "gunzip: stdin: not in gzip format")
    }

    // MARK: Remote targets

    func testShellQuoting() {
        XCTAssertEqual(RemoteEngine.shellQuote("devbox"), "devbox")
        XCTAssertEqual(RemoteEngine.shellQuote("me@dev-box.local:22"), "me@dev-box.local:22")
        XCTAssertEqual(RemoteEngine.shellQuote("~/.jetline/bin/jetlined attach"), "'~/.jetline/bin/jetlined attach'")
        XCTAssertEqual(RemoteEngine.shellQuote("a'b"), "'a'\\''b'")
        XCTAssertEqual(RemoteEngine.shellQuote("$(rm -rf /)"), "'$(rm -rf /)'")
        XCTAssertEqual(RemoteEngine.shellQuote(""), "")
    }

    /// Quoting survives a real shell.
    func testQuotedArgumentsRoundTripThroughSh() async throws {
        let nasty = "it's a \"test\" with $HOME, `ticks` and \\ backslash"
        let result = await Subprocess.run(executable: "/bin/sh", args: ["-c", "printf %s \(RemoteEngine.shellQuote(nasty))"])
        XCTAssertEqual(result.stdout, nasty)
    }

    func testSSHTargetCommand() {
        let remote = RemoteEngine.ssh(host: "me@devbox")
        XCTAssertEqual(remote.name, "me@devbox")
        XCTAssertEqual(remote.sshHost, "me@devbox")
        XCTAssertTrue(remote.command.hasPrefix("ssh "))
        XCTAssertTrue(remote.command.contains("-T"))
        XCTAssertTrue(remote.command.contains("ServerAliveInterval=15"))
        XCTAssertTrue(remote.command.hasSuffix(" me@devbox '~/.jetline/bin/jetlined attach'"), remote.command)

        let custom = RemoteEngine.ssh(host: "box", daemonPath: "/opt/j d/jetlined")
        XCTAssertTrue(custom.command.hasSuffix(" box '/opt/j d/jetlined attach'"), custom.command)
    }

    func testEngineTargetsCodeAndName() throws {
        let remote = EngineTarget.remote(RemoteEngine(name: "devbox", command: "ssh devbox x", sshHost: "devbox"))
        XCTAssertEqual(EngineTarget.local.displayName, "This Mac")
        XCTAssertEqual(remote.displayName, "devbox")
        XCTAssertTrue(EngineTarget.local.isLocal)
        XCTAssertFalse(remote.isLocal)
        for target in [EngineTarget.local, remote] {
            XCTAssertEqual(try JSONDecoder().decode(EngineTarget.self, from: JSONEncoder().encode(target)), target)
        }
        let config = RemoteHostConfig(id: "abc", remote: RemoteEngine(name: "n", command: "c"))
        XCTAssertEqual(try JSONDecoder().decode(RemoteHostConfig.self, from: JSONEncoder().encode(config)), config)
    }

    // MARK: Hosts

    func testAHostOwnsItsRepositoriesWorkspacesAndBaseCheckouts() {
        let host = EngineHost(id: "env-test", name: "devbox", target: .remote(RemoteEngine(name: "devbox", command: "true", sshHost: "devbox")))
        defer { host.ports?.stop() }
        XCTAssertFalse(host.isLocal)
        XCTAssertEqual(host.sshHost, "devbox")
        XCTAssertNotNil(host.ports, "a remote forwards its ports")

        let repo = Repository(id: "r1", name: "app", path: "/home/me/app", defaultBranch: "main", createdAt: Date(), lastOpenedAt: nil)
        let ws = Workspace(
            id: "w1", repositoryId: "r1", name: "feature", branchName: "feature", baseBranch: "main",
            pullRequestNumber: nil, pullRequestURL: nil, worktreePath: "/home/me/.jetline/worktrees/app/feature",
            agent: .shell, createdAt: Date(), lastActiveAt: Date()
        )
        XCTAssertFalse(host.owns(workspaceId: "w1"))
        host.repositories = [repo]
        host.workspacesByRepo = ["r1": [ws]]
        XCTAssertTrue(host.owns(repoId: "r1"))
        XCTAssertTrue(host.owns(workspaceId: "w1"))
        XCTAssertTrue(host.owns(workspaceId: Engine.repositoryBaseWorkspacePrefix + "r1"))
        XCTAssertFalse(host.owns(workspaceId: Engine.repositoryBaseWorkspacePrefix + "r2"))
        XCTAssertFalse(host.owns(workspaceId: "w2"))
        XCTAssertFalse(host.owns(repoId: "r2"))

        let local = EngineHost(id: EngineHost.localId, name: "This Mac", target: .local)
        XCTAssertTrue(local.isLocal)
        XCTAssertNil(local.ports, "this Mac's ports are already here")
        XCTAssertNil(local.sshHost)
    }
}
#endif

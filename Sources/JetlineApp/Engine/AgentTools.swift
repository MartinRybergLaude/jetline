import Foundation

/// The tools Jetline gives the agents it launches, served to them over MCP
/// by `jetlined mcp` (see `AgentToolsServer`) and carried out here.
///
/// Reads reach every workspace in the caller's repository. Writes reach
/// only the caller's own workspace and the ones it created: another agent
/// may be mid-task in any other worktree. Merging, deleting and closing
/// aren't offered at all — those stay with the user.
enum AgentTools {
    struct Tool: Sendable {
        var name: String
        var description: String
        var inputSchema: JSONValue
        /// Needs no approval: it only reads.
        var readOnly: Bool
        /// Rewrites a branch's history (MCP's `destructiveHint`).
        var rewritesHistory: Bool = false
    }

    /// The MCP server name. Claude addresses a tool as `mcp__jetline__<name>`.
    static let serverName = "jetline"

    static let catalog: [Tool] = [
        Tool(
            name: "get_context",
            description: """
            Where you are in Jetline: your workspace (name, branch, base, worktree), the stack \
            it's part of, its pull request and checks, and the repository's default branch. \
            Call this before creating or restacking workspaces.
            """,
            inputSchema: schema([:]),
            readOnly: true
        ),
        Tool(
            name: "list_workspaces",
            description: """
            Every Jetline workspace in this repository: id, branch, base, the workspace it's \
            stacked on, pull request state, who created it, and whether you may change it.
            """,
            inputSchema: schema([:]),
            readOnly: true
        ),
        Tool(
            name: "get_workspace",
            description: "One workspace in detail: pull request with review and checks, ahead/behind counts, changed files, note.",
            inputSchema: schema(["workspace_id": workspaceIdProperty], required: ["workspace_id"]),
            readOnly: true
        ),
        Tool(
            name: "create_workspace",
            description: """
            Create a Jetline workspace: a branch with its own worktree in the user's sidebar, \
            set up by the repository's setup script. Nothing runs in it. stack_on "current" \
            starts it from your branch's tip as it is now (commit first) and targets its PR at \
            your branch; without stack_on it starts from the default branch.
            """,
            inputSchema: schema([
                "name": .object(["type": "string", "description": "Short human name, e.g. \"settings screen\". The branch name is derived from it."]),
                "stack_on": .object(["type": "string", "description": "\"current\" for your workspace, or a workspace id. Omit to start from the default branch."]),
                "note": .object(["type": "string", "description": "What the workspace is for, for whoever picks it up."])
            ], required: ["name"]),
            readOnly: false
        ),
        Tool(
            name: "import_branch",
            description: "Open an existing remote branch or pull request as a new workspace. Give exactly one of branch or pull_request.",
            inputSchema: schema([
                "branch": .object(["type": "string", "description": "Remote branch name, without the remote prefix."]),
                "pull_request": .object(["type": "integer", "description": "Pull request number."]),
                "name": .object(["type": "string", "description": "Workspace name. Defaults to the branch or PR title."]),
                "note": .object(["type": "string", "description": "What the workspace is for."])
            ]),
            readOnly: false
        ),
        Tool(
            name: "rename_workspace",
            description: "Rename a workspace as shown in the sidebar. The branch keeps its name.",
            inputSchema: schema([
                "workspace_id": workspaceIdProperty,
                "name": .object(["type": "string"])
            ], required: ["name"]),
            readOnly: false
        ),
        Tool(
            name: "set_workspace_note",
            description: "Replace a workspace's note. An empty note removes it.",
            inputSchema: schema([
                "workspace_id": workspaceIdProperty,
                "note": .object(["type": "string"])
            ], required: ["note"]),
            readOnly: false
        ),
        Tool(
            name: "restack_workspace",
            description: """
            Move a workspace onto another base: rebase its own commits onto that workspace's \
            branch (or the default branch), push, and retarget its pull request. Rewrites the \
            worktree's history, so commit or stash first. Refused for a PR that's part of a \
            GitHub stack.
            """,
            inputSchema: schema([
                "workspace_id": workspaceIdProperty,
                "onto": .object(["type": "string", "description": "A workspace id, or \"default\" for the default branch."])
            ], required: ["onto"]),
            readOnly: false,
            rewritesHistory: true
        ),
        Tool(
            name: "rebase_workspace",
            description: "Rebase a workspace onto the latest of its base and push. On conflicts nothing changes and you're told.",
            inputSchema: schema(["workspace_id": workspaceIdProperty]),
            readOnly: false,
            rewritesHistory: true
        ),
        Tool(
            name: "pull_workspace",
            description: "Bring a workspace's branch up to date with commits pushed to it elsewhere (git pull --rebase).",
            inputSchema: schema(["workspace_id": workspaceIdProperty]),
            readOnly: false,
            rewritesHistory: true
        )
    ]

    static var readOnlyToolNames: [String] { catalog.filter(\.readOnly).map(\.name) }

    private static let workspaceIdProperty: JSONValue = .object([
        "type": "string",
        "description": "A workspace id from list_workspaces. Defaults to your own workspace."
    ])

    private static func schema(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        .object([
            "type": "object",
            "properties": .object(properties),
            "required": .array(required.map(JSONValue.string)),
            "additionalProperties": false
        ])
    }
}

/// How to start the agent tools' MCP server for one workspace: this binary
/// in its `mcp` mode, pointed at the engine's socket.
struct AgentToolsLaunch: Sendable, Hashable {
    var executable: String
    var args: [String]
    var env: [String: String]

    static let socketEnvKey = "JETLINE_ENGINE_SOCKET"
    static let workspaceEnvKey = "JETLINE_WORKSPACE_ID"

    init(socketPath: String, workspaceId: String) {
        executable = JetlineDaemon.currentExecutable() ?? "jetlined"
        args = JetlineDaemon.commandPrefix + ["mcp"]
        env = [Self.socketEnvKey: socketPath, Self.workspaceEnvKey: workspaceId]
    }

    /// The flags that give `agent` these tools. Vibe isn't wired up yet.
    func args(for agent: Workspace.AgentKind) -> [String] {
        switch agent {
        case .claude: return claudeArgs
        case .codex: return codexArgs
        case .vibe, .shell: return []
        }
    }

    /// Claude Code flags: the server, and the read-only tools pre-approved.
    /// `=` forms, since both flags are variadic and would swallow a
    /// trailing prompt argument.
    private var claudeArgs: [String] {
        let config: JSONValue = .object(["mcpServers": .object([
            AgentTools.serverName: .object([
                "command": .string(executable),
                "args": .array(args.map(JSONValue.string)),
                "env": .object(env.mapValues(JSONValue.string))
            ])
        ])])
        let allowed = AgentTools.readOnlyToolNames.map { "mcp__\(AgentTools.serverName)__\($0)" }
        return ["--mcp-config=\(config.serializedString())", "--allowedTools=\(allowed.joined(separator: ","))"]
    }

    /// Codex `-c` overrides (values are TOML). Tools that don't declare
    /// themselves read-only ask first.
    private var codexArgs: [String] {
        let prefix = "mcp_servers.\(AgentTools.serverName)"
        var out = [
            "-c", "\(prefix).command=\(Self.toml(executable))",
            "-c", "\(prefix).args=[\(args.map(Self.toml).joined(separator: ", "))]",
            "-c", "\(prefix).default_tools_approval_mode=\"writes\""
        ]
        for (key, value) in env.sorted(by: { $0.key < $1.key }) {
            out += ["-c", "\(prefix).env.\(key)=\(Self.toml(value))"]
        }
        return out
    }

    private static func toml(_ string: String) -> String {
        "\"" + string.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

// MARK: - Engine side

extension Engine {
    /// The MCP server config for agents launched in `workspaceId`, or `nil`
    /// while the engine has no socket for it to reach back on.
    func agentToolsLaunch(for workspaceId: String) -> AgentToolsLaunch? {
        agentToolsSocket.map { AgentToolsLaunch(socketPath: $0, workspaceId: workspaceId) }
    }

    /// Run `tool` for an agent in `callerId`. Failures come back as an
    /// error result for the agent to read, not a protocol error.
    func runAgentTool(_ tool: String, arguments: JSONValue, callerId: String) async -> API.AgentToolResult {
        do {
            guard let caller = workspaceById(callerId),
                  let repo = repository(id: caller.repositoryId) else {
                throw WireError("This workspace no longer exists in Jetline.")
            }
            let args = AgentToolArguments(arguments)
            let result: [String: JSONValue]
            switch tool {
            case "get_context":
                result = context(for: caller, repo: repo)
            case "list_workspaces":
                result = ["workspaces": .array(repoWorkspaces(repo).map { .object(summary(of: $0, caller: caller, repo: repo)) })]
            case "get_workspace":
                result = detail(of: try readable(target(args, caller: caller), caller: caller), caller: caller, repo: repo)
            case "create_workspace":
                result = try await toolCreateWorkspace(args, caller: caller, repo: repo)
            case "import_branch":
                result = try await toolImportBranch(args, caller: caller, repo: repo)
            case "rename_workspace":
                let target = try writableTarget(args, caller: caller)
                let name = try args.requiredString("name")
                renameWorkspace(target.id, to: name)
                result = ["renamed": .string(target.id), "name": .string(name)]
            case "set_workspace_note":
                let target = try writableTarget(args, caller: caller)
                setWorkspaceNote(target.id, note: args.string("note"))
                result = ["updated": .string(target.id)]
            case "restack_workspace":
                let target = try writableTarget(args, caller: caller)
                let onto = try args.requiredString("onto")
                let parent = onto == "default" ? nil : try readable(workspace(id: onto), caller: caller)
                let warning = try await restackWorkspace(target, onto: parent.flatMap { isRepositoryBaseWorkspace($0) ? nil : $0 })
                let base = workspaceById(target.id).map { repo.localName(forRemoteRef: $0.baseBranch) }
                result = ["restacked": .string(target.id), "base": base.map(JSONValue.string) ?? .null, "warning": warning.map(JSONValue.string) ?? .null]
            case "rebase_workspace":
                let target = try writableTarget(args, caller: caller)
                try await rebase(target).get()
                result = ["rebased": .string(target.id), "onto": .string(baseRef(for: target))]
            case "pull_workspace":
                let target = try writableTarget(args, caller: caller)
                try await pull(target).get()
                result = ["pulled": .string(target.id)]
            default:
                throw WireError("Unknown tool \(tool).")
            }
            if AgentTools.catalog.first(where: { $0.name == tool })?.readOnly == false {
                activityLog.record(.gitAction, "Agent tool \(tool)", repoId: repo.id, workspaceId: caller.id)
            }
            return API.AgentToolResult(text: JSONValue.object(result).serializedString(), isError: false)
        } catch {
            return API.AgentToolResult(text: error.localizedDescription, isError: true)
        }
    }

    // MARK: Access

    private func repoWorkspaces(_ repo: Repository) -> [Workspace] {
        workspacesByRepo[repo.id] ?? []
    }

    /// `workspace_id`, else the caller's own workspace.
    private func target(_ args: AgentToolArguments, caller: Workspace) throws -> Workspace {
        guard let id = args.string("workspace_id") else { return caller }
        return try workspace(id: id)
    }

    private func workspace(id: String) throws -> Workspace {
        guard let ws = workspaceById(id) else {
            throw WireError("No workspace \(id). list_workspaces shows the ids.")
        }
        return ws
    }

    private func readable(_ target: Workspace, caller: Workspace) throws -> Workspace {
        guard target.repositoryId == caller.repositoryId else {
            throw WireError("That workspace is in another repository.")
        }
        return target
    }

    /// The target of a write: the caller's own workspace, or one it created.
    private func writableTarget(_ args: AgentToolArguments, caller: Workspace) throws -> Workspace {
        let target = try readable(target(args, caller: caller), caller: caller)
        guard canChange(target, caller: caller) else {
            throw WireError("You may only change your own workspace and the ones you created, and not the repository's own checkout. \(target.name) isn't one of those.")
        }
        return target
    }

    private func canChange(_ target: Workspace, caller: Workspace) -> Bool {
        !isRepositoryBaseWorkspace(target) && (target.id == caller.id || target.createdByWorkspaceId == caller.id)
    }

    // MARK: Reads

    private func context(for caller: Workspace, repo: Repository) -> [String: JSONValue] {
        var out = detail(of: caller, caller: caller, repo: repo)
        out["repository"] = [
            "name": .string(repo.name),
            "default_branch": .string(repo.localName(forRemoteRef: repo.defaultBranch)),
            "remote": .string(repo.remoteOrigin)
        ]
        if let stack = StackSummary.build(for: caller, in: repoWorkspaces(repo), repo: repo, pr: loadedPR) {
            out["stack"] = [
                "on_github": .bool(stack.isOnGitHub),
                "trunk": .string(stack.trunk),
                "layers_top_first": .array(stack.layers.map { layer in
                    [
                        "workspace_id": layer.workspaceId.map(JSONValue.string) ?? .null,
                        "branch": .string(layer.branch),
                        "title": .string(layer.title),
                        "pull_request": layer.number.map(JSONValue.number) ?? .null,
                        "state": layer.state.map(JSONValue.string) ?? .null,
                        "is_you": .bool(layer.isCurrent)
                    ]
                })
            ]
        }
        return out
    }

    private func loadedPR(_ ws: Workspace) -> PullRequest? {
        if case let .loaded(pr, _) = workspaceState(for: ws.id).pr { return pr }
        return nil
    }

    private func summary(of ws: Workspace, caller: Workspace, repo: Repository) -> [String: JSONValue] {
        var out: [String: JSONValue] = [
            "id": .string(ws.id),
            "name": .string(ws.name),
            "branch": .string(ws.branchName),
            "base": .string(repo.localName(forRemoteRef: ws.baseBranch)),
            "stacked_on": WorkspaceStacks.parent(of: ws, in: repoWorkspaces(repo), repo: repo).map { .string($0.id) } ?? .null,
            "is_you": .bool(ws.id == caller.id),
            "you_may_change": .bool(canChange(ws, caller: caller)),
            "created_by": ws.createdByWorkspaceId.map(JSONValue.string) ?? .null
        ]
        if let pr = loadedPR(ws) {
            out["pull_request"] = [
                "number": .number(pr.number),
                "state": .string(pr.isDraft ? "DRAFT" : pr.state.uppercased()),
                "url": .string(pr.url)
            ]
        }
        return out
    }

    private func detail(of ws: Workspace, caller: Workspace, repo: Repository) -> [String: JSONValue] {
        var out = summary(of: ws, caller: caller, repo: repo)
        let state = workspaceState(for: ws.id)
        out["worktree"] = .string(ws.worktreePath)
        out["note"] = ws.note.map(JSONValue.string) ?? .null
        let position = state.branchPosition
        out["position"] = [
            "behind_base": .number(position.behindBase),
            "ahead_of_remote": .number(position.aheadOfRemote),
            "behind_remote": .number(position.behindRemote),
            "pushed": .bool(position.remoteTrackingExists)
        ]
        if let diff = state.diff {
            out["changes_vs_base"] = [
                "files": .array(diff.files.prefix(100).map { .string($0.path) }),
                "additions": .number(diff.totalAdditions),
                "deletions": .number(diff.totalDeletions)
            ]
        }
        if case let .loaded(pr, checks) = state.pr, var pull = out["pull_request"]?.object {
            pull["title"] = .string(pr.title)
            pull["base"] = .string(pr.baseRefName)
            pull["merge_blocker"] = pr.isOpen ? MergeReadiness.evaluate(pr: pr, checks: checks).reason.map(JSONValue.string) ?? .null : .null
            pull["open_comments"] = .number(pr.unresolvedThreadCount + pr.issueCommentCount)
            pull["checks"] = [
                "total": .number(checks.count),
                "running": .number(checks.filter(\.isActive).count),
                "failing": .array(checks.filter { $0.bucket == .fail }.map { .string($0.name) })
            ]
            pull["github_stack"] = pr.stack.map { .number($0.number) } ?? .null
            out["pull_request"] = .object(pull)
        }
        return out
    }

    // MARK: Writes

    private func toolCreateWorkspace(_ args: AgentToolArguments, caller: Workspace, repo: Repository) async throws -> [String: JSONValue] {
        let name = try args.requiredString("name")
        let baseId: String?
        switch args.string("stack_on") {
        case nil: baseId = nil
        case "current": baseId = isRepositoryBaseWorkspace(caller) ? nil : caller.id
        case let id?: baseId = try readable(workspace(id: id), caller: caller).id
        }
        let result = try await createWorkspace(
            in: repo,
            name: name,
            baseWorkspaceId: baseId,
            createdBy: caller.id,
            note: args.string("note"),
            overrideExisting: false
        )
        return try created(result, caller: caller, repo: repo)
    }

    private func toolImportBranch(_ args: AgentToolArguments, caller: Workspace, repo: Repository) async throws -> [String: JSONValue] {
        let remoteRef: String?
        let pullRequest: PRSummary?
        let defaultName: String
        switch (args.string("branch"), args.int("pull_request")) {
        case let (branch?, nil):
            (remoteRef, pullRequest, defaultName) = (repo.remoteRef(branch), nil, branch)
        case let (nil, number?):
            guard let identifier = repoMetadataByRepo[repo.id] else {
                throw WireError("Jetline hasn't reached GitHub for this repository yet.")
            }
            guard let (pr, _) = try await GitHubRunner.batchFetchPRsByNumber(repo: identifier, numbers: [number], cwd: repo.path)[number] else {
                throw WireError("No pull request #\(number) in \(identifier.owner)/\(identifier.name).")
            }
            let summary = PRSummary(
                number: pr.number,
                title: pr.title,
                url: pr.url,
                authorLogin: pr.author.login,
                headRefName: pr.headRefName,
                headRepositoryOwner: identifier.owner,
                baseRefName: pr.baseRefName,
                isDraft: pr.isDraft,
                updatedAt: Date(),
                checkBucket: nil
            )
            (remoteRef, pullRequest, defaultName) = (nil, summary, pr.title)
        default:
            throw WireError("Give exactly one of branch or pull_request.")
        }
        let result = try await importBranch(
            in: repo,
            remoteRef: remoteRef,
            pullRequest: pullRequest,
            name: args.string("name") ?? defaultName,
            createdBy: caller.id,
            note: args.string("note"),
            overrideExisting: false
        )
        return try created(result, caller: caller, repo: repo)
    }

    private func created(_ result: API.CreateWorkspaceResult, caller: Workspace, repo: Repository) throws -> [String: JSONValue] {
        switch result {
        case let .created(ws):
            return summary(of: ws, caller: caller, repo: repo)
        case let .branchInUse(branch, path, _):
            throw WireError("Branch \(branch) is already checked out at \(path).")
        }
    }
}

private extension JSONValue {
    static func number(_ value: Int) -> JSONValue { .int(Int64(value)) }
}

/// Typed reads of a tool call's arguments.
private struct AgentToolArguments {
    let raw: JSONValue

    init(_ raw: JSONValue) { self.raw = raw }

    func string(_ key: String) -> String? { raw[key]?.string?.nonBlank }
    func int(_ key: String) -> Int? { raw[key]?.int }

    func requiredString(_ key: String) throws -> String {
        guard let value = string(key) else { throw WireError("\(key) is required.") }
        return value
    }
}

import Foundation

/// `jetline <tool> [--flag value …]`: Jetline's agent tools from a shell, for
/// people, scripts and agents without MCP. The same tools and rules as
/// `jetlined mcp`: the caller is the workspace holding the working directory
/// (see `AgentToolsCaller`), and only it and the workspaces it created can
/// be changed. Flags come from each tool's input schema; output is JSON.
///
/// `jetline` is the link `AgentToolsRegistration` keeps in the data
/// directory, which every Jetline terminal has first on its PATH.
public enum AgentToolsCLI {
    struct UsageError: Error, CustomStringConvertible {
        var description: String
        init(_ description: String) { self.description = description }
    }

    /// `tools`, or a tool name (kebab or snake case).
    public static func handles(_ command: String) -> Bool {
        command == "tools" || tool(named: command) != nil
    }

    public static func run(argv: [String]) -> Never {
        guard let command = argv.first, command != "tools" else {
            print(overview)
            exit(0)
        }
        guard let tool = tool(named: command) else { fail("unknown command '\(command)'\n\n\(overview)") }
        let rest = Array(argv.dropFirst())
        if rest.first == "--help" || rest.first == "-h" {
            print(usage(for: tool))
            exit(0)
        }
        let input: JSONValue
        do {
            input = try arguments(for: tool, from: rest)
        } catch {
            fail("\(error)\n\n\(usage(for: tool))")
        }
        guard let caller = AgentToolsCaller.current() else {
            fail("not in a Jetline workspace. Run it inside a workspace's worktree while Jetline is running.")
        }
        do {
            let client = try BlockingEngineClient(socketPath: caller.socketPath, clientName: "jetline cli")
            let reply = try client.call(API.AgentToolCall.method, [
                "workspaceId": .string(caller.workspaceId),
                "tool": .string(tool.name),
                "arguments": input
            ])
            let text = reply["text"]?.string ?? ""
            guard reply["isError"]?.bool != true else { fail(text) }
            print((try? JSONValue.parse(Data(text.utf8)).prettyPrinted()) ?? text)
            exit(0)
        } catch {
            fail(error.localizedDescription)
        }
    }

    static func tool(named name: String) -> AgentTools.Tool? {
        let snake = name.replacingOccurrences(of: "-", with: "_")
        return AgentTools.catalog.first { $0.name == snake }
    }

    /// `PATH` with `bin` first, once.
    static func prependingBin(_ bin: String, to env: [String: String]) -> [String: String] {
        let rest = (env["PATH"] ?? "").split(separator: ":").map(String.init).filter { $0 != bin }
        return env.merging(["PATH": ([bin] + rest).joined(separator: ":")]) { $1 }
    }

    // MARK: Arguments

    /// The tool's arguments from `--flag value` / `--flag=value` pairs (an
    /// array's flag repeats), bare values for its required properties in
    /// order, and `--json '{…}'` as a base the flags override.
    static func arguments(for tool: AgentTools.Tool, from argv: [String]) throws -> JSONValue {
        let properties = tool.inputSchema["properties"]?.object ?? [:]
        let required = tool.inputSchema["required"]?.array?.compactMap(\.string) ?? []
        var flagged: [String: JSONValue] = [:]
        var base: [String: JSONValue] = [:]
        var positional: [String] = []
        var rest = argv[...]
        while let arg = rest.popFirst() {
            guard arg.hasPrefix("--") else {
                positional.append(arg)
                continue
            }
            let parts = arg.split(separator: "=", maxSplits: 1).map(String.init)
            let flag = parts[0]
            if flag == "--json" {
                let text = try parts.count > 1 ? parts[1] : value(after: flag, in: &rest)
                guard case let .object(object)? = try? JSONValue.parse(Data(text.utf8)) else {
                    throw UsageError("--json needs a JSON object")
                }
                base = object
                continue
            }
            let key = String(flag.dropFirst(2)).replacingOccurrences(of: "-", with: "_")
            guard let schema = properties[key] else { throw UsageError("unknown option \(flag)") }
            let raw: String
            if parts.count > 1 {
                raw = parts[1]
            } else if schema["type"]?.string == "boolean" {
                raw = rest.first.flatMap { ["true", "false"].contains($0) ? rest.popFirst() : nil } ?? "true"
            } else {
                raw = try value(after: flag, in: &rest)
            }
            flagged[key] = try parse(raw, as: schema, appendingTo: flagged[key], flag: flag)
        }
        let unfilled = required.filter { flagged[$0] == nil && base[$0] == nil }
        guard positional.count <= unfilled.count else { throw UsageError("unexpected argument '\(positional[unfilled.count])'") }
        for (key, raw) in zip(unfilled, positional) {
            flagged[key] = try parse(raw, as: properties[key] ?? [:], appendingTo: nil, flag: flagName(key))
        }
        let values = base.merging(flagged) { $1 }
        if let missing = required.first(where: { values[$0] == nil }) { throw UsageError("missing \(flagName(missing))") }
        return .object(values)
    }

    private static func value(after flag: String, in rest: inout ArraySlice<String>) throws -> String {
        guard let value = rest.popFirst() else { throw UsageError("\(flag) needs a value") }
        return value
    }

    private static func parse(_ raw: String, as schema: JSONValue, appendingTo existing: JSONValue?, flag: String) throws -> JSONValue {
        switch schema["type"]?.string {
        case "integer":
            guard let n = Int64(raw) else { throw UsageError("\(flag) needs a whole number, not '\(raw)'") }
            return .int(n)
        case "number":
            guard let n = Double(raw) else { throw UsageError("\(flag) needs a number, not '\(raw)'") }
            return .double(n)
        case "boolean":
            guard let b = Bool(raw) else { throw UsageError("\(flag) is true or false, not '\(raw)'") }
            return .bool(b)
        case "array":
            let item = try parse(raw, as: schema["items"] ?? [:], appendingTo: nil, flag: flag)
            return .array((existing?.array ?? []) + [item])
        default:
            return .string(raw)
        }
    }

    private static func flagName(_ key: String) -> String {
        "--" + key.replacingOccurrences(of: "_", with: "-")
    }

    // MARK: Help

    static func usage(for tool: AgentTools.Tool) -> String {
        let properties = tool.inputSchema["properties"]?.object ?? [:]
        let required = tool.inputSchema["required"]?.array?.compactMap(\.string) ?? []
        let optional = properties.keys.filter { !required.contains($0) }.sorted()
        let synopsis = (["usage: jetline \(commandName(tool))"]
            + required.map { "<\($0.replacingOccurrences(of: "_", with: "-"))>" }
            + optional.map { "[\(flagName($0)) \(placeholder(properties[$0]))]" })
            .joined(separator: " ")
        let flags = (required + optional).map { key in
            let label = "\(flagName(key)) \(placeholder(properties[key]))"
            let padded = label.padding(toLength: max(label.count, 26), withPad: " ", startingAt: 0)
            return "  \(padded)  \(properties[key]?["description"]?.string ?? "")"
        }
        return ([synopsis, "", tool.description] + (flags.isEmpty ? [] : [""] + flags)).joined(separator: "\n")
    }

    static var overview: String {
        func rows(_ tools: [AgentTools.Tool]) -> [String] {
            tools.map { "  \(commandName($0).padding(toLength: 20, withPad: " ", startingAt: 0))\(summary($0.description))" }
        }
        return ([
            "usage: jetline <tool> [--flag value …]      jetline <tool> --help for its flags",
            "",
            "Jetline's agent tools, run as the workspace holding the current directory.",
            "Output is JSON; --json '{…}' passes the arguments as one object.",
            "",
            "Read:"
        ] + rows(AgentTools.catalog.filter(\.readOnly)) + ["", "Change:"] + rows(AgentTools.catalog.filter { !$0.readOnly }))
            .joined(separator: "\n")
    }

    private static func commandName(_ tool: AgentTools.Tool) -> String {
        tool.name.replacingOccurrences(of: "_", with: "-")
    }

    private static func placeholder(_ schema: JSONValue?) -> String {
        switch schema?["type"]?.string {
        case "integer", "number": return "N"
        case "boolean": return "true|false"
        case "array": return "VALUE…"
        default: return "VALUE"
        }
    }

    /// A description's first sentence.
    private static func summary(_ description: String) -> String {
        let sentence = description.components(separatedBy: ". ").first ?? description
        return sentence.hasSuffix(".") ? String(sentence.dropLast()) : sentence
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("jetline: \(message)\n".utf8))
        exit(1)
    }
}

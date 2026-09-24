import Foundation

/// An MCP elicitation Codex sends to approve an MCP or connector tool
/// call. The approval choices are encoded in a JSON-schema form whose
/// field and option names say what they mean ("Allow for this session",
/// a boolean `persist`, ...). Ported from T3 Code's
/// `describeMcpElicitation` / `toMcpElicitationResponse`.
struct CodexElicitation {
    let params: JSONValue

    private var meta: JSONValue? { params["_meta"] }

    var appName: String {
        let candidates: [String?] = [
            meta?["app_name"]?.string, meta?["appName"]?.string, meta?["app"]?.string,
            meta?["target"]?["app"]?.string, meta?["target"]?["name"]?.string,
            meta?["tool_params"]?["app_name"]?.string, meta?["tool_params"]?["app"]?.string,
            Self.appFromMessage(params["message"]?.string),
            meta?["connector_name"]?.string, meta?["connectorName"]?.string,
            params["serverName"]?.string
        ]
        return candidates.compactMap { $0?.nonBlank }.first ?? "this tool"
    }

    var offersSessionScope: Bool {
        let persist = meta?["persist"]
        let values = persist?.string.map { [$0] } ?? persist?.array?.compactMap(\.string) ?? []
        if values.contains(where: { Self.persistence($0) == .session }) {
            return response(for: .allowForSession)["action"]?.string == "accept"
        }
        for (key, field) in formFields {
            if Self.options(field).contains(where: { Self.persistence($0.value) == .session }) { return true }
            if Self.persistence(key) == .session { return true }
        }
        return false
    }

    func response(for decision: AgentApprovalDecision) -> JSONValue {
        let persist: String?
        switch decision {
        case .deny: return ["action": "decline", "content": nil, "_meta": nil]
        case .cancel: return ["action": "cancel", "content": nil, "_meta": nil]
        case .allowOnce: persist = nil
        case .allowForSession: persist = "session"
        }
        if params["mode"]?.string == "url" { return ["action": "decline", "content": nil, "_meta": nil] }

        var content: [String: JSONValue] = [:]
        for (key, field) in formFields {
            let options = Self.options(field)
            let chosen = options.first { option in
                if persist != nil { return Self.persistence(option.value) == .session }
                return option.value.range(of: "once|accept|approve|allow", options: [.regularExpression, .caseInsensitive]) != nil
                    && Self.persistence(option.value) == nil
            }
            if let chosen {
                content[key] = .string(chosen.value)
            } else if field["type"]?.string == "boolean", Self.isPersistenceField(key, field) {
                content[key] = false
            } else if let value = field["default"], !value.isNull {
                content[key] = value
            }
        }
        let required = params["requestedSchema"]?["required"]?.array?.compactMap(\.string) ?? []
        if required.contains(where: { content[$0] == nil }) {
            return ["action": "decline", "content": nil, "_meta": nil]
        }
        return [
            "action": "accept",
            "content": .object(content),
            "_meta": persist.map { ["persist": .string($0)] } ?? nil
        ]
    }

    // MARK: Helpers

    private enum Persistence { case session, always }

    private var formFields: [(String, JSONValue)] {
        guard params["mode"]?.string != "url",
              let properties = params["requestedSchema"]?["properties"]?.object else { return [] }
        return properties.sorted { $0.key < $1.key }
    }

    private static func persistence(_ value: String) -> Persistence? {
        let lower = value.lowercased()
        if lower.contains("session") { return .session }
        if ["always", "permanent", "forever", "persistent"].contains(where: lower.contains) { return .always }
        return nil
    }

    private static func isPersistenceField(_ key: String, _ field: JSONValue) -> Bool {
        persistence(key) != nil || key.lowercased() == "persist"
            || persistence(field["title"]?.string ?? "") != nil
            || persistence(field["description"]?.string ?? "") != nil
    }

    private static func options(_ field: JSONValue) -> [(value: String, label: String?)] {
        if let oneOf = field["oneOf"]?.array {
            return oneOf.compactMap { option in
                option["const"]?.string.map { ($0, option["title"]?.string) }
            }
        }
        let names = field["enumNames"]?.array?.map(\.string) ?? []
        return (field["enum"]?.array ?? []).enumerated().compactMap { index, value in
            value.string.map { ($0, index < names.count ? names[index] : nil) }
        }
    }

    private static func appFromMessage(_ message: String?) -> String? {
        guard let message,
              let match = message.range(of: #"^Allow ChatGPT to use (.+?)\?$"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        let text = String(message[match])
        return text.replacingOccurrences(of: #"^Allow ChatGPT to use "#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "?", with: "")
    }
}

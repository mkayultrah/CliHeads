import Foundation

/// A byte-oriented NDJSON reader. Buffer bytes rather than Strings so split UTF-8 scalars survive.
struct JSONLineBuffer {
    private var pending = Data()
    private let maximumLineBytes = 8 * 1024 * 1024

    mutating func append(_ chunk: Data) -> [String] {
        pending.append(chunk)
        var lines: [String] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = Data(pending[..<newline])
            pending.removeSubrange(...newline)
            if let string = String(data: line, encoding: .utf8), !string.isEmpty {
                lines.append(string)
            }
        }
        if pending.count > maximumLineBytes {
            pending.removeAll(keepingCapacity: true)
            lines.append("{\"type\":\"cliheads_line_too_long\"}")
        }
        return lines
    }
}

/// A tool use waiting on the user, from Claude Code's `--permission-prompt-tool stdio`.
struct PermissionPrompt: Identifiable, Equatable {
    let id: String            // control request_id
    let tool: String
    let summary: String
    let inputJSON: String
    let suggestionsJSON: String?
    /// Raw tool_name from the CLI (tool above may be a display name).
    var toolName: String = ""
}

enum ClaudeEvent: Equatable {
    case sessionID(String)
    case textBlockStart
    case textDelta(String)
    case thinkingBlockStart
    case thinkingDelta(String)
    case thinkingSnapshot(String)
    case systemNotice(String)
    case permissionRequest(PermissionPrompt)
    case unsupportedControl(id: String, subtype: String)
    /// From system init: the starting permission mode and the slash commands that work headless.
    case sessionInfo(mode: String?, commands: [String])
    /// The CLI changed permission mode (shift+tab from us, or ExitPlanMode).
    case permissionMode(String)
    /// Reply to a control request we sent. `error` is nil on success.
    case controlResult(id: String, error: String?)
    case assistantSnapshot(String)
    case toolUse(String)
    case toolResult(String)
    case finished(text: String?, isError: Bool)
    case error(String)
}

/// Makes only narrowly defined assumptions about Claude Code's evolving stream-json output.
/// Unknown records are ignored; protocol errors remain visible in the diagnostics pane.
enum ClaudeProtocol {
    static func inputLine(_ text: String, images: [(mediaType: String, data: Data)] = []) throws -> Data {
        var content: [[String: Any]] = images.map {
            ["type": "image", "source": ["type": "base64", "media_type": $0.mediaType,
                                         "data": $0.data.base64EncodedString()]]
        }
        if !text.isEmpty || content.isEmpty { content.append(["type": "text", "text": text]) }
        let object: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": content]
        ]
        return try line(object)
    }

    /// Stops the current turn, like Esc in the CLI. The CLI answers with an error result.
    static func interruptLine(id: String) throws -> Data {
        try line(["type": "control_request", "request_id": id, "request": ["subtype": "interrupt"]])
    }

    /// Reply to a can_use_tool request. `always` applies the CLI's own suggested rules.
    static func permissionLine(_ prompt: PermissionPrompt, allow: Bool, always: Bool = false,
                               denyMessage: String? = nil) throws -> Data {
        var decision: [String: Any]
        if allow {
            let input = (prompt.inputJSON.data(using: .utf8)).flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? [String: Any]()
            decision = ["behavior": "allow", "updatedInput": input]
            if always, let raw = prompt.suggestionsJSON?.data(using: .utf8),
               let suggestions = try? JSONSerialization.jsonObject(with: raw) as? [Any], !suggestions.isEmpty {
                decision["updatedPermissions"] = suggestions
            }
        } else {
            decision = ["behavior": "deny", "message": denyMessage ?? "The user denied this tool use. Ask them what to do instead."]
        }
        return try line(["type": "control_response",
                         "response": ["subtype": "success", "request_id": prompt.id, "response": decision]])
    }

    /// Same as shift+tab in the CLI: switch permission mode on the running process.
    static func setModeLine(id: String, mode: String) throws -> Data {
        try line(["type": "control_request", "request_id": id,
                  "request": ["subtype": "set_permission_mode", "mode": mode]])
    }

    static func controlErrorLine(id: String, message: String) throws -> Data {
        try line(["type": "control_response",
                  "response": ["subtype": "error", "request_id": id, "error": message]])
    }

    private static func line(_ object: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed])
        data.append(0x0A)
        return data
    }

    /// Short, readable description of what a tool wants to do.
    static func describe(tool: String, input: [String: Any], description: String?) -> String {
        if let command = input["command"] as? String { return command }
        if let path = input["file_path"] as? String ?? input["notebook_path"] as? String ?? input["path"] as? String {
            return path
        }
        if let url = input["url"] as? String { return url }
        if let pattern = input["pattern"] as? String { return pattern }
        if let plan = input["plan"] as? String { return plan }
        if let description, !description.isEmpty { return description }
        let data = (try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])) ?? Data()
        return String((String(data: data, encoding: .utf8) ?? "").prefix(400))
    }

    static func parse(_ line: String) -> [ClaudeEvent] {
        guard let data = line.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = object["type"] as? String else { return [] }
        var events: [ClaudeEvent] = []
        if let sid = object["session_id"] as? String, !sid.isEmpty {
            events.append(.sessionID(sid))
        }

        switch type {
        case "stream_event":
            // Subagent output carries a parent_tool_use_id; keep the chat to the main thread.
            if let parent = object["parent_tool_use_id"] as? String, !parent.isEmpty { break }
            guard let event = object["event"] as? [String: Any] else { break }
            if event["type"] as? String == "content_block_start",
               let block = event["content_block"] as? [String: Any] {
                switch block["type"] as? String {
                case "text": events.append(.textBlockStart)
                case "thinking": events.append(.thinkingBlockStart)
                default: break
                }
                break
            }
            guard event["type"] as? String == "content_block_delta",
                  let delta = event["delta"] as? [String: Any] else { break }
            switch delta["type"] as? String {
            case "text_delta":
                if let text = delta["text"] as? String { events.append(.textDelta(text)) }
            case "thinking_delta":
                if let text = delta["thinking"] as? String, !text.isEmpty { events.append(.thinkingDelta(text)) }
            default: break
            }
        case "assistant":
            if let parent = object["parent_tool_use_id"] as? String, !parent.isEmpty { break }
            guard let message = object["message"] as? [String: Any],
                  let blocks = message["content"] as? [[String: Any]] else { break }
            let thoughts = blocks.compactMap { block -> String? in
                guard block["type"] as? String == "thinking" else { return nil }
                return block["thinking"] as? String
            }.filter { !$0.isEmpty }
            if !thoughts.isEmpty { events.append(.thinkingSnapshot(thoughts.joined(separator: "\n\n"))) }
            let texts = blocks.compactMap { block -> String? in
                guard block["type"] as? String == "text" else { return nil }
                return block["text"] as? String
            }
            if !texts.isEmpty { events.append(.assistantSnapshot(texts.joined(separator: "\n"))) }
            for block in blocks where block["type"] as? String == "tool_use" {
                events.append(.toolUse(block["name"] as? String ?? "Tool"))
            }
        case "user":
            if let blocks = (object["message"] as? [String: Any])?["content"] as? [[String: Any]] {
                for block in blocks where block["type"] as? String == "tool_result" {
                    events.append(.toolResult("Tool finished"))
                }
            }
        case "system":
            let subtype = object["subtype"] as? String
            if subtype == "init" {
                let terminalOnly = Set(object["terminal_slash_commands"] as? [String] ?? [])
                let commands = (object["slash_commands"] as? [String] ?? []).filter {
                    !terminalOnly.contains($0) && !$0.hasPrefix("__")
                }
                events.append(.sessionInfo(mode: object["permissionMode"] as? String, commands: commands))
                break
            }
            if subtype == "status", let mode = object["permissionMode"] as? String {
                events.append(.permissionMode(mode)); break
            }
            guard subtype == "informational",
                  var text = object["content"] as? String else { break }
            // Hook replies arrive as "X operation blocked by hook:\n<reason>".
            if let range = text.range(of: "blocked by hook:") {
                text = String(text[range.upperBound...])
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { events.append(.systemNotice(text)) }
        case "control_request":
            guard let id = object["request_id"] as? String,
                  let request = object["request"] as? [String: Any] else { break }
            let subtype = request["subtype"] as? String ?? ""
            guard subtype == "can_use_tool" else {
                events.append(.unsupportedControl(id: id, subtype: subtype)); break
            }
            let tool = request["display_name"] as? String ?? request["tool_name"] as? String ?? "Tool"
            let input = request["input"] as? [String: Any] ?? [:]
            let inputData = (try? JSONSerialization.data(withJSONObject: input)) ?? Data("{}".utf8)
            var suggestions: String?
            if let list = request["permission_suggestions"] as? [Any], !list.isEmpty,
               let data = try? JSONSerialization.data(withJSONObject: list) {
                suggestions = String(data: data, encoding: .utf8)
            }
            events.append(.permissionRequest(PermissionPrompt(
                id: id, tool: tool,
                summary: describe(tool: tool, input: input, description: request["description"] as? String),
                inputJSON: String(data: inputData, encoding: .utf8) ?? "{}",
                suggestionsJSON: suggestions,
                toolName: request["tool_name"] as? String ?? "")))
        case "control_response":
            guard let response = object["response"] as? [String: Any],
                  let id = response["request_id"] as? String else { break }
            let failed = response["subtype"] as? String == "error"
            events.append(.controlResult(id: id, error: failed ? (response["error"] as? String ?? "failed") : nil))
        case "result":
            events.append(.finished(text: object["result"] as? String,
                                    isError: object["is_error"] as? Bool ?? false))
        case "cliheads_line_too_long":
            events.append(.error("CLI produced an oversized output record"))
        default:
            break
        }
        return events
    }
}

/// Claude Code permission modes, cycled with shift+tab like the CLI.
enum PermissionMode: String, CaseIterable {
    case `default`, acceptEdits, plan, auto, bypassPermissions, dontAsk

    static let cycle: [PermissionMode] = [.default, .acceptEdits, .plan, .auto, .bypassPermissions]

    var label: String {
        switch self {
        case .default: return ""
        case .acceptEdits: return "⏵⏵ accept edits on"
        case .plan: return "⏸ plan mode on"
        case .auto: return "⏵⏵ auto mode on"
        case .bypassPermissions: return "⏵⏵ bypass permissions on"
        case .dontAsk: return "⏵⏵ don't ask mode on"
        }
    }

    var title: String {
        switch self {
        case .default: return "default mode"
        case .acceptEdits: return "accept edits"
        case .plan: return "plan mode"
        case .auto: return "auto mode"
        case .bypassPermissions: return "bypass permissions"
        case .dontAsk: return "don't ask mode"
        }
    }

    func next(skipping unavailable: Set<PermissionMode>, in available: [PermissionMode] = cycle) -> PermissionMode {
        let modes = available.filter { !unavailable.contains($0) || $0 == self }
        guard let index = modes.firstIndex(of: self) else { return .default }
        return modes[(index + 1) % modes.count]
    }
}

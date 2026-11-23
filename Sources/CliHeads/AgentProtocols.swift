import Foundation

/// An image the user attached, already written to disk so file based CLIs can read it.
struct PromptImage: Equatable {
    var path: String
    var mediaType: String
    var data: Data
}

/// Each provider keeps its own documented CLI wire format. No API keys or private APIs.
enum AgentProvider: String, Codable, CaseIterable, Identifiable {
    case claude, codex, gemini, grok
    var id: String { rawValue }
    var title: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .gemini: return "Gemini CLI"
        case .grok: return "Grok"
        }
    }
    var executable: String { rawValue }
    var accent: String { rawValue }
    var supportsPersistentStdin: Bool { self == .claude }
    /// CLIs that let us pick the session UUID up front, so the chat can resume before the first reply.
    var choosesSessionID: Bool { self == .claude || self == .grok }

    /// The permission modes shift+tab cycles through, mapped to each CLI's own flags.
    var modes: [PermissionMode] {
        switch self {
        case .claude: return PermissionMode.cycle
        case .codex: return [.default, .acceptEdits, .bypassPermissions]
        case .gemini: return [.default, .acceptEdits, .plan, .bypassPermissions]
        case .grok: return [.default, .acceptEdits, .plan, .auto, .bypassPermissions]
        }
    }

    func arguments(prompt: String?, sessionID: String?, newSession: Bool = false,
                   mode: PermissionMode = .default, images: [PromptImage] = []) -> [String] {
        let id = sessionID.flatMap { $0.isEmpty ? nil : $0 }
        let text = prompt ?? ""
        switch self {
        case .claude:
            var a = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                     // Tool approvals come back to us as control requests, and thinking
                     // arrives as readable summaries instead of being omitted.
                     "--permission-prompt-tool", "stdio", "--thinking-display", "summarized",
                     // Lets shift+tab reach bypass permissions, same as the CLI when allowed.
                     "--allow-dangerously-skip-permissions"]
            if let id { a += newSession ? ["--session-id", id] : ["--resume", id] }
            return a
        case .codex:
            var a = id == nil ? ["exec"] : ["exec", "resume"]
            a += ["--json", "--skip-git-repo-check", "-c", "model_reasoning_summary=detailed"]
            switch mode {
            case .bypassPermissions: a.append("--dangerously-bypass-approvals-and-sandbox")
            case .acceptEdits, .auto: a += ["-c", "sandbox_mode=\"workspace-write\""]
            default: a += ["-c", "sandbox_mode=\"read-only\""]
            }
            // --image is variadic, so pin each value with = and end options with --.
            a += images.map { "--image=\($0.path)" }
            a.append("--")
            if let id { a.append(id) }
            a.append(text)
            return a
        case .gemini:
            var a = ["--output-format", "stream-json"]
            switch mode {
            case .acceptEdits, .auto: a += ["--approval-mode", "auto_edit"]
            case .plan: a += ["--approval-mode", "plan"]
            case .bypassPermissions: a += ["--approval-mode", "yolo"]
            default: break
            }
            if let id { a += ["--resume", id] }
            // Gemini only reads files inside its workspace, so add the image folder to it.
            let folders = Set(images.map { ($0.path as NSString).deletingLastPathComponent })
            for folder in folders.sorted() { a += ["--include-directories", folder] }
            // Gemini reads files referenced with @path inside the prompt.
            let refs = images.map { " @" + $0.path.replacingOccurrences(of: " ", with: "\\ ") }.joined()
            // Attached with = so a prompt starting with "-" isn't read as a flag.
            a.append("--prompt=" + text + refs)
            return a
        case .grok:
            var a: [String]
            if images.isEmpty {
                a = ["--single=" + text]
            } else {
                var blocks: [[String: String]] = [["type": "text", "text": text]]
                blocks += images.map { ["type": "image", "data": $0.data.base64EncodedString(), "mimeType": $0.mediaType] }
                let json = (try? JSONSerialization.data(withJSONObject: blocks)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
                a = ["--prompt-json", json]
            }
            a += ["--output-format", "streaming-messages-json", "--include-partial-messages"]
            if mode != .default { a += ["--permission-mode", mode.rawValue] }
            if let id { a += newSession ? ["--session-id", id] : ["--resume", id] }
            return a
        }
    }

    func parse(_ line: String) -> [ClaudeEvent] {
        switch self {
        case .claude, .grok: return ClaudeProtocol.parse(line)
        case .codex: return CodexProtocol.parse(line)
        case .gemini: return GeminiProtocol.parse(line)
        }
    }
}

/// Official Codex `exec --json` NDJSON: thread.started, item.* and turn.*.
enum CodexProtocol {
    static func parse(_ line: String) -> [ClaudeEvent] {
        guard let obj = jsonObject(line), let type = obj["type"] as? String else { return [] }
        switch type {
        case "thread.started":
            if let id = obj["thread_id"] as? String { return [.sessionID(id)] }
        case "item.started", "item.updated", "item.completed":
            if let item = obj["item"] as? [String: Any] {
                let kind = item["type"] as? String ?? ""
                // Codex emits progressive item.updated snapshots before item.completed.
                // Display them immediately instead of appearing frozen until turn end.
                if kind == "reasoning", type == "item.completed",
                   let text = (item["text"] as? String) ?? (item["summary"] as? String), !text.isEmpty {
                    return [.thinkingBlockStart, .thinkingDelta(text)]
                }
                if kind == "agent_message", let text = item["text"] as? String,
                   (type == "item.updated" || type == "item.completed") {
                    return [.assistantSnapshot(text)]
                }
                if type == "item.started", ["command_execution", "file_change", "web_search", "mcp_tool_call"].contains(kind) {
                    return [.toolUse(kind.replacingOccurrences(of: "_", with: " "))]
                }
            }
        case "turn.completed": return [.finished(text: nil, isError: false)]
        case "turn.failed":
            let message = errorDescription(obj)
            return [.error(message), .finished(text: message, isError: true)]
        case "error": return [.error(errorDescription(obj))]
        default: break
        }
        return []
    }
}

/// Gemini CLI `--output-format stream-json`. The CLI exits after each prompt;
/// subsequent prompts use `--resume <session UUID>` to preserve context.
enum GeminiProtocol {
    static func parse(_ line: String) -> [ClaudeEvent] {
        guard let obj = jsonObject(line), let type = obj["type"] as? String else { return [] }
        switch type {
        case "init":
            if let id = obj["session_id"] as? String { return [.sessionID(id)] }
        case "message":
            guard (obj["role"] as? String) == "assistant", let content = obj["content"] as? String else { return [] }
            return (obj["delta"] as? Bool ?? false) ? [.textDelta(content)] : [.assistantSnapshot(content)]
        case "tool_use": return [.toolUse(obj["tool_name"] as? String ?? obj["name"] as? String ?? "Tool")]
        case "tool_result": return [.toolResult("Tool finished")]
        case "result":
            let err = (obj["status"] as? String) == "error" || (obj["is_error"] as? Bool ?? false)
            var text = obj["response"] as? String
            if err, text == nil, obj["error"] != nil { text = errorDescription(obj) }
            return [.finished(text: text, isError: err)]
        case "error":
            // Warnings are noise for the chat; keep them in Events only.
            let message = errorDescription(obj)
            return (obj["severity"] as? String) == "warning" ? [.error("warning: " + message)] : [.error(message)]
        default: break
        }
        return []
    }
}

private func jsonObject(_ line: String) -> [String: Any]? {
    guard let d = line.data(using: .utf8) else { return nil }
    return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
}

private func errorDescription(_ object: [String: Any]) -> String {
    if let text = object["message"] as? String { return text }
    if let nested = object["error"] as? [String: Any], let text = nested["message"] as? String { return text }
    return "The agent reported an error"
}

import Foundation

/// The `/` command list for the chat composer. Names come from the CLI itself
/// (system init lists every command that works headless), cached between launches.
enum SlashCommands {
    struct Command: Identifiable, Equatable {
        let name: String
        let detail: String
        var id: String { name }
    }

    /// Handled by the chat head itself rather than sent to the CLI.
    static let native = ["resume", "clear"]

    private static let cacheKey = "claudeSlashCommands"

    private static let details: [String: String] = [
        "resume": "Resume a past conversation",
        "continue": "Resume a past conversation",
        "clear": "Start a new conversation",
        "new": "Start a new conversation",
        "compact": "Summarise the chat to free up context",
        "context": "Show context usage",
        "cost": "Show cost and duration of this session",
        "usage": "Show plan usage limits",
        "model": "Set the model",
        "effort": "Set thinking effort",
        "fast": "Toggle fast mode",
        "rename": "Rename this conversation",
        "init": "Create a CLAUDE.md for this project",
        "memory": "Edit memory files",
        "config": "Open settings",
        "status": "Show version, model and account",
        "mcp": "Manage MCP servers",
        "agents": "Manage subagents",
        "skills": "List available skills",
        "hooks": "Manage hooks",
        "permissions": "Manage allow and deny rules",
        "plugin": "Manage plugins",
        "code-review": "Review the current changes",
        "review": "Review a pull request",
        "security-review": "Security review of pending changes",
        "simplify": "Clean up the changed code",
        "pr-comments": "Get comments from a pull request",
        "add-dir": "Add a working directory",
        "export": "Export the conversation",
        "release-notes": "Show release notes",
        "todos": "List current todos",
        "help": "Show help",
        "login": "Sign in to an Anthropic account",
        "logout": "Sign out",
        "doctor": "Check the install (Full CLI only)",
    ]

    /// Used until the CLI has told us its real list.
    private static let fallback = ["compact", "context", "cost", "usage", "model", "effort", "fast",
                                   "rename", "init", "memory", "config", "status", "mcp", "agents",
                                   "skills", "hooks", "permissions", "code-review", "review",
                                   "security-review", "simplify", "add-dir", "export", "help"]

    static func remember(_ names: [String]) {
        guard !names.isEmpty else { return }
        UserDefaults.standard.set(names, forKey: cacheKey)
    }

    /// Other CLIs only run their slash commands in the full TUI, so they get the chat head's own.
    static func all(for provider: AgentProvider = .claude) -> [Command] {
        let names: [String]
        if provider == .claude {
            names = native + (UserDefaults.standard.stringArray(forKey: cacheKey) ?? fallback)
        } else {
            names = ["resume", "clear", "new"]
        }
        var seen = Set<String>()
        return names.compactMap { name in
            guard seen.insert(name).inserted else { return nil }
            return Command(name: name, detail: details[name] ?? "")
        }
    }

    /// Suggestions for a draft like "/re". Nil once the draft stops being a bare command.
    static func suggestions(for draft: String, provider: AgentProvider = .claude, limit: Int = 6) -> [Command]? {
        guard draft.hasPrefix("/"), !draft.contains(" "), !draft.contains("\n") else { return nil }
        let query = draft.dropFirst().lowercased()
        let commands = all(for: provider)
        if query.isEmpty { return Array(commands.prefix(limit)) }
        // An exact name goes first, then the other prefix matches.
        let prefix = commands.filter { $0.name.lowercased().hasPrefix(query) }
            .sorted { ($0.name.lowercased() == query ? 0 : 1) < ($1.name.lowercased() == query ? 0 : 1) }
        let contains = commands.filter {
            !$0.name.lowercased().hasPrefix(query) &&
            ($0.name.lowercased().contains(query) || $0.detail.lowercased().contains(query))
        }
        let result = Array((prefix + contains).prefix(limit))
        // An exact, complete command needs no list.
        if result.count == 1, result[0].name.lowercased() == query { return nil }
        return result.isEmpty ? nil : result
    }
}

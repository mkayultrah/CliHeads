import Foundation

func must(_ condition: @autoclosure () -> Bool, _ description: String) {
    precondition(condition(), "FAILED: \(description)")
    print("PASS \(description)")
}

@main
struct AgentTests {
    static func main() throws {
        let claudeArgs = AgentProvider.claude.arguments(prompt: "hello", sessionID: "abc", newSession: true)
        must(claudeArgs.suffix(2) == ["--session-id", "abc"], "New Claude chats get explicit session IDs")
        let resumed = AgentProvider.claude.arguments(prompt: "test", sessionID: "xyz")
        must(resumed.suffix(2) == ["--resume", "xyz"], "Claude uses exact resume ID")
        let codexBase = ["--json", "--skip-git-repo-check", "-c", "model_reasoning_summary=detailed"]
        must(AgentProvider.codex.arguments(prompt: "continue", sessionID: "42") == ["exec", "resume"] + codexBase + ["-c", "sandbox_mode=\"read-only\"", "--", "42", "continue"], "Codex resume command")
        let img = PromptImage(path: "/tmp/a b.png", mediaType: "image/png", data: Data([1, 2]))
        must(AgentProvider.codex.arguments(prompt: "-look", sessionID: nil, mode: .acceptEdits, images: [img]) == ["exec"] + codexBase + ["-c", "sandbox_mode=\"workspace-write\"", "--image=/tmp/a b.png", "--", "-look"], "Codex new turn with image and edits")
        must(AgentProvider.codex.arguments(prompt: "go", sessionID: nil, mode: .bypassPermissions).contains("--dangerously-bypass-approvals-and-sandbox"), "Codex bypass")
        must(AgentProvider.gemini.arguments(prompt: "hi", sessionID: nil, mode: .plan, images: [img]) == ["--output-format", "stream-json", "--approval-mode", "plan", "--include-directories", "/tmp", "--prompt=hi @/tmp/a\\ b.png"], "Gemini plan mode and image ref")
        must(AgentProvider.grok.arguments(prompt: "hi", sessionID: "g1", newSession: true) == ["--single=hi", "--output-format", "streaming-messages-json", "--include-partial-messages", "--session-id", "g1"], "Grok new session")
        let grokResume = AgentProvider.grok.arguments(prompt: "again", sessionID: "g1", mode: .acceptEdits, images: [img])
        must(grokResume.first == "--prompt-json" && grokResume.suffix(4) == ["--permission-mode", "acceptEdits", "--resume", "g1"], "Grok resume with image and mode")
        must(PermissionMode.default.next(skipping: [], in: AgentProvider.codex.modes) == .acceptEdits
             && PermissionMode.bypassPermissions.next(skipping: [], in: AgentProvider.codex.modes) == .default, "Codex mode cycle")
        must(CodexProtocol.parse("{\"type\":\"item.completed\",\"item\":{\"type\":\"reasoning\",\"text\":\"hmm\"}}") == [.thinkingBlockStart, .thinkingDelta("hmm")], "Codex reasoning shows as thinking")
        must(GeminiProtocol.parse("{\"type\":\"result\",\"status\":\"error\",\"error\":{\"message\":\"Operation cancelled.\"}}") == [.finished(text: "Operation cancelled.", isError: true)], "Gemini result error")
        must(AgentProvider.gemini.arguments(prompt: "continue", sessionID: "42") == ["--output-format", "stream-json", "--resume", "42", "--prompt=continue"], "Gemini resume command")
        must(CodexProtocol.parse("{\"type\":\"thread.started\",\"thread_id\":\"aabb\"}") == [.sessionID("aabb")], "Codex session ID captured")
        must(CodexProtocol.parse("{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"hello\"}}") == [.assistantSnapshot("hello")], "Codex reply parsed")
        must(CodexProtocol.parse("{\"type\":\"item.updated\",\"item\":{\"type\":\"agent_message\",\"text\":\"hel\"}}") == [.assistantSnapshot("hel")], "Codex progressive reply displayed before completion")
        must(CodexProtocol.parse("{\"type\":\"turn.completed\"}") == [.finished(text: nil, isError: false)], "Codex turn completion")
        must(GeminiProtocol.parse("{\"type\":\"init\",\"session_id\":\"aabb\"}") == [.sessionID("aabb")], "Gemini session ID")
        must(GeminiProtocol.parse("{\"type\":\"message\",\"role\":\"assistant\",\"content\":\"hi\",\"delta\":true}") == [.textDelta("hi")], "Gemini delta")
        must(GeminiProtocol.parse("{\"type\":\"result\",\"status\":\"success\"}") == [.finished(text: nil, isError: false)], "Gemini final response")
        must(GeminiProtocol.parse("{\"type\":\"error\",\"message\":\"oops\"}") == [.error("oops")], "Gemini error")

        // The old on-disk format MUST survive upgrade without losing location/history.
        let legacy = """
        [{"id":"A9DB4C56-8AB3-422D-A4AD-840A9B1F0A92","title":"Claude Code","directory":"/tmp","claudeSessionID":"old-id","messages":[],"x":-1280,"y":420}]
        """
        let old = try JSONDecoder().decode([SavedHead].self, from: Data(legacy.utf8))
        must(old.count == 1 && old[0].provider == .claude && old[0].agentSessionID == "old-id", "legacy claudeSessionID format migrates")
        must(old[0].x == -1280 && old[0].y == 420, "Existing monitor position survives")
        let roundTrip = try JSONDecoder().decode([SavedHead].self, from: JSONEncoder().encode(old))
        must(roundTrip[0].agentSessionID == "old-id", "Migrated ID persists")
        must(old[0].permissionMode == nil, "Old saves have no mode")
        let moded = SavedHead(title: "t", directory: "/tmp", provider: .claude, permissionMode: "bypassPermissions")
        let modedBack = try JSONDecoder().decode(SavedHead.self, from: JSONEncoder().encode(moded))
        must(modedBack.permissionMode == "bypassPermissions", "Permission mode persists")

        // Synthetic local transcripts; no real ~/.claude or ~/.codex files read by tests.
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("cliheads-tests-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: home) }
        let claudeRoot = home.appendingPathComponent(".claude/projects/myproject")
        let codexRoot = home.appendingPathComponent(".codex/sessions/2026/11/22")
        try fm.createDirectory(at: claudeRoot, withIntermediateDirectories: true)
        try fm.createDirectory(at: codexRoot, withIntermediateDirectories: true)
        let a = "0c880df5-1dbf-4f1b-a96d-c10bc187fcdb"
        let b = "1c880df5-1dbf-4f1b-a96d-c10bc187fcdb"
        let cwd = home.path
        let geminiRoot = home.appendingPathComponent(".gemini/tmp/abcdef/chats")
        try fm.createDirectory(at: geminiRoot, withIntermediateDirectories: true)
        try (cwd + "\n").write(to: geminiRoot.deletingLastPathComponent().appendingPathComponent(".project_root"), atomically: true, encoding: .utf8)
        let c = "2c880df5-1dbf-4f1b-a96d-c10bc187fcdb"
        let geminiJSON = """
        {"sessionId":"\(c)","messages":[{"type":"user","content":"Explain the problem"},{"type":"gemini","content":"Here's the answer"}]}
        """
        try geminiJSON.write(to: geminiRoot.appendingPathComponent("session-one.json"), atomically: true, encoding: .utf8)
        let lines = [
            "{\"type\":\"user\",\"cwd\":\"\(cwd)\",\"message\":{\"role\":\"user\",\"content\":\"Fix the build\"}}",
            "{\"type\":\"assistant\",\"cwd\":\"\(cwd)\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"Done.\"}]}}"
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: claudeRoot.appendingPathComponent("\(a).jsonl"), atomically: true, encoding: .utf8)
        let codex = [
            "{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(b)\",\"cwd\":\"\(cwd)\"}}",
            "{\"type\":\"event_msg\",\"payload\":{\"type\":\"user_message\",\"message\":\"Build the feature\"}}",
            "{\"type\":\"event_msg\",\"payload\":{\"type\":\"agent_message\",\"message\":\"Implemented.\"}}"
        ]
        try (codex.joined(separator: "\n") + "\n").write(to: codexRoot.appendingPathComponent("rollout-2026-11-22-\(b).jsonl"), atomically: true, encoding: .utf8)
        // Codex 0.17x writes item_completed records instead of user_message / agent_message.
        let d = "3c880df5-1dbf-4f1b-a96d-c10bc187fcdb"
        let codexNew = [
            "{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(d)\",\"cwd\":\"\(cwd)\"}}",
            "{\"type\":\"event_msg\",\"payload\":{\"type\":\"item_completed\",\"item\":{\"type\":\"UserMessage\",\"content\":[{\"type\":\"local_image\",\"path\":\"/x.png\"},{\"type\":\"text\",\"text\":\"What colour is it\"}]}}}",
            "{\"type\":\"event_msg\",\"payload\":{\"type\":\"item_completed\",\"item\":{\"type\":\"AgentMessage\",\"content\":[{\"type\":\"Text\",\"text\":\"Blue\"}]}}}"
        ]
        try (codexNew.joined(separator: "\n") + "\n").write(to: codexRoot.appendingPathComponent("rollout-2026-11-22-\(d).jsonl"), atomically: true, encoding: .utf8)
        // Gemini jsonl chats: {type: user|gemini, content: [{text}]}.
        let e = "4c880df5-1dbf-4f1b-a96d-c10bc187fcdb"
        let geminiLines = [
            "{\"sessionId\":\"\(e)\",\"projectHash\":\"abcdef\"}",
            "{\"type\":\"user\",\"content\":[{\"text\":\"Sort the imports\"}]}",
            "{\"type\":\"gemini\",\"content\":[{\"text\":\"Sorted\"}]}"
        ]
        try (geminiLines.joined(separator: "\n") + "\n").write(to: geminiRoot.appendingPathComponent("session-two.jsonl"), atomically: true, encoding: .utf8)
        // Grok: summary.json beside chat_history.jsonl; real prompts sit in <user_query>.
        let f = "5c880df5-1dbf-4f1b-a96d-c10bc187fcdb"
        let grokRoot = home.appendingPathComponent(".grok/sessions/x/\(f)")
        try fm.createDirectory(at: grokRoot, withIntermediateDirectories: true)
        try "{\"info\":{\"id\":\"\(f)\",\"cwd\":\"\(cwd)\"}}".write(to: grokRoot.appendingPathComponent("summary.json"), atomically: true, encoding: .utf8)
        let grokLines = [
            "{\"type\":\"system\",\"content\":\"You are a CLI\"}",
            "{\"type\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"<system-reminder>skills</system-reminder>\"}],\"synthetic_reason\":\"skills\"}",
            "{\"type\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"<user_info>mac</user_info>\"},{\"type\":\"text\",\"text\":\"<user_query>\\nRename the module\\n</user_query>\"}]}",
            "{\"type\":\"reasoning\",\"summary\":[{\"type\":\"summary_text\",\"text\":\"thinking\"}]}",
            "{\"type\":\"assistant\",\"content\":\"\",\"tool_calls\":[]}",
            "{\"type\":\"assistant\",\"content\":\"Renamed\"}"
        ]
        try (grokLines.joined(separator: "\n") + "\n").write(to: grokRoot.appendingPathComponent("chat_history.jsonl"), atomically: true, encoding: .utf8)
        let found = SessionCatalog.discover(home: cwd)
        must(found.count == 6, "Discover Claude, Codex, Gemini and Grok sessions")
        if let item = found.first(where: { $0.sessionID == d }) {
            must(item.title == "What colour is it" && SessionCatalog.recentHistory(item) == [TranscriptMessage(role: "user", text: "What colour is it"), TranscriptMessage(role: "assistant", text: "Blue")], "Codex new transcript format")
        } else { must(false, "Codex new format discovered") }
        if let item = found.first(where: { $0.sessionID == e }) {
            must(item.title == "Sort the imports" && SessionCatalog.recentHistory(item) == [TranscriptMessage(role: "user", text: "Sort the imports"), TranscriptMessage(role: "assistant", text: "Sorted")], "Gemini jsonl parts format")
        } else { must(false, "Gemini jsonl discovered") }
        if let item = found.first(where: { $0.provider == .grok }) {
            must(item.sessionID == f && item.title == "Rename the module", "Grok title from user_query")
            must(SessionCatalog.recentHistory(item) == [TranscriptMessage(role: "user", text: "Rename the module"), TranscriptMessage(role: "assistant", text: "Renamed")], "Grok transcript preview skips plumbing")
        } else { must(false, "Grok session discovered") }
        must(found.contains(where: { $0.provider == .claude && $0.sessionID == a && $0.title == "Fix the build" }), "Claude title and project parsed")
        must(found.contains(where: { $0.provider == .codex && $0.sessionID == b && $0.title == "Build the feature" }), "Codex title and project parsed")
        must(found.contains(where: { $0.provider == .gemini && $0.sessionID == c && $0.title == "Explain the problem" }), "Gemini project-root mapping and title")
        if let item = found.first(where: { $0.sessionID == c }) {
            must(SessionCatalog.recentHistory(item) == [TranscriptMessage(role: "user", text: "Explain the problem"), TranscriptMessage(role: "assistant", text: "Here's the answer")], "Gemini transcript preview")
        }
        if let item = found.first(where: { $0.provider == .claude }) {
            let preview = SessionCatalog.recentHistory(item)
            must(preview == [TranscriptMessage(role: "user", text: "Fix the build"), TranscriptMessage(role: "assistant", text: "Done.")], "Claude conversation preview")
        }
        print("All agent and session discovery tests passed")
    }
}

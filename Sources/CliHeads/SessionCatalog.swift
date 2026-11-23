import Foundation

/// Local-only, read-only discovery. Resumption is done by the actual CLI,
/// not by replaying conversation text back to the model.
struct DiscoveredSession: Identifiable, Equatable {
    let provider: AgentProvider
    let sessionID: String
    let title: String
    let directory: String
    let modified: Date
    let transcriptURL: URL
    var id: String { provider.rawValue + ":" + sessionID }
}

struct TranscriptMessage: Equatable {
    let role: String
    var text: String
}

struct SessionCatalog {
    /// Claude honours CLAUDE_CONFIG_DIR, so look there too when it's set.
    static func claudeConfigDirs(home: String = NSHomeDirectory()) -> [String] {
        var dirs = [home + "/.claude"]
        if home == NSHomeDirectory(), let custom = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"],
           !custom.isEmpty, !dirs.contains(custom) { dirs.append(custom) }
        return dirs
    }

    /// True once Claude has written a transcript for this session, so --resume will find it.
    static func hasClaudeTranscript(_ sessionID: String) -> Bool {
        let fm = FileManager.default
        for dir in claudeConfigDirs() {
            let projects = dir + "/projects"
            guard let folders = try? fm.contentsOfDirectory(atPath: projects) else { continue }
            if folders.contains(where: { fm.fileExists(atPath: projects + "/" + $0 + "/" + sessionID + ".jsonl") }) { return true }
        }
        return false
    }

    static func discover(home: String = NSHomeDirectory(), limit: Int = 150) -> [DiscoveredSession] {
        let fm = FileManager.default
        let claudeDirs = claudeConfigDirs(home: home)
        let sources: [(AgentProvider, String)] = claudeDirs.map { (.claude, $0 + "/projects") } + [
            (.codex, home + "/.codex/sessions"),
            (.gemini, home + "/.gemini/tmp"),
            (.grok, home + "/.grok/sessions")
        ]
        var results: [DiscoveredSession] = []
        for (provider, root) in sources {
            guard let walker = fm.enumerator(at: URL(fileURLWithPath: root),
                  includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                  options: [.skipsHiddenFiles], errorHandler: nil) else { continue }
            var files: [(URL, Date)] = []
            while let url = walker.nextObject() as? URL {
                if url.lastPathComponent == "subagents" { walker.skipDescendants(); continue }
                if provider == .grok {
                    guard url.lastPathComponent == "chat_history.jsonl" else { continue }
                } else if provider == .gemini {
                    guard ["jsonl", "json"].contains(url.pathExtension),
                          url.deletingLastPathComponent().lastPathComponent == "chats",
                          url.lastPathComponent.hasPrefix("session-") else { continue }
                } else {
                    guard url.pathExtension == "jsonl" else { continue }
                }
                let name = url.deletingPathExtension().lastPathComponent
                if provider == .claude && UUID(uuidString: name) == nil { continue }
                guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                      values.isRegularFile == true else { continue }
                files.append((url, values.contentModificationDate ?? .distantPast))
            }
            // Inspect only the most recent files; large session histories are common.
            for (url, modified) in files.sorted(by: { $0.1 > $1.1 }).prefix(limit) {
                if let entry = inspect(url, provider: provider, modified: modified) { results.append(entry) }
            }
        }
        // Older tools may leave duplicate transcript files. Keep latest.
        var byID: [String: DiscoveredSession] = [:]
        for item in results {
            if let old = byID[item.id], old.modified >= item.modified { continue }
            byID[item.id] = item
        }
        return byID.values.sorted { $0.modified > $1.modified }
    }

    /// Preview only the last portion of a local transcript. The native CLI
    /// remains the source of truth for actual conversation context.
    static func recentHistory(_ session: DiscoveredSession, limit: Int = 24) -> [TranscriptMessage] {
        if session.provider == .gemini && session.transcriptURL.pathExtension == "json" {
            guard let data = try? Data(contentsOf: session.transcriptURL),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let entries = object["messages"] as? [[String: Any]] else { return [] }
            return Array(entries.compactMap { item -> TranscriptMessage? in
                let kind = item["type"] as? String ?? item["role"] as? String ?? ""
                guard ["user", "gemini", "assistant"].contains(kind), let text = messageText(item["content"]), !text.isEmpty else { return nil }
                return TranscriptMessage(role: kind == "user" ? "user" : "assistant", text: String(text.prefix(12_000)))
            }.suffix(limit))
        }
        guard let handle = try? FileHandle(forReadingFrom: session.transcriptURL) else { return [] }
        defer { try? handle.close() }
        guard let length = try? handle.seekToEnd() else { return [] }
        let offset = length > 1_048_576 ? length - 1_048_576 : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd() else { return [] }
        let text = String(decoding: data, as: UTF8.self)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        // Discard the incomplete first record after seeking into the file.
        if offset > 0 && !lines.isEmpty { lines.removeFirst() }
        var history: [TranscriptMessage] = []
        for line in lines {
            guard let raw = line.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any],
                  let type = obj["type"] as? String else { continue }
            var item: TranscriptMessage?
            if session.provider == .claude {
                // Compaction summaries, meta records and subagent turns are CLI
                // plumbing, not things anyone actually typed or read in the chat.
                if (type == "assistant" || type == "user"),
                   obj["isCompactSummary"] as? Bool != true, obj["isMeta"] as? Bool != true,
                   obj["isSidechain"] as? Bool != true,
                   let message = obj["message"] as? [String: Any],
                   let body = messageText(message["content"]), !body.isEmpty, !isPlumbing(body) {
                    item = TranscriptMessage(role: type, text: body)
                }
            } else if session.provider == .gemini {
                // Newer Gemini writes {type: user|gemini, content: [{text}]}; older wrote stream style messages.
                if type == "message", let role = obj["role"] as? String,
                   (role == "user" || role == "assistant"),
                   let body = messageText(obj["content"]), !body.isEmpty,
                   (obj["delta"] as? Bool) != true {
                    item = TranscriptMessage(role: role, text: body)
                } else if type == "user" || type == "gemini",
                          let body = messageText(obj["content"]), !body.isEmpty {
                    item = TranscriptMessage(role: type == "user" ? "user" : "assistant", text: body)
                }
            } else if session.provider == .grok {
                if type == "user", obj["synthetic_reason"] == nil || obj["synthetic_reason"] is NSNull,
                   let body = grokQuery(obj["content"]) {
                    item = TranscriptMessage(role: "user", text: body)
                } else if type == "assistant", let body = messageText(obj["content"]), !body.isEmpty {
                    item = TranscriptMessage(role: "assistant", text: body)
                }
            } else {
                item = codexMessage(obj)
            }
            guard var entry = item else { continue }
            // Keep previews lightweight; full context still lives in CLI files.
            if entry.text.count > 12_000 { entry.text = String(entry.text.prefix(12_000)) + "…" }
            if let previous = history.last, previous.role == entry.role {
                if previous.text == entry.text { continue }
                // Claude sometimes records progressive assistant snapshots.
                if entry.role == "assistant" && entry.text.hasPrefix(previous.text) {
                    history[history.count - 1] = entry
                    continue
                }
            }
            history.append(entry)
            if history.count > limit * 3 { history.removeFirst(history.count - limit * 2) }
        }
        return Array(history.suffix(limit))
    }

    private static func inspect(_ url: URL, provider: AgentProvider, modified: Date) -> DiscoveredSession? {
        // FileHandle avoids importing an entire multi-gigabyte transcript.
        if provider == .gemini { return inspectGemini(url, modified: modified) }
        if provider == .grok { return inspectGrok(url, modified: modified) }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 512 * 1024) else { return nil }
        let str = String(decoding: data, as: UTF8.self)
        let lines = str.split(separator: "\n", omittingEmptySubsequences: true).prefix(550)
        var title = "Previous conversation"
        var path: String?
        var id: String?
        if provider == .claude { id = url.deletingPathExtension().lastPathComponent }
        for line in lines {
            guard let raw = line.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] else { continue }
            if provider == .claude {
                if path == nil { path = obj["cwd"] as? String }
                if (obj["type"] as? String) == "user", title == "Previous conversation",
                   let message = obj["message"] as? [String: Any], let text = messageText(message["content"]) {
                    title = shortTitle(text)
                }
            } else {
                if (obj["type"] as? String) == "session_meta",
                   let payload = obj["payload"] as? [String: Any] {
                    id = payload["id"] as? String ?? id
                    path = payload["cwd"] as? String ?? path
                }
                if title == "Previous conversation", let message = codexMessage(obj), message.role == "user" {
                    title = shortTitle(message.text)
                }
            }
            if path != nil && id != nil && title != "Previous conversation" { break }
        }
        guard let directory = path, directory.hasPrefix("/"),
              FileManager.default.fileExists(atPath: directory),
              let sessionID = id, UUID(uuidString: sessionID) != nil else { return nil }
        return DiscoveredSession(provider: provider, sessionID: sessionID,
                                 title: title, directory: directory, modified: modified, transcriptURL: url)
    }

    private static func inspectGemini(_ url: URL, modified: Date) -> DiscoveredSession? {
        // Gemini's hash folder is *not* reversible to its project path. Modern
        // versions write the original path in .project_root beside /chats/.
        // Without it, skip discovery rather than silently resume in ~/.
        let projectFolder = url.deletingLastPathComponent().deletingLastPathComponent()
        let marker = projectFolder.appendingPathComponent(".project_root")
        guard let rawRoot = try? String(contentsOf: marker, encoding: .utf8) else { return nil }
        let cwd = rawRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cwd.hasPrefix("/"), FileManager.default.fileExists(atPath: cwd) else { return nil }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 524_288) else { return nil }
        var title = "Previous conversation"
        var id: String?
        if url.pathExtension == "json", let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            id = object["sessionId"] as? String ?? object["session_id"] as? String
            if let messages = object["messages"] as? [[String: Any]] {
                for message in messages {
                    let kind = message["type"] as? String ?? message["role"] as? String ?? ""
                    if kind == "user", let text = messageText(message["content"]) {
                        title = shortTitle(text); break
                    }
                }
            }
        } else {
            let text = String(decoding: data, as: UTF8.self)
            for line in text.split(separator: "\n").prefix(500) {
                guard let lineData = line.data(using: .utf8),
                      let object = (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any] else { continue }
                if id == nil { id = object["session_id"] as? String ?? object["sessionId"] as? String }
                let kind = object["type"] as? String
                if title == "Previous conversation",
                   (kind == "message" && (object["role"] as? String) == "user") || kind == "user",
                   let body = messageText(object["content"]) {
                    title = shortTitle(body)
                }
                if id != nil && title != "Previous conversation" { break }
            }
        }
        guard let uuid = id, UUID(uuidString: uuid) != nil else { return nil }
        return DiscoveredSession(provider: .gemini, sessionID: uuid, title: title,
                                 directory: cwd, modified: modified, transcriptURL: url)
    }

    /// Grok sessions keep summary.json (id, cwd, title) beside chat_history.jsonl.
    private static func inspectGrok(_ url: URL, modified: Date) -> DiscoveredSession? {
        let folder = url.deletingLastPathComponent()
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("summary.json")),
              let summary = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let info = summary["info"] as? [String: Any],
              let id = info["id"] as? String, UUID(uuidString: id) != nil,
              let cwd = info["cwd"] as? String, cwd.hasPrefix("/"),
              FileManager.default.fileExists(atPath: cwd) else { return nil }
        var title = (summary["generated_title"] as? String).flatMap { $0.isEmpty ? nil : shortTitle($0) }
        if title == nil, let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            let text = String(decoding: (try? handle.read(upToCount: 524_288)) ?? Data(), as: UTF8.self)
            for line in text.split(separator: "\n").prefix(400) {
                guard let raw = line.data(using: .utf8),
                      let obj = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any],
                      (obj["type"] as? String) == "user", let query = grokQuery(obj["content"]) else { continue }
                title = shortTitle(query); break
            }
        }
        // A session with no real prompt yet is just an opened TUI; nothing to resume.
        guard let title else { return nil }
        return DiscoveredSession(provider: .grok, sessionID: id, title: title,
                                 directory: cwd, modified: modified, transcriptURL: url)
    }

    /// What the person typed in a Grok user record: the <user_query> block, minus injected context.
    static func grokQuery(_ content: Any?) -> String? {
        let texts: [String]
        if let text = content as? String { texts = [text] }
        else if let blocks = content as? [[String: Any]] { texts = blocks.compactMap { $0["text"] as? String } }
        else { return nil }
        for text in texts {
            if let start = text.range(of: "<user_query>"), let end = text.range(of: "</user_query>"),
               start.upperBound <= end.lowerBound {
                let query = text[start.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
                if !query.isEmpty { return query }
            }
        }
        let plain = texts.filter { !isPlumbing($0) && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("<") }
        return plain.isEmpty ? nil : plain.joined(separator: "\n\n")
    }

    /// Codex rollout records, old (event_msg user_message) and new (item_completed UserMessage) styles.
    static func codexMessage(_ obj: [String: Any]) -> TranscriptMessage? {
        guard (obj["type"] as? String) == "event_msg", let payload = obj["payload"] as? [String: Any],
              let event = payload["type"] as? String else { return nil }
        if let body = payload["message"] as? String, !body.isEmpty {
            if event == "user_message" { return TranscriptMessage(role: "user", text: body) }
            if event == "agent_message" { return TranscriptMessage(role: "assistant", text: body) }
        }
        guard event == "item_completed", let item = payload["item"] as? [String: Any],
              let kind = item["type"] as? String, let body = messageText(item["content"]), !body.isEmpty else { return nil }
        if kind == "UserMessage" { return TranscriptMessage(role: "user", text: body) }
        if kind == "AgentMessage" { return TranscriptMessage(role: "assistant", text: body) }
        return nil
    }

    private static func messageText(_ content: Any?) -> String? {
        if let text = content as? String { return isPlumbing(text) ? nil : text }
        if let blocks = content as? [[String: Any]] {
            let texts = blocks.compactMap { block -> String? in
                // Claude/Codex tag text blocks ("text" or "Text"); Gemini parts have no type at all.
                let type = (block["type"] as? String)?.lowercased()
                guard type == nil || type == "text", let text = block["text"] as? String,
                      !text.isEmpty, !isPlumbing(text) else { return nil }
                return text
            }
            return texts.isEmpty ? nil : texts.joined(separator: "\n\n")
        }
        return nil
    }

    /// Text the CLI writes into the transcript that was never part of the visible chat.
    static func isPlumbing(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = ["<system-reminder>", "<command-name>", "<command-message>", "<local-command-",
                        "<command-args>", "Caveat: The messages below", "[Request interrupted",
                        "This session is being continued from a previous conversation",
                        "<environment_context>", "<user_instructions>", "<user_info>", "<rules>"]
        return prefixes.contains { trimmed.hasPrefix($0) }
    }

    /// A few words for the head and header, not the whole first prompt.
    /// Paths and links are dropped, then it's cut to about five words / 32 characters.
    static func shortTitle(_ text: String) -> String {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init).filter {
            !$0.hasPrefix("/") && !$0.hasPrefix("~/") && !$0.contains("://")
        }
        var title = ""
        for word in words.prefix(5) {
            let next = title.isEmpty ? word : title + " " + word
            if next.count > 32 { break }
            title = next
        }
        if title.isEmpty, let first = words.first { title = String(first.prefix(31)) + "…" }
        else if words.count > title.split(separator: " ").count { title += "…" }
        return title.isEmpty ? "Previous conversation" : title
    }
}

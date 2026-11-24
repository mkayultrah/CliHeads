import AppKit
import Combine
import Foundation

@MainActor
final class AgentSession: ObservableObject {
    enum Status: String {
        case idle = "Ready"
        case starting = "Starting"
        case working = "Working"
        case ready = "Connected"
        case stopped = "Disconnected"
        case failed = "Error"
    }

    let id: UUID
    let provider: AgentProvider
    @Published var title: String
    let directory: String
    @Published var messages: [ChatMessage]
    @Published var draft = ""
    @Published private(set) var status: Status = .idle
    @Published private(set) var activity = ""
    @Published private(set) var diagnostics: [String] = []
    @Published private(set) var updateCounter = 0
    @Published private(set) var unread = 0
    @Published private(set) var latestAssistantPreview = ""
    @Published var expanded = false
    /// Tool uses waiting on Allow / Deny, oldest first.
    @Published private(set) var pendingPermissions: [PermissionPrompt] = []
    /// Shift+tab mode, shown under the composer like the CLI's footer.
    /// Saved with the head, and remembered per agent so new heads start on the same mode.
    @Published private(set) var permissionMode: PermissionMode = .default {
        didSet {
            guard permissionMode != oldValue else { return }
            UserDefaults.standard.set(permissionMode.rawValue, forKey: Self.lastModeKey(provider))
            onSave?()
        }
    }
    private static func lastModeKey(_ provider: AgentProvider) -> String { "lastPermissionMode.\(provider.rawValue)" }
    /// Non nil while the /resume list is open. Holds the search text typed after /resume.
    @Published var resumeQuery: String?
    /// Images to go out with the next message.
    @Published var attachments: [ImageAttachment] = []
    /// Messages typed while a turn was running. Sent one by one as turns finish.
    @Published var queued: [QueuedMessage] = []

    struct QueuedMessage: Identifiable {
        let id = UUID()
        let text: String
        let images: [ImageAttachment]
    }

    var agentSessionID: String?
    var onSave: (() -> Void)?
    var onIncomingReply: (() -> Void)?
    private(set) var liveTerminal: LiveTerminal?
    private var process: Process?
    private var stdinHandle: FileHandle?
    /// Pipe writes can be big (base64 images), so keep them off the main thread, in order.
    private let inputQueue = DispatchQueue(label: "cliheads.stdin")
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var stdoutLines = JSONLineBuffer()
    private var stderrLines = JSONLineBuffer()
    /// Last few stderr lines, shown when a CLI exits without saying why on stdout.
    private var stderrTail: [String] = []
    private var currentReplyID: UUID?
    private var receivedStreamingText = false
    private var lastSnapshot = ""
    private var expectedExit = false
    private var completedCurrentTurn = false
    private var turnStartedAt: Date?
    private var receivedFirstToken = false
    // On a newly-created Claude chat, the initial launch must use --session-id,
    // not --resume. This is reset only if the process fails before starting.
    private var freshClaudeSession = false
    private var receivedThinking = false
    private var receivedNotice = false
    /// Mode requests in flight, so a refusal can put the old mode back.
    private var pendingModeRequests: [String: (previous: PermissionMode, requested: PermissionMode)] = [:]
    private var unavailableModes: Set<PermissionMode> = []
    private var controlCounter = 0
    /// Set while a stop (interrupt) is in flight, so its error result reads as "interrupted".
    private var interrupting = false
    private var permissionNoticeShown = false

    init(saved: SavedHead) {
        id = saved.id; provider = saved.provider
        // Older heads kept the whole first prompt as the title.
        title = saved.title.count > 34 ? SessionCatalog.shortTitle(saved.title) : saved.title
        directory = saved.directory; agentSessionID = saved.agentSessionID
        let remembered = saved.permissionMode
            ?? UserDefaults.standard.string(forKey: Self.lastModeKey(saved.provider))
        if let mode = remembered.flatMap(PermissionMode.init(rawValue:)), saved.provider.modes.contains(mode) {
            permissionMode = mode
        }
        // An empty reply means the app quit mid turn. Left in, it shows as typing
        // dots forever, so drop it and pull the real reply from the CLI transcript.
        let interrupted = saved.messages.contains { $0.role == .assistant && $0.text.isEmpty }
        messages = saved.messages.filter {
            !($0.role == .assistant && $0.text.isEmpty)
                && !($0.role == .user && SessionCatalog.isPlumbing($0.text))
        }
        if interrupted, agentSessionID != nil {
            DispatchQueue.main.async { [weak self] in self?.refreshHistoryAfterTerminal() }
        }
    }

    var isWorking: Bool { status == .starting || status == .working }

    func submit() {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = attachments
        guard !prompt.isEmpty || !images.isEmpty else { return }
        guard liveTerminal?.running != true else {
            addDiagnostic("Full CLI is active. Switch back to Chat to send from the composer.")
            return
        }
        draft = ""; attachments = []
        // Like the CLI: typing while it works queues the message for after this turn.
        // A one shot CLI can still be exiting after its reply, so wait for it too.
        if isWorking || (!provider.supportsPersistentStdin && process != nil) {
            queued.append(QueuedMessage(text: prompt, images: images))
            updateCounter += 1
            return
        }
        send(prompt, images: images)
    }

    private func send(_ prompt: String, images: [ImageAttachment]) {
        if images.isEmpty, handleNativeCommand(prompt) { return }
        var message = ChatMessage(role: .user, text: prompt)
        if !images.isEmpty { message.images = images.compactMap { $0.save() } }
        messages.append(message)
        let reply = ChatMessage(role: .assistant, text: "")
        messages.append(reply)
        currentReplyID = reply.id
        receivedStreamingText = false; lastSnapshot = ""
        receivedThinking = false; receivedNotice = false
        completedCurrentTurn = false; interrupting = false
        turnStartedAt = Date()
        receivedFirstToken = false
        status = .working; activity = "Starting agent…"; updateCounter += 1
        onSave?()

        if process?.isRunning != true {
            // One shot CLIs take images as launch arguments; Claude gets them over stdin below.
            // Grok takes them base64 in argv, so keep the total well under the 1MB limit.
            let budget = 600_000 / max(images.count, 1) * 3 / 4
            let files: [PromptImage] = provider.supportsPersistentStdin ? [] : images.compactMap { original -> PromptImage? in
                let image = provider == .grok ? original.shrunk(toFit: budget) : original
                return image.save().map { PromptImage(path: $0, mediaType: image.mediaType, data: image.data) }
            }
            guard launchProcess(prompt: prompt, images: files) else { return }
            if provider == .claude, permissionMode != .default { sendMode(permissionMode, previous: .default) }
        }
        if provider.supportsPersistentStdin {
            do {
                guard stdinHandle != nil else { throw SessionError.missingInput }
                writeInput(try ClaudeProtocol.inputLine(prompt, images: images.map { ($0.mediaType, $0.data) }))
                addDiagnostic(images.isEmpty ? "Sent message to Claude" : "Sent message with \(images.count) image(s)")
            } catch { finishWithError("Cannot send message: \(error.localizedDescription)") }
        }
    }

    /// /resume and /clear are done by the chat head itself. True if handled.
    private func handleNativeCommand(_ prompt: String) -> Bool {
        // /resume and /clear need the CLI's interactive picker, so the chat head does them natively.
        if let match = prompt.range(of: #"^/(resume|continue)\b"#, options: [.regularExpression, .caseInsensitive]) {
            // Whatever follows /resume becomes the search text; the composer keeps filtering it.
            let query = String(prompt[match.upperBound...]).trimmingCharacters(in: .whitespaces)
            draft = query
            resumeQuery = query
            return true
        }
        if prompt.range(of: #"^/(clear|new|reset)\s*$"#, options: [.regularExpression, .caseInsensitive]) != nil {
            startFresh()
            return true
        }
        return false
    }

    /// Stop button / Esc: interrupt the turn like the CLI. Kills the process if it won't stop.
    func stop() {
        guard status == .working, !interrupting else { return }
        pendingPermissions.removeAll()
        if provider.supportsPersistentStdin, process?.isRunning == true, stdinHandle != nil {
            interrupting = true
            controlCounter += 1
            if let data = try? ClaudeProtocol.interruptLine(id: "cliheads-stop-\(controlCounter)") { writeInput(data) }
            activity = "Stopping…"; updateCounter += 1
            addDiagnostic("Interrupt sent")
            let attempt = controlCounter
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                guard let self, self.interrupting, self.controlCounter == attempt else { return }
                self.addDiagnostic("CLI didn't stop in time, ending it")
                self.stopHeadless()
                self.finishInterrupted()
            }
        } else {
            stopHeadless()
            finishInterrupted()
        }
    }

    private func finishInterrupted() {
        interrupting = false
        completedCurrentTurn = true
        if replyIsEmpty, currentReply?.thinking?.isEmpty != false, let id = currentReplyID {
            messages.removeAll { $0.id == id }
        }
        currentReplyID = nil; turnStartedAt = nil
        addNotice("interrupted")
        status = .ready; activity = ""
        // Like the CLI: queued messages come back into the box instead of firing off.
        restoreQueueToDraft()
        updateCounter += 1; onSave?()
    }

    private func restoreQueueToDraft() {
        guard !queued.isEmpty else { return }
        let texts = queued.map(\.text) + [draft]
        draft = texts.filter { !$0.isEmpty }.joined(separator: "\n")
        attachments = queued.flatMap(\.images) + attachments
        queued = []
    }

    /// Sends the next queued message once the agent is free.
    private func drainQueue() {
        guard !isWorking, !queued.isEmpty, liveTerminal?.running != true else { return }
        // One shot CLIs (Codex, Gemini) take the next prompt after the process exits.
        if !provider.supportsPersistentStdin, process?.isRunning == true { return }
        let next = queued.removeFirst()
        send(next.text, images: next.images)
    }

    private enum SessionError: Error { case missingInput }

    private func launchProcess(prompt: String, images: [PromptImage] = []) -> Bool {
        guard let executable = executablePath() else {
            finishWithError("\(provider.title) was not found. Install its CLI and sign in from Terminal first.")
            return false
        }
        let dir = URL(fileURLWithPath: directory, isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            finishWithError("Working directory does not exist: \(directory)")
            return false
        }
        stdoutLines = JSONLineBuffer(); stderrLines = JSONLineBuffer(); stderrTail = []; expectedExit = false
        let output = Pipe(), errors = Pipe()
        // One shot CLIs get an empty stdin; Codex otherwise sits waiting for more input.
        let input: Pipe? = provider.supportsPersistentStdin ? Pipe() : nil
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.currentDirectoryURL = dir
        if provider.choosesSessionID && agentSessionID == nil {
            agentSessionID = UUID().uuidString.lowercased()
            freshClaudeSession = true
            onSave?()
        } else if provider == .claude, let id = agentSessionID, !SessionCatalog.hasClaudeTranscript(id) {
            // Picked earlier (say by Full CLI) but never written, so --resume would fail.
            freshClaudeSession = true
        } else { freshClaudeSession = false }
        task.arguments = provider.arguments(prompt: prompt, sessionID: agentSessionID,
                                            newSession: freshClaudeSession, mode: permissionMode,
                                            images: images)
        permissionNoticeShown = false
        task.environment = CLILocator.environment(for: executable)
        task.standardInput = input ?? FileHandle.nullDevice
        task.standardOutput = output; task.standardError = errors
        process = task; stdinHandle = input?.fileHandleForWriting
        stdoutPipe = output; stderrPipe = errors

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async { [weak self] in self?.readStdout(data) }
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async { [weak self] in self?.readStderr(data) }
        }
        task.terminationHandler = { [weak self] finished in
            let code = finished.terminationStatus
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.processTerminated(finished, exitCode: code)
            }
        }
        do {
            try task.run()
            addDiagnostic("Launched \(provider.title) in \(directory)")
            return true
        } catch {
            finishWithError("Failed to launch \(provider.title): \(error.localizedDescription)")
            teardownIO(); process = nil
            return false
        }
    }

    private func readStdout(_ data: Data) {
        for line in stdoutLines.append(data) {
            for event in provider.parse(line) { consume(event) }
        }
    }

    private func readStderr(_ data: Data) {
        for line in stderrLines.append(data) {
            addDiagnostic("stderr: \(String(line.prefix(1200)))")
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { stderrTail = Array((stderrTail + [String(trimmed.prefix(300))]).suffix(3)) }
            // Headless Grok refuses tools that need approval instead of asking.
            if provider == .grok, !permissionNoticeShown,
               line.range(of: "permission required", options: .caseInsensitive) != nil {
                permissionNoticeShown = true
                addNotice("grok needs permission for that. press shift+tab for accept edits or bypass, then ask again")
            }
        }
    }

    private func consume(_ event: ClaudeEvent) {
        switch event {
        case .sessionID(let id):
            // Keep the canonical resume ID. Some CLIs emit a new per-invocation
            // identifier during --resume; replacing ours would strand the chat.
            if agentSessionID == nil { agentSessionID = id; onSave?() }
        case .textBlockStart:
            // A new text block after a tool call: keep it as its own paragraph.
            if let text = currentReply?.text, !text.isEmpty, !text.hasSuffix("\n\n") {
                appendToReply(text.hasSuffix("\n") ? "\n" : "\n\n")
            }
        case .textDelta(let delta):
            recordFirstToken()
            receivedStreamingText = true
            appendToReply(delta); activity = "Responding…"
        case .thinkingBlockStart:
            if let thinking = currentReply?.thinking, !thinking.isEmpty { appendThinking("\n\n") }
            activity = "Thinking…"
        case .thinkingDelta(let delta):
            receivedThinking = true
            appendThinking(delta); activity = "Thinking…"
        case .thinkingSnapshot(let text):
            if !receivedThinking { appendThinking((currentReply?.thinking?.isEmpty == false ? "\n\n" : "") + text) }
        case .systemNotice(let text):
            receivedNotice = true
            addNotice(text)
        case .permissionRequest(let prompt):
            if prompt.toolName == "AskUserQuestion" {
                // No way to show a question picker here, so tell the model to ask in plain text.
                let message = "This chat can't show question pickers. Ask the question as plain text in your reply and wait for the answer."
                if let data = try? ClaudeProtocol.permissionLine(prompt, allow: false, denyMessage: message) {
                    writeInput(data)
                }
                addDiagnostic("AskUserQuestion denied: question pickers aren't supported in chat")
                break
            }
            pendingPermissions.append(prompt)
            activity = "Waiting for you to allow \(prompt.tool)"
            updateCounter += 1
            addDiagnostic("Permission requested: \(prompt.tool) \(prompt.summary.prefix(200))")
            if !expanded {
                latestAssistantPreview = "Wants to use \(prompt.tool): \(prompt.summary.prefix(100))"
                unread += 1
                onIncomingReply?()
            }
        case .sessionInfo(let mode, let commands):
            if provider == .claude { SlashCommands.remember(commands) }
            if let mode, let parsed = PermissionMode(rawValue: mode), pendingModeRequests.isEmpty {
                permissionMode = parsed
            }
        case .permissionMode(let mode):
            if let parsed = PermissionMode(rawValue: mode), pendingModeRequests.isEmpty {
                permissionMode = parsed
            }
        case .controlResult(let id, let error):
            guard let pending = pendingModeRequests.removeValue(forKey: id) else { break }
            if let error {
                unavailableModes.insert(pending.requested)
                if permissionMode == pending.requested { permissionMode = pending.previous }
                addDiagnostic("Mode change refused: \(error)")
                addNotice("cant switch to \(pending.requested.title): \(error)")
            } else {
                addDiagnostic("Mode: \(pending.requested.rawValue)")
            }
        case .unsupportedControl(let id, let subtype):
            addDiagnostic("Unsupported control request: \(subtype)")
            if let data = try? ClaudeProtocol.controlErrorLine(id: id, message: "Not supported by CliHeads") {
                writeInput(data)
            }
        case .assistantSnapshot(let text):
            if !text.isEmpty { recordFirstToken() }
            // Some CLIs emit multiple complete assistant messages in one turn.
            // Keep those intact; never concatenate snapshots to delta output.
            if !receivedStreamingText && text != lastSnapshot {
                replaceReply(text); lastSnapshot = text
            }
        case .toolUse(let name):
            activity = "Using \(name)…"; addDiagnostic("Tool: \(name)")
        case .toolResult(let text):
            addDiagnostic(text); activity = "Thinking…"
        case .finished(let text, let isError):
            if interrupting { finishInterrupted(); return }
            completedCurrentTurn = true
            freshClaudeSession = false
            if isError {
                if replyIsEmpty { replaceReply(text ?? "Agent returned an error. Check Events.") }
                else if let text, !text.isEmpty { addNotice(text) }
                status = .failed; activity = "Agent returned an error"
            } else {
                if replyIsEmpty, let text, !text.isEmpty { replaceReply(text) }
                // Commands that need the interactive TUI: show as a grey line pointing at Full CLI.
                if let id = currentReplyID, let index = messages.firstIndex(where: { $0.id == id }),
                   messages[index].text.contains("isn't available in this environment") {
                    messages[index].role = .notice
                    messages[index].text = messages[index].text.trimmingCharacters(in: .whitespacesAndNewlines)
                        + " Use the Full CLI button (terminal icon, top right) for this one."
                }
                // Hook-only turns have no reply, just the notice.
                if replyIsEmpty, receivedNotice, currentReply?.thinking?.isEmpty != false,
                   let id = currentReplyID { messages.removeAll { $0.id == id } }
                status = .ready; activity = ""
            }
            pendingPermissions.removeAll()
            if let started = turnStartedAt {
                addDiagnostic(String(format: "Turn completed after %.2fs", Date().timeIntervalSince(started)))
            }
            turnStartedAt = nil
            latestAssistantPreview = previewText(fallback: text, isError: isError)
            currentReplyID = nil
            if !expanded {
                unread += 1
                onIncomingReply?()
            }
            onSave?()
            if isError { restoreQueueToDraft() } else { drainQueue() }
        case .error(let message): addDiagnostic(message)
        }
    }

    private func recordFirstToken() {
        guard !receivedFirstToken else { return }
        receivedFirstToken = true
        freshClaudeSession = false
        if let started = turnStartedAt {
            addDiagnostic(String(format: "First reply text after %.2fs", Date().timeIntervalSince(started)))
        }
    }

    private var currentReply: ChatMessage? {
        guard let id = currentReplyID else { return nil }
        return messages.first { $0.id == id }
    }

    private func appendThinking(_ text: String) {
        guard let id = currentReplyID, let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].thinking = (messages[index].thinking ?? "") + text; updateCounter += 1
    }

    /// Notices sit above the in-progress reply so the reply stays last.
    private func addNotice(_ text: String) {
        let notice = ChatMessage(role: .notice, text: text)
        if let id = currentReplyID, let index = messages.firstIndex(where: { $0.id == id }) {
            messages.insert(notice, at: index)
        } else { messages.append(notice) }
        updateCounter += 1; onSave?()
    }

    func answerPermission(_ prompt: PermissionPrompt, allow: Bool, always: Bool = false) {
        guard let index = pendingPermissions.firstIndex(of: prompt) else { return }
        pendingPermissions.remove(at: index)
        do {
            guard stdinHandle != nil else { throw SessionError.missingInput }
            writeInput(try ClaudeProtocol.permissionLine(prompt, allow: allow, always: always))
            addDiagnostic("\(allow ? (always ? "Always allowed" : "Allowed") : "Denied") \(prompt.tool)")
            activity = pendingPermissions.first.map { "Waiting for you to allow \($0.tool)" }
                ?? (allow ? "Using \(prompt.tool)…" : "Thinking…")
        } catch { addDiagnostic("Cannot answer permission: \(error.localizedDescription)") }
        updateCounter += 1
    }

    /// Shift+tab: next mode, applied live if the CLI is running, otherwise on next launch.
    func cycleMode() {
        setMode(permissionMode.next(skipping: unavailableModes, in: provider.modes))
    }

    func setMode(_ mode: PermissionMode) {
        guard mode != permissionMode, provider.modes.contains(mode) else { return }
        let previous = permissionMode
        permissionMode = mode
        updateCounter += 1
        // One shot CLIs pick the mode up as a flag on the next prompt.
        if provider.supportsPersistentStdin, process?.isRunning == true { sendMode(mode, previous: previous) }
    }

    private func sendMode(_ mode: PermissionMode, previous: PermissionMode) {
        controlCounter += 1
        let id = "cliheads-mode-\(controlCounter)"
        do {
            guard stdinHandle != nil else { throw SessionError.missingInput }
            writeInput(try ClaudeProtocol.setModeLine(id: id, mode: mode.rawValue))
            pendingModeRequests[id] = (previous, mode)
        } catch {
            permissionMode = previous
            addDiagnostic("Cannot change mode: \(error.localizedDescription)")
        }
    }

    /// Stops the running CLI without marking the chat as failed.
    private func stopHeadless() {
        if let process, process.isRunning {
            expectedExit = true
            teardownIO()
            process.terminate()
        }
        process = nil
        pendingPermissions.removeAll(); pendingModeRequests.removeAll()
    }

    /// /clear: a brand new conversation in the same head.
    private func startFresh() {
        guard !isWorking else { addDiagnostic("Wait for the current turn to finish."); return }
        stopHeadless()
        agentSessionID = nil; freshClaudeSession = false
        messages = [ChatMessage(role: .notice, text: "new conversation")]
        status = .ready; activity = ""
        latestAssistantPreview = ""
        updateCounter += 1; onSave?()
    }

    /// Past Claude conversations for this head's folder, newest first. Call off the main thread.
    nonisolated static func samePath(_ a: String, _ b: String) -> Bool {
        func resolved(_ path: String) -> String {
            URL(fileURLWithPath: path).resolvingSymlinksInPath().standardized.path
        }
        return resolved(a) == resolved(b)
    }

    nonisolated static func resumable(provider: AgentProvider, directory: String, excluding current: String?) -> [DiscoveredSession] {
        var seen = Set<String>()
        return SessionCatalog.discover(limit: 400)
            .filter { $0.provider == provider && samePath($0.directory, directory) && $0.sessionID != current }
            .sorted { $0.modified > $1.modified }
            .filter { seen.insert($0.sessionID).inserted }
    }

    /// Picked from the /resume list: switch this head to that conversation.
    func resume(_ item: DiscoveredSession) {
        resumeQuery = nil
        guard !isWorking else { addDiagnostic("Wait for the current turn to finish."); return }
        stopHeadless()
        agentSessionID = item.sessionID; freshClaudeSession = false
        status = .starting; activity = "Loading conversation…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let history = SessionCatalog.recentHistory(item)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.agentSessionID == item.sessionID else { return }
                self.messages = history.map {
                    ChatMessage(role: $0.role == "user" ? .user : .assistant, text: $0.text, date: .distantPast)
                } + [ChatMessage(role: .notice, text: "resumed \(item.title)", date: .distantPast)]
                self.status = .ready; self.activity = ""
                self.addDiagnostic("Resumed \(item.sessionID)")
                self.updateCounter += 1
                self.onSave?()
                self.drainQueue()
            }
        }
    }

    private var replyIsEmpty: Bool {
        guard let id = currentReplyID, let msg = messages.first(where: { $0.id == id }) else { return true }
        return msg.text.isEmpty
    }


    private func previewText(fallback: String?, isError: Bool) -> String {
        let raw: String
        if let id = currentReplyID,
           let msg = messages.first(where: { $0.id == id }),
           !msg.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            raw = msg.text
        } else if let fallback, !fallback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            raw = fallback
        } else {
            raw = isError ? "Agent returned an error" : "New reply"
        }
        let singleLine = raw
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        let collapsed = singleLine.replacingOccurrences(of: "  +", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(collapsed.prefix(140))
    }

    private func appendToReply(_ text: String) {
        guard let id = currentReplyID, let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].text += text; updateCounter += 1
    }

    private func replaceReply(_ text: String) {
        guard let id = currentReplyID, let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].text = text; updateCounter += 1
    }

    private func finishWithError(_ message: String) {
        status = .failed; activity = ""
        if currentReplyID != nil {
            if replyIsEmpty { replaceReply(message) } else { addNotice(message) }
            currentReplyID = nil
        }
        else { messages.append(ChatMessage(role: .notice, text: message)) }
        addDiagnostic("ERROR: " + message); onSave?()
    }

    private func processTerminated(_ finished: Process, exitCode: Int32) {
        guard let active = process, active === finished else { return }
        teardownIO(); process = nil
        pendingPermissions.removeAll(); pendingModeRequests.removeAll()
        if freshClaudeSession, !receivedFirstToken, !completedCurrentTurn {
            // Nothing came back, so the CLI may never have written this session.
            agentSessionID = nil; freshClaudeSession = false
        }
        if expectedExit { if status != .starting { status = .stopped }; return }
        if currentReplyID != nil {
            if exitCode == 0 && completedCurrentTurn { status = .ready }
            else {
                let reason = stderrTail.isEmpty ? "Check Events for details." : stderrTail.joined(separator: "\n")
                finishWithError("\(provider.title) exited (status \(exitCode)).\n\(reason)")
            }
        } else if exitCode != 0 {
            status = .failed; activity = "Agent exited with an error"
        } else {
            status = .ready; activity = ""
        }
        if status == .ready { drainQueue() } else { restoreQueueToDraft() }
    }

    /// Queue a write to the CLI's stdin. Errors are ignored; a dead pipe shows up as the process exiting.
    private func writeInput(_ data: Data) {
        guard let handle = stdinHandle else { return }
        inputQueue.async {
            do { try handle.write(contentsOf: data) } catch {}
        }
    }

    private func teardownIO() {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        // Close on the same queue so pending writes go out first.
        if let handle = stdinHandle { inputQueue.async { try? handle.close() } }
        stdoutPipe = nil; stderrPipe = nil; stdinHandle = nil
    }

    func activateTerminal() -> LiveTerminal? {
        guard !isWorking else {
            addDiagnostic("Wait for the current reply before switching to Full CLI.")
            return nil
        }
        if let liveTerminal { return liveTerminal }
        let terminal = LiveTerminal(session: self)
        liveTerminal = terminal
        terminal.start()
        return terminal
    }

    func stopTerminal() {
        liveTerminal?.stop()
        liveTerminal = nil
        // The terminal CLI is the source of truth. Refresh the clean transcript
        // preview after it has written its final session file.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            self?.refreshHistoryAfterTerminal()
        }
    }

    /// A brand new head picks up the latest CLI conversation for its folder,
    /// so opening it carries on where you left off instead of starting fresh.
    /// `isTaken` is checked again on main, since another head may have adopted
    /// the same session while the scan ran.
    func continueLatestSession(excluding taken: Set<String>, isTaken: @escaping @MainActor (String) -> Bool = { _ in false }) {
        guard agentSessionID == nil, messages.isEmpty, process == nil, liveTerminal == nil else { return }
        let provider = self.provider
        let directory = self.directory
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let latest = SessionCatalog.discover(limit: 60).first(where: {
                $0.provider == provider && AgentSession.samePath($0.directory, directory) && !taken.contains($0.id)
            }) else { return }
            let history = SessionCatalog.recentHistory(latest)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.agentSessionID == nil, self.messages.isEmpty,
                      self.process == nil, self.liveTerminal == nil, !isTaken(latest.id) else { return }
                self.agentSessionID = latest.sessionID
                self.messages = history.map {
                    ChatMessage(role: $0.role == "user" ? .user : .assistant, text: $0.text, date: .distantPast)
                }
                self.updateCounter += 1
                self.onSave?()
            }
        }
    }

    private func refreshHistoryAfterTerminal() {
        let provider = self.provider
        let directory = self.directory
        let currentID = agentSessionID
        let before = messages.map(\.id)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let candidates = SessionCatalog.discover(limit: 160)
                .filter { $0.provider == provider && AgentSession.samePath($0.directory, directory) }
            let selected: DiscoveredSession?
            if let currentID {
                selected = candidates.first { $0.sessionID == currentID }
            } else {
                // Only adopt an unknown interactive session if the match is
                // unambiguous. Never silently resume someone else's chat.
                let recentlyModified = candidates.filter { $0.modified > Date().addingTimeInterval(-3600) }
                selected = recentlyModified.count == 1 ? recentlyModified.first : nil
            }
            guard let selected else { return }
            let history = SessionCatalog.recentHistory(selected)
            guard !history.isEmpty else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.liveTerminal == nil, !self.isWorking,
                      self.messages.map(\.id) == before else { return }
                if self.agentSessionID == nil { self.agentSessionID = selected.sessionID }
                self.messages = history.map {
                    ChatMessage(role: $0.role == "user" ? .user : .assistant, text: $0.text, date: .distantPast)
                }
                self.updateCounter += 1
                self.onSave?()
            }
        }
    }

    func suspendHeadlessForTerminal() {
        expectedExit = true
        teardownIO()
        if let process, process.isRunning { process.terminate() }
        process = nil; pendingPermissions.removeAll()
        status = .ready
        activity = ""
    }

    func terminate() {
        stopTerminal()
        expectedExit = true; teardownIO()
        if let process, process.isRunning { process.terminate() }
        process = nil; pendingPermissions.removeAll()
        status = .stopped; activity = ""; onSave?()
    }

    func markRead() { unread = 0; expanded = true }
    func markCollapsed() {
        expanded = false
        // Closing the chat with an approval still waiting keeps a badge on the head.
        if !pendingPermissions.isEmpty, unread == 0 { unread = 1 }
    }

    private func addDiagnostic(_ line: String) {
        diagnostics.append("\(Date().formatted(date: .omitted, time: .standard))  \(line)")
        if diagnostics.count > 120 { diagnostics.removeFirst(diagnostics.count - 120) }
    }

    func snapshot(x: Double?, y: Double?) -> SavedHead {
        SavedHead(id: id, title: title, directory: directory, provider: provider,
                  agentSessionID: agentSessionID, messages: Array(messages.suffix(200)), x: x, y: y,
                  permissionMode: permissionMode.rawValue)
    }

    func executablePath() -> String? { CLILocator.find(provider.executable) }
}

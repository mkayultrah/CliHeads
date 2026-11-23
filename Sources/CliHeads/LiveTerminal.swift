import AppKit
import SwiftUI
import SwiftTerm

/// Full interactive CLI: a real PTY-backed terminal, not stripped ANSI text.
/// The native agent owns slash commands, permission prompts, model selection,
/// keybindings, and the rest of its terminal UI.
@MainActor
final class LiveTerminal: NSObject, ObservableObject, LocalProcessTerminalViewDelegate {
    let view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 450))
    @Published private(set) var running = false
    @Published private(set) var message = ""
    private weak var session: AgentSession?

    init(session: AgentSession) {
        self.session = session
        super.init()
        view.processDelegate = self
        view.autoresizingMask = [.width, .height]
    }

    func start() {
        guard !running, let session else { return }
        guard let executable = session.executablePath() else {
            message = "\(session.provider.title) is not installed or isn't on PATH."
            return
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: session.directory, isDirectory: &isDir), isDir.boolValue else {
            message = "Working directory does not exist: \(session.directory)"
            return
        }
        session.suspendHeadlessForTerminal()
        var arguments: [String] = []
        switch session.provider {
        case .claude:
            if let id = session.agentSessionID {
                // A head that was opened but never used has an ID with no transcript yet.
                arguments = SessionCatalog.hasClaudeTranscript(id) ? ["--resume", id] : ["--session-id", id]
            } else {
                let id = UUID().uuidString.lowercased()
                session.agentSessionID = id
                session.onSave?()
                // Creates a known session ID for the clean view to resume.
                arguments = ["--session-id", id]
            }
        case .codex:
            if let id = session.agentSessionID { arguments = ["resume", id] }
        case .gemini:
            if let id = session.agentSessionID { arguments = ["--resume", id] }
        case .grok:
            if let id = session.agentSessionID {
                arguments = ["--resume", id]
            } else {
                let id = UUID().uuidString.lowercased()
                session.agentSessionID = id
                session.onSave?()
                arguments = ["--session-id", id]
            }
        }
        var environment = CLILocator.environment(for: executable)
        environment["TERM"] = "xterm-256color"
        running = true
        message = ""
        view.startProcess(executable: executable,
                          args: arguments,
                          environment: environment.map { "\($0.key)=\($0.value)" },
                          currentDirectory: session.directory)
    }

    func stop() {
        guard running else { return }
        // Never terminate a CLI merely because the conversation bubble collapsed.
        // Only an explicit switch back to clean chat or closing the head does this.
        view.terminate()
        running = false
        message = "Terminal session stopped. The next clean message resumes its saved CLI session."
    }

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        Task { @MainActor [weak self] in
            self?.running = false
            self?.message = "CLI exited\(exitCode.map { " (code \($0))" } ?? "")."
        }
    }
}

struct EmbeddedTerminal: NSViewRepresentable {
    @ObservedObject var controller: LiveTerminal

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        controller.view
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}
}

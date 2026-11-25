import SwiftUI
import AppKit
import ImageIO

struct ChatView: View {
    @ObservedObject var session: AgentSession
    let collapse: () -> Void
    var openCount = 0
    @State private var showEvents = false
    @State private var followOutput = true
    @State private var showingTerminal = false
    @State private var confirmReturnToChat = false
    @State private var terminal: LiveTerminal?
    @State private var slashIndex = 0
    @State private var resumeItems: [DiscoveredSession]?
    @State private var resumeIndex = 0
    @State private var copiedResume = false

    /// Paste into Terminal to carry on this exact chat in the real CLI.
    private var resumeCommand: String? {
        guard let rawID = session.agentSessionID else { return nil }
        let quote = { (value: String) in "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let dir = quote(session.directory), id = quote(rawID)
        switch session.provider {
        case .claude: return "cd \(dir) && claude --resume \(id)"
        case .codex: return "cd \(dir) && codex resume \(id)"
        case .gemini: return "cd \(dir) && gemini --resume \(id)"
        case .grok: return "cd \(dir) && grok --resume \(id)"
        }
    }

    private var isBusy: Bool { session.isWorking }
    private var violet: Color {
        switch session.provider {
        case .claude: return Color(red: 0.70, green: 0.40, blue: 0.29)
        case .codex: return Color(red: 0.12, green: 0.55, blue: 0.40)
        case .gemini: return Color(red: 0.38, green: 0.45, blue: 0.83)
        case .grok: return Color(red: 0.24, green: 0.25, blue: 0.29)
        }
    }
    private var providerSymbol: String {
        switch session.provider {
        case .claude: return "terminal.fill"
        case .codex: return "circle.hexagongrid.fill"
        case .gemini: return "sparkles"
        case .grok: return "bolt.fill"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(.primary.opacity(0.08)).frame(height: 1)
            if showingTerminal { terminalScreen }
            else if showEvents { diagnosticsView }
            else if session.resumeQuery != nil { resumeList }
            else { conversation }
            if !showingTerminal {
                if let prompt = session.pendingPermissions.first {
                    PermissionCard(prompt: prompt, queued: session.pendingPermissions.count - 1,
                                   accent: violet) { allow, always in
                        session.answerPermission(prompt, allow: allow, always: always)
                    }
                    .padding(.horizontal, 12).padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                Rectangle().fill(.primary.opacity(0.08)).frame(height: 1)
                composer
            }
        }
        .onDrop(of: [.fileURL, .image], isTargeted: nil) { providers in
            // Nothing to attach to while the resume list or terminal is up.
            if showingTerminal || session.resumeQuery != nil { return false }
            for provider in providers {
                if provider.hasItemConformingToTypeIdentifier("public.file-url"),
                   provider.canLoadObject(ofClass: URL.self) {
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        guard let url, url.isFileURL, let image = ImageAttachment.from(fileURL: url) else { return }
                        DispatchQueue.main.async { session.attachments.append(image) }
                    }
                } else if provider.canLoadObject(ofClass: NSImage.self) {
                    _ = provider.loadObject(ofClass: NSImage.self) { object, _ in
                        guard let picked = object as? NSImage, let image = ImageAttachment.from(image: picked) else { return }
                        DispatchQueue.main.async { session.attachments.append(image) }
                    }
                }
            }
            return true
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: session.pendingPermissions.map(\.id))
        .frame(width: 430, height: 570)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(0.24), lineWidth: 1))
        .preferredColorScheme(nil)
        .onChange(of: session.draft) { _, _ in slashIndex = 0; resumeIndex = 0 }
        .task(id: session.resumeQuery != nil) {
            guard session.resumeQuery != nil else { resumeItems = nil; return }
            resumeItems = nil; resumeIndex = 0
            let provider = session.provider, directory = session.directory, current = session.agentSessionID
            resumeItems = await Task.detached(priority: .userInitiated) {
                AgentSession.resumable(provider: provider, directory: directory, excluding: current)
            }.value
        }
        .alert("Return to chat?", isPresented: $confirmReturnToChat) {
            Button("Stay in Full CLI", role: .cancel) {}
            Button("Stop CLI and return") {
                session.stopTerminal()
                terminal = nil
                showingTerminal = false
            }
        } message: {
            Text("The live terminal session will stop. Its saved CLI conversation can be resumed in chat mode. Only switch when the agent is idle.")
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            if let logo = HeadArt.logo(for: session.provider.rawValue) {
                Image(nsImage: HeadArt.image(provider: session.provider.rawValue, logo: logo, diameter: 28))
                    .frame(width: 28, height: 28)
            } else {
                ZStack {
                    Circle().fill(violet.gradient).frame(width: 28, height: 28)
                    Image(systemName: providerSymbol)
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(session.title).font(.system(size: 13, weight: .semibold))
                        .lineLimit(1).truncationMode(.tail)
                    Circle().fill(statusColor).frame(width: 6, height: 6)
                }
                Text(session.activity.isEmpty ? session.status.rawValue : session.activity)
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let command = resumeCommand, !showingTerminal {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                    copiedResume = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copiedResume = false }
                } label: {
                    Image(systemName: copiedResume ? "checkmark" : "arrow.uturn.backward.circle")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 26, height: 26)
                }
                .help("Copy the command to resume this chat in the CLI:\n\(command)")
                .accessibilityLabel("Copy resume command")
                .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            Button {
                if showingTerminal {
                    confirmReturnToChat = true
                } else if let running = session.activateTerminal() {
                    terminal = running
                    showingTerminal = true
                    showEvents = false
                }
            } label: {
                Image(systemName: showingTerminal ? "bubble.left.fill" : "terminal.fill")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 29, height: 26)
            }
            .disabled(!showingTerminal && session.isWorking)
            .help(showingTerminal ? "Return to chat (stops full CLI)" : "Full CLI: native menus, permissions, commands")
            .accessibilityLabel(showingTerminal ? "Return to chat" : "Switch to Full CLI")
            .buttonStyle(.plain).foregroundStyle(.secondary)
            if !showingTerminal {
                Button { showEvents.toggle() } label: {
                    Image(systemName: showEvents ? "bubble.left" : "line.3.horizontal.decrease")
                }
                .help(showEvents ? "Back to conversation" : "CLI events and errors")
                .accessibilityLabel(showEvents ? "Back to conversation" : "Show CLI events")
                .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            Button(action: collapse) {
                Image(systemName: "minus").font(.system(size: 15, weight: .bold))
                    .frame(width: 26, height: 26)
            }.buttonStyle(.plain).foregroundStyle(.secondary).help("Collapse to chat head")
                .accessibilityLabel("Collapse chat")
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
    }

    private var terminalScreen: some View {
        VStack(spacing: 0) {
            HStack {
                Text("FULL CLI")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                Spacer()
                Text("Agent controls • /commands • approvals")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            if let terminal {
                EmbeddedTerminal(controller: terminal)
                    .background(Color(nsColor: .textBackgroundColor))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onAppear {
                        DispatchQueue.main.async { [weak terminal] in
                            guard let terminal else { return }
                            terminal.view.window?.makeFirstResponder(terminal.view)
                        }
                    }
                if !terminal.message.isEmpty {
                    Text(terminal.message).font(.caption2).foregroundStyle(.secondary)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                }
            } else {
                Text("Terminal is not available")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var statusColor: Color {
        switch session.status {
        case .ready: return .green
        case .working, .starting: return .orange
        case .failed: return .red
        default: return .secondary
        }
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Plain VStack on purpose: a LazyVStack works out its visible rows while the
                // panel is still scaled down by the open animation and then shows nothing
                // until you scroll. The last 200 messages matches what gets saved anyway.
                VStack(alignment: .leading, spacing: 16) {
                    if session.messages.isEmpty {
                        emptyState.padding(.top, 100)
                    }
                    ForEach(session.messages.suffix(200)) { message in
                        MessageView(message: message, violet: violet, symbol: providerSymbol,
                                    typing: session.isWorking && message.id == session.messages.last?.id)
                            .id(message.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }.padding(.horizontal, 16).padding(.vertical, 18)
            }
            .defaultScrollAnchor(.bottom)
            // Fresh scroll view per open, so it always lands on the newest message.
            .id(openCount)
            .onChange(of: session.updateCounter) { _, _ in
                if followOutput { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: session.messages.count) { _, _ in
                if followOutput { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .overlay(alignment: .bottomTrailing) {
                Button {
                    followOutput.toggle()
                    if followOutput { proxy.scrollTo("bottom", anchor: .bottom) }
                } label: {
                    Image(systemName: followOutput ? "arrow.down.circle.fill" : "arrow.down.to.line.compact")
                        .font(.system(size: 15)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(13)
                .help(followOutput ? "Following new responses (click to pause)" : "Resume auto-scrolling")
                .accessibilityLabel(followOutput ? "Pause auto-scroll" : "Resume auto-scroll")
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 13) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 40, weight: .ultraLight)).foregroundStyle(violet)
            Text("\(session.provider.title) is ready").font(.system(size: 19, weight: .semibold))
            Text("Your CLI, without the terminal window.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Text(session.directory)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary).lineLimit(2).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity)
    }

    private var diagnosticsView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text("CLI EVENTS").font(.system(size: 10, weight: .bold, design: .monospaced))
                    Spacer()
                    Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(session.diagnostics.joined(separator: "\n"), forType: .string) }
                        .buttonStyle(.borderless)
                }
                ForEach(Array(session.diagnostics.enumerated()), id: \.offset) { entry in
                    Text(entry.element).font(.system(size: 11, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }
                if session.diagnostics.isEmpty { Text("No events yet").foregroundStyle(.secondary) }
            }.padding(17)
        }
    }

    // MARK: slash commands and /resume

    private var slashSuggestions: [SlashCommands.Command]? {
        guard session.resumeQuery == nil else { return nil }
        return SlashCommands.suggestions(for: session.draft, provider: session.provider)
    }

    private var filteredResume: [DiscoveredSession] {
        let query = session.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let items = resumeItems ?? []
        guard !query.isEmpty else { return items }
        return items.filter {
            $0.title.localizedCaseInsensitiveContains(query) || $0.sessionID.hasPrefix(query.lowercased())
        }
    }

    private func send() {
        if session.resumeQuery != nil {
            let items = filteredResume
            guard !items.isEmpty else { return }
            session.draft = ""
            session.resume(items[min(resumeIndex, items.count - 1)])
            return
        }
        // Like the CLI: Return on a partial command runs the highlighted one.
        if let list = slashSuggestions {
            session.draft = "/" + list[min(slashIndex, list.count - 1)].name
        }
        session.submit()
    }

    private func handleKey(_ key: ChatComposer.Key) -> Bool {
        if key == .backtab {
            session.cycleMode(); return true
        }
        if session.resumeQuery != nil {
            let count = filteredResume.count
            switch key {
            case .up: resumeIndex = max(0, resumeIndex - 1); return true
            case .down: resumeIndex = min(max(0, count - 1), resumeIndex + 1); return true
            case .escape: closeResume(); return true
            default: return false
            }
        }
        guard let list = slashSuggestions else {
            // Esc closes the chat (CliHeadsDelegate's key monitor); the stop button stops the agent.
            if key == .escape { return true }
            return false
        }
        switch key {
        case .tab: session.draft = "/" + list[min(slashIndex, list.count - 1)].name + " "; return true
        case .up: slashIndex = (slashIndex - 1 + list.count) % list.count; return true
        case .down: slashIndex = (slashIndex + 1) % list.count; return true
        case .escape: session.draft = ""; return true
        default: return false
        }
    }

    private func openResume(_ item: DiscoveredSession) {
        session.draft = ""
        session.resume(item)
    }

    private func closeResume() {
        session.resumeQuery = nil
        session.draft = ""
    }

    private var resumeList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Resume a conversation").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Cancel") { closeResume() }.buttonStyle(.borderless).controlSize(.small)
            }
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
            if resumeItems == nil {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredResume.isEmpty {
                Text(session.draft.isEmpty ? "No other conversations in this folder" : "Nothing matches \"\(session.draft)\"")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(filteredResume.enumerated()), id: \.element.id) { index, item in
                                resumeRow(item, selected: index == min(resumeIndex, filteredResume.count - 1))
                                    .id(item.id)
                                    .onTapGesture { openResume(item) }
                                    .accessibilityAddTraits(.isButton)
                                    .accessibilityAction { openResume(item) }
                            }
                        }.padding(.horizontal, 10).padding(.bottom, 10)
                    }
                    .onChange(of: resumeIndex) { _, index in
                        let items = filteredResume
                        guard !items.isEmpty else { return }
                        proxy.scrollTo(items[min(index, items.count - 1)].id)
                    }
                }
            }
        }
    }

    private func resumeRow(_ item: DiscoveredSession, selected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.title).font(.system(size: 13)).lineLimit(1)
            Text(item.modified, format: .relative(presentation: .named)) + Text("  ·  " + String(item.sessionID.prefix(8)))
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(selected ? violet.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }

    private func slashList(_ list: [SlashCommands.Command]) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(list.enumerated()), id: \.element.id) { index, command in
                HStack(spacing: 10) {
                    Text("/" + command.name).font(.system(size: 12, weight: .medium, design: .monospaced))
                        .frame(width: 130, alignment: .leading)
                    Text(command.detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(index == min(slashIndex, list.count - 1) ? violet.opacity(0.18) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
                .onTapGesture { session.draft = "/" + command.name + " " }
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { session.draft = "/" + command.name + " " }
            }
        }
    }

    /// The CLI footer: current mode on the left (click or shift+tab), keys on the right.
    private var footer: some View {
        HStack(spacing: 6) {
            if session.provider.modes.count > 1 {
                let mode = session.permissionMode
                Button { session.cycleMode() } label: {
                    Text(mode == .default ? "⏵ default mode" : mode.label)
                        .font(.system(size: 10, weight: mode == .default ? .regular : .semibold))
                        .foregroundStyle(mode.tint)
                }
                .buttonStyle(.plain)
                .help("Permission mode. Click or press shift+tab to cycle")
                Text("(shift+tab to cycle)").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            Text(footerKeys).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
        }
    }

    private var footerKeys: String {
        if session.resumeQuery != nil { return "type to search  ·  ↑↓ pick  ·  ⏎ resume  ·  esc" }
        if slashSuggestions != nil { return "tab complete  ·  ↑↓ pick  ·  ⏎ run" }
        if isBusy { return "⏎ queue  ·  esc stop  ·  ⇧⏎ new line" }
        return "⏎ send  ·  ⇧⏎ new line  ·  / commands"
    }

    private var acceptsImages: Bool { session.resumeQuery == nil }

    private var canSend: Bool {
        session.resumeQuery != nil || !session.attachments.isEmpty ||
            !session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var queuedList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(session.queued) { item in
                HStack(spacing: 7) {
                    Image(systemName: "clock").font(.system(size: 10))
                    Text(item.text.isEmpty ? "\(item.images.count) image(s)"
                         : item.text + (item.images.isEmpty ? "" : "  + \(item.images.count) image(s)"))
                        .font(.system(size: 11)).lineLimit(1)
                    Spacer(minLength: 4)
                    Button { session.queued.removeAll { $0.id == item.id } } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                    }
                    .buttonStyle(.plain).help("Remove from queue")
                    .accessibilityLabel("Remove from queue")
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(session.attachments) { item in
                    ZStack(alignment: .topTrailing) {
                        if let image = item.image {
                            Image(nsImage: image).resizable().scaledToFill()
                                .frame(width: 48, height: 48)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        Button { session.attachments.removeAll { $0.id == item.id } } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14)).foregroundStyle(.white, .black.opacity(0.6))
                        }
                        .buttonStyle(.plain).offset(x: 5, y: -5).help("Remove image")
                        .accessibilityLabel("Remove image")
                    }
                }
            }
            .padding(.top, 6).padding(.trailing, 6)
        }
    }

    private func pickImages() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        session.attachments += panel.urls.compactMap { ImageAttachment.from(fileURL: $0) }
    }

    private var composer: some View {
        VStack(spacing: 8) {
            if !session.queued.isEmpty { queuedList }
            if let list = slashSuggestions { slashList(list) }
            if !session.attachments.isEmpty { attachmentStrip }
            HStack(alignment: .bottom, spacing: 9) {
                if acceptsImages {
                    Button { pickImages() } label: {
                        Image(systemName: "photo.badge.plus")
                            .font(.system(size: 15, weight: .medium))
                            .frame(width: 26, height: 31)
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Attach images (or paste / drop them in)")
                    .accessibilityLabel("Attach images")
                }
                ChatComposer(text: $session.draft, onSend: { send() }, onKey: handleKey,
                             onImages: acceptsImages ? { session.attachments += $0 } : nil,
                             placeholder: "Message \(session.provider.title)…")
                    .frame(height: 57)
                    .padding(.horizontal, 3)
                if isBusy {
                    Button { session.stop() } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 31, height: 31)
                            .background(Color.red.opacity(0.85), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Stop (esc)")
                    .accessibilityLabel("Stop")
                }
                Button { send() } label: {
                    Image(systemName: isBusy ? "text.append" : "arrow.up")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 31, height: 31)
                        .background(violet, in: Circle())
                }
                .disabled(!canSend)
                .buttonStyle(.plain)
                .help(isBusy ? "Queue for after this reply (Return)" : "Send message (Return)")
                .accessibilityLabel(isBusy ? "Queue message" : "Send message")
            }
            footer
        }
        .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 13)
    }
}

/// Allow / Deny for a tool use, like the CLI's permission prompt.
private struct PermissionCard: View {
    let prompt: PermissionPrompt
    let queued: Int
    let accent: Color
    let answer: (_ allow: Bool, _ always: Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                Text("Allow \(prompt.tool)?").font(.system(size: 13, weight: .semibold))
                Spacer()
                if queued > 0 {
                    Text("+\(queued) more").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            ScrollView {
                Text(prompt.summary)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 96).fixedSize(horizontal: false, vertical: true)
            .padding(8)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            HStack(spacing: 8) {
                Button("Deny") { answer(false, false) }
                    .keyboardShortcut(.escape, modifiers: [])
                Spacer()
                if prompt.suggestionsJSON != nil {
                    Button("Always allow") { answer(true, true) }
                        .help("Allow and don't ask again for this (saved like the CLI does)")
                }
                Button { answer(true, false) } label: {
                    Text("Allow").fontWeight(.semibold).foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 4)
                        .background(accent, in: Capsule())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: [.command])
            }
            .controlSize(.small)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.95), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.orange.opacity(0.45), lineWidth: 1))
    }
}

private struct MessageView: View {
    let message: ChatMessage
    let violet: Color
    /// Same icon as the chat header.
    let symbol: String
    /// Only the live reply shows typing dots. A stopped or interrupted empty reply shows nothing.
    let typing: Bool
    @State private var showAllThinking = false
    /// Messenger style entrance: fresh bubbles spring up from their corner.
    @State private var popped = false

    private var isBlank: Bool { message.text.isEmpty && (message.images ?? []).isEmpty }

    private var mine: Bool { message.role == .user }
    private var thinking: String? {
        guard let text = message.thinking?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    var body: some View {
        if message.role == .notice {
            // System lines (hook replies, errors) sit centred in small grey text.
            Text(message.text)
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).textSelection(.enabled)
                .frame(maxWidth: .infinity).padding(.horizontal, 24)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                if !mine, let thinking { thinkingView(thinking) }
                if !isBlank || typing { bubble }
            }
            .scaleEffect(popped ? 1 : 0.55, anchor: mine ? .bottomTrailing : .bottomLeading)
            .offset(y: popped ? 0 : 14)
            .opacity(popped ? 1 : 0)
            .onAppear {
                // Only brand new messages animate; history and scrolled-back rows just show.
                guard !popped else { return }
                if Date().timeIntervalSince(message.date) < 1.5 {
                    withAnimation(.spring(response: 0.36, dampingFraction: 0.62)) { popped = true }
                } else {
                    popped = true
                }
            }
        }
    }

    /// Like the CLI: dim, smaller reasoning text above the reply. Click to expand.
    private func thinkingView(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("∴").font(.system(size: 11, weight: .bold)).foregroundStyle(.tertiary)
            Text(text)
                .font(.system(size: 11)).italic()
                .foregroundStyle(.secondary)
                .lineLimit(showAllThinking ? nil : 3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(.leading, 30).padding(.trailing, 38)
        .contentShape(Rectangle())
        .onTapGesture { showAllThinking.toggle() }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(showAllThinking ? "Collapse thinking" : "Expand thinking")
        .accessibilityAction { showAllThinking.toggle() }
        .help(showAllThinking ? "Click to collapse thinking" : "Click to show all thinking")
    }

    private var bubble: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if mine { Spacer(minLength: 45) }
            if !mine {
                Image(systemName: symbol)
                    .font(.system(size: 16)).foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
            }
            Group {
                if let paths = message.images, !paths.isEmpty {
                    VStack(alignment: .trailing, spacing: 8) {
                        ForEach(paths, id: \.self) { path in
                            if let image = ThumbnailCache.image(atPath: path) {
                                Image(nsImage: image).resizable().scaledToFit()
                                    .frame(maxWidth: 220, maxHeight: 180)
                                    .clipShape(RoundedRectangle(cornerRadius: 9))
                            } else {
                                Label("image", systemImage: "photo").font(.system(size: 12))
                            }
                        }
                        if !message.text.isEmpty { RichText(text: message.text, mine: mine).equatable() }
                    }
                } else if message.text.isEmpty {
                    TypingDots().transition(.opacity)
                } else {
                    RichText(text: message.text, mine: mine).equatable().transition(.opacity)
                }
            }
            // The typing bubble grows into the reply instead of jumping.
            .animation(.spring(response: 0.32, dampingFraction: 0.78), value: message.text.isEmpty)
            .padding(.horizontal, 13).padding(.vertical, 10)
            .background(mine ? violet : Color(nsColor: .controlBackgroundColor).opacity(0.92),
                        in: RoundedRectangle(cornerRadius: 15))
            .foregroundStyle(mine ? Color.white : Color.primary)
            if !mine { Spacer(minLength: 38) }
        }
    }
}

/// Small cache of downscaled images so body doesn't decode full files on every redraw.
private enum ThumbnailCache {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(atPath path: String, maxPixels: Int = 600) -> NSImage? {
        let key = path as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let url = URL(fileURLWithPath: path) as CFURL
        guard let source = CGImageSourceCreateWithURL(url, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        cache.setObject(image, forKey: key)
        return image
    }
}

/// Message text with fenced code blocks pulled out into their own click to copy boxes.
private struct RichText: View, Equatable {
    let text: String
    let mine: Bool
    private let segments: [Segment]

    init(text: String, mine: Bool) {
        self.text = text
        self.mine = mine
        self.segments = Self.parse(text)
    }

    static func == (lhs: RichText, rhs: RichText) -> Bool {
        lhs.text == rhs.text && lhs.mine == rhs.mine
    }

    private enum Segment: Hashable {
        /// One paragraph, so finished ones stay put while a later one streams in.
        case prose(String)
        case code(language: String, body: String)
    }

    private static func parse(_ raw: String) -> [Segment] {
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n")
        var result: [Segment] = []
        var prose: [Substring] = [], code: [Substring] = []
        var language: String?
        var fenceChar: Character = "`"
        var fenceLength = 0
        var fenceIndent = 0
        func flushProse() {
            var paragraph: [Substring] = []
            func flushParagraph() {
                let joined = paragraph.joined(separator: "\n").trimmingCharacters(in: .newlines)
                if !joined.isEmpty { result.append(.prose(joined)) }
                paragraph.removeAll()
            }
            for line in prose {
                if line.trimmingCharacters(in: .whitespaces).isEmpty { flushParagraph() } else { paragraph.append(line) }
            }
            flushParagraph()
            prose.removeAll()
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let indent = line.prefix(while: { $0 == " " || $0 == "\t" }).count
            let first = trimmed.first
            let run = (first == "`" || first == "~") ? trimmed.prefix(while: { $0 == first }).count : 0
            if language != nil {
                // Only a bare run of the same fence char, at least as long as the opener, closes it.
                if first == fenceChar && run >= fenceLength && run == trimmed.count {
                    result.append(.code(language: language ?? "", body: code.joined(separator: "\n")))
                    code.removeAll(); language = nil
                } else {
                    // Drop up to the opener's indent from the body.
                    let strip = min(fenceIndent, indent)
                    code.append(line.dropFirst(strip))
                }
            } else if run >= 3, let first, first == "~" || !trimmed.dropFirst(run).contains("`") {
                // ```ls -la``` on one line has backticks after the opener, so it stays prose.
                flushProse()
                fenceChar = first
                fenceLength = run
                fenceIndent = indent
                language = String(trimmed.dropFirst(run)).trimmingCharacters(in: .whitespaces)
            } else {
                prose.append(line)
            }
        }
        // A block still streaming in shows as code straight away.
        if let lang = language { result.append(.code(language: lang, body: code.joined(separator: "\n"))) }
        flushProse()
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, part in
                switch part {
                case .prose(let prose):
                    ProseView(text: prose, mine: mine).equatable()
                case .code(let language, let body):
                    CodeBlock(language: language, code: body, mine: mine)
                }
            }
        }
    }
}

/// One paragraph. Headings, list items and table rows get a light pass; the rest is inline markdown.
private struct ProseView: View, Equatable {
    let text: String
    let mine: Bool

    private enum Piece {
        case plain(String)
        case heading(level: Int, text: String)
        case item(marker: String, text: String, depth: Int)
        case table(String)
    }

    private static func pieces(_ text: String) -> [Piece] {
        var result: [Piece] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let indent = line.prefix(while: { $0 == " " || $0 == "\t" }).count
            let hashes = trimmed.prefix(while: { $0 == "#" }).count
            if (1...6).contains(hashes), trimmed.dropFirst(hashes).first == " " {
                var title = trimmed.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
                // Closing hashes like "## Title ##".
                while title.hasSuffix("#") { title.removeLast() }
                result.append(.heading(level: hashes, text: title.trimmingCharacters(in: .whitespaces)))
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                result.append(.item(marker: "•", text: String(trimmed.dropFirst(2)), depth: indent / 2))
            } else if let dot = trimmed.firstIndex(of: "."),
                      dot != trimmed.startIndex, dot < trimmed.index(trimmed.startIndex, offsetBy: min(trimmed.count, 4)),
                      trimmed[..<dot].allSatisfy(\.isNumber),
                      trimmed[trimmed.index(after: dot)...].hasPrefix(" ") {
                let rest = trimmed[trimmed.index(after: dot)...].trimmingCharacters(in: .whitespaces)
                result.append(.item(marker: String(trimmed[..<dot]) + ".", text: rest, depth: indent / 2))
            } else if trimmed.hasPrefix("|") {
                if case .table(let rows)? = result.last {
                    result[result.count - 1] = .table(rows + "\n" + trimmed)
                } else { result.append(.table(trimmed)) }
            } else {
                if case .plain(let previous)? = result.last {
                    result[result.count - 1] = .plain(previous + "\n" + String(line))
                } else { result.append(.plain(String(line))) }
            }
        }
        return result
    }

    /// Your own text stays literal so my_var_name isn't turned into markdown.
    private func inline(_ string: String) -> Text {
        mine ? Text(verbatim: string) : Text(.init(string))
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 17
        case 2: return 16
        case 3: return 15
        default: return 14
        }
    }

    var body: some View {
        if mine {
            Text(verbatim: text)
                .textSelection(.enabled)
                .font(.system(size: 13)).lineSpacing(3)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(Self.pieces(text).enumerated()), id: \.offset) { _, piece in
                    switch piece {
                    case .plain(let string):
                        inline(string).font(.system(size: 13))
                            .fixedSize(horizontal: false, vertical: true)
                    case .heading(let level, let string):
                        inline(string).font(.system(size: headingSize(level), weight: .bold))
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 2)
                    case .item(let marker, let string, let depth):
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(marker).font(.system(size: 13))
                                .frame(minWidth: 12, alignment: .trailing)
                            // Without this, a long item gets cut off with "…" instead of wrapping.
                            inline(string).font(.system(size: 13))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.leading, CGFloat(depth) * 12)
                    case .table(let rows):
                        Text(verbatim: rows).font(.system(size: 11.5, design: .monospaced))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .textSelection(.enabled)
            .lineSpacing(3)
            // Agent text can carry any link. Only open web links, never file or app links.
            .environment(\.openURL, OpenURLAction { url in
                ["http", "https"].contains(url.scheme?.lowercased() ?? "") ? .systemAction : .discarded
            })
        }
    }
}

/// Click anywhere on the block to copy it, like Claude on the web.
private struct CodeBlock: View {
    let language: String
    let code: String
    let mine: Bool
    @State private var copied = false
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                Text(language.isEmpty ? "code" : language)
                Spacer(minLength: 8)
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                Text(copied ? "copied" : "copy")
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(Color.primary.opacity(0.06))
            Text(code.isEmpty ? " " : code)
                .font(.system(size: 11.5, design: .monospaced))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(9)
        }
        .foregroundStyle(Color.primary)
        .background(Color(nsColor: .textBackgroundColor).opacity(mine ? 0.92 : 0.75),
                    in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(Color.primary.opacity(hovering ? 0.28 : 0.1), lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onContinuousHover { phase in
            switch phase {
            case .active: hovering = true; NSCursor.pointingHand.set()
            case .ended: hovering = false; NSCursor.arrow.set()
            }
        }
        .onTapGesture { copy() }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Copy code")
        .accessibilityAction { copy() }
        .help("Click to copy")
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        withAnimation(.easeOut(duration: 0.15)) { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation(.easeOut(duration: 0.2)) { copied = false }
        }
    }
}

/// Messenger style typing indicator: the dots rise and darken one after another.
private struct TypingDots: View {
    var body: some View {
        TimelineView(.animation) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { index in
                    let phase = time * 2 * .pi / 1.3 - Double(index) * 0.75
                    let lift = max(0, sin(phase))
                    Circle().fill(Color.secondary)
                        .frame(width: 7, height: 7)
                        .opacity(0.35 + 0.65 * lift)
                        .offset(y: -3.5 * lift)
                }
            }
            .frame(height: 20)
        }
    }
}

private extension PermissionMode {
    /// Roughly the CLI's footer colours.
    var tint: Color {
        switch self {
        case .default: return .secondary
        case .acceptEdits: return Color(red: 0.62, green: 0.45, blue: 0.95)
        case .plan: return Color(red: 0.20, green: 0.68, blue: 0.66)
        case .auto: return Color(red: 0.90, green: 0.62, blue: 0.10)
        case .bypassPermissions, .dontAsk: return Color(red: 0.92, green: 0.30, blue: 0.30)
        }
    }
}

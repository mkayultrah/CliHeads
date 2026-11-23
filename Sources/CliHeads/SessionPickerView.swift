import AppKit
import SwiftUI

/// A local browser of existing CLI transcripts. No network calls, and no
/// transcript file is modified. The selected CLI resumes itself by UUID.
struct SessionPickerView: View {
    let existing: Set<String>
    let onResume: (DiscoveredSession) -> Void
    let onManualResume: (AgentProvider, String, String) -> Void
    let onNew: (AgentProvider, String) -> Void

    @State private var discovered: [DiscoveredSession] = []
    @State private var loading = true
    @State private var searchText = ""
    @State private var provider: AgentProvider = .claude
    @State private var directory = NSHomeDirectory()
    @State private var manualID = ""
    @State private var selected: String?

    private var filtered: [DiscoveredSession] {
        discovered.filter { item in
            (searchText.isEmpty || (item.title + " " + item.directory + " " + item.sessionID)
                .localizedCaseInsensitiveContains(searchText)) && item.provider == provider
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Conversations").font(.system(size: 24, weight: .bold))
                    Text("Create a fresh CLI chat or reopen an existing conversation.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Refresh") { refresh() }.disabled(loading)
            }
            HStack {
                Picker("Agent", selection: $provider) {
                    ForEach(AgentProvider.allCases) { agent in
                        Text(agent.title).tag(agent)
                    }
                }.frame(width: 220)
                TextField("Search recent chats, folders or session IDs", text: $searchText)
                    .textFieldStyle(.roundedBorder)
            }
            GroupBox("Recent CLI chats") {
                if loading {
                    ProgressView("Finding local sessions…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if filtered.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "text.bubble").font(.system(size: 24))
                        Text("No matching chats found")
                        Text("You can resume using a session ID below, or create a new chat.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(selection: $selected) {
                        ForEach(filtered) { item in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "bubble.left.fill")
                                    .foregroundStyle(.secondary).padding(.top, 3)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.title).font(.system(size: 12, weight: .medium)).lineLimit(2)
                                    Text(item.directory).font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.secondary).lineLimit(1)
                                    Text(item.modified, format: .dateTime.day().month().year().hour().minute())
                                        .font(.caption2).foregroundStyle(.tertiary)
                                }
                                Spacer()
                                if existing.contains(item.id) {
                                    Text("OPEN").font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                            .tag(item.id)
                            .contentShape(Rectangle())
                        }
                    }
                    // Double click or Return opens the row.
                    .contextMenu(forSelectionType: String.self) { _ in
                        EmptyView()
                    } primaryAction: { ids in
                        if let id = ids.first, let item = filtered.first(where: { $0.id == id }) { onResume(item) }
                    }
                }
            }.frame(maxHeight: .infinity)
            HStack {
                Text("Working folder:").font(.caption).foregroundStyle(.secondary)
                Text(directory).font(.system(size: 10, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Choose…") { chooseDirectory() }
            }
            HStack(spacing: 10) {
                Button("New \(provider.title) chat") { onNew(provider, directory) }
                    .buttonStyle(.borderedProminent)
                Button("Open selected") {
                    if let selected, let item = filtered.first(where: { $0.id == selected }) {
                        onResume(item)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selected == nil || !filtered.contains(where: { $0.id == selected }))
                Spacer()
            }
            Divider()
            HStack {
                TextField("Resume by UUID / session ID", text: $manualID)
                    .textFieldStyle(.roundedBorder)
                Button("Resume ID") {
                    let id = manualID.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !id.isEmpty { onManualResume(provider, id, directory) }
                }.disabled(manualID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Text("Resume ID uses the working folder above. Only one CliHeads window per saved session; do not open the same session concurrently in Terminal.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(19)
        .frame(width: 680, height: 640)
        .onAppear { refresh() }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        if panel.runModal() == .OK, let url = panel.url { directory = url.path }
    }

    private func refresh() {
        loading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let items = SessionCatalog.discover()
            DispatchQueue.main.async {
                discovered = items
                loading = false
            }
        }
    }
}

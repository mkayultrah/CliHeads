import Foundation

struct ChatMessage: Identifiable, Codable, Equatable {
    enum Role: String, Codable { case user, assistant, notice }
    var id: UUID = UUID()
    var role: Role
    var text: String
    var date: Date = Date()
    /// Model reasoning shown above the reply in small grey text, like the CLI.
    var thinking: String? = nil
    /// Paths of images sent with this message (kept in Application Support).
    var images: [String]? = nil
}

/// Old v0.1/v0.2 heads.json uses `claudeSessionID`. The decoder deliberately
/// migrates those saves in-place so existing bubbles and transcripts survive.
struct SavedHead: Codable {
    var id: UUID
    var title: String
    var directory: String
    var provider: AgentProvider
    var agentSessionID: String?
    var messages: [ChatMessage]
    var x: Double?
    var y: Double?
    /// Shift+tab mode the head was last on, as the PermissionMode raw value.
    var permissionMode: String?

    enum CodingKeys: String, CodingKey {
        case id, title, directory, provider, agentSessionID, claudeSessionID, messages, x, y, permissionMode
    }

    init(id: UUID = UUID(), title: String, directory: String, provider: AgentProvider,
         agentSessionID: String? = nil, messages: [ChatMessage] = [], x: Double? = nil, y: Double? = nil,
         permissionMode: String? = nil) {
        self.id = id; self.title = title; self.directory = directory
        self.provider = provider; self.agentSessionID = agentSessionID
        self.messages = messages; self.x = x; self.y = y
        self.permissionMode = permissionMode
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        directory = try c.decode(String.self, forKey: .directory)
        provider = try c.decodeIfPresent(AgentProvider.self, forKey: .provider) ?? .claude
        agentSessionID = try c.decodeIfPresent(String.self, forKey: .agentSessionID)
            ?? c.decodeIfPresent(String.self, forKey: .claudeSessionID)
        messages = try c.decodeIfPresent([ChatMessage].self, forKey: .messages) ?? []
        x = try c.decodeIfPresent(Double.self, forKey: .x)
        y = try c.decodeIfPresent(Double.self, forKey: .y)
        permissionMode = try c.decodeIfPresent(String.self, forKey: .permissionMode)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(title, forKey: .title)
        try c.encode(directory, forKey: .directory); try c.encode(provider, forKey: .provider)
        try c.encodeIfPresent(agentSessionID, forKey: .agentSessionID)
        try c.encode(messages, forKey: .messages)
        try c.encodeIfPresent(x, forKey: .x); try c.encodeIfPresent(y, forKey: .y)
        try c.encodeIfPresent(permissionMode, forKey: .permissionMode)
    }
}


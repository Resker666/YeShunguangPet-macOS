import Foundation

public enum ChatModel: String, Codable, CaseIterable, Sendable {
    case flash = "deepseek-flash"
    case pro = "deepseek-v4-pro"
}

public struct ChatConnection: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var model: ChatModel
    public init(enabled: Bool = false, model: ChatModel = .flash) {
        self.enabled = enabled
        self.model = model
    }
}

public struct ChatProfile: Codable, Equatable, Sendable {
    public var background, personality, speakingStyle, examples: String
    public init(background: String = "", personality: String = "", speakingStyle: String = "", examples: String = "") {
        self.background = background
        self.personality = personality
        self.speakingStyle = speakingStyle
        self.examples = examples
    }
    public func validate() throws {
        for (text, limit) in [(background, 2000), (personality, 1000), (speakingStyle, 1000), (examples, 2000)] {
            try ChatText.validate(text, maxUTF16: limit, allowEmpty: true)
        }
    }
    func prompt(characterName: String) -> String {
        """
        你正在以桌宠角色「\(characterName)」进行自然、亲切的虚构角色扮演。以下是用户自定义的非官方演绎，不代表原作官方设定。
        结合设定和对话，用角色口吻回应，不要每次重复自我介绍。你只能看到本次提供的人设和聊天文字，不要声称读取了桌面、屏幕、文件或其他未提供的信息。
        背景：\(background)
        性格：\(personality)
        说话风格：\(speakingStyle)
        示例台词：\(examples)
        """
    }
}

public struct ChatMessage: Codable, Equatable, Sendable {
    public enum Role: String, Codable, Sendable { case system, user, assistant }
    public let role: Role
    public let content: String
    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }
}

public struct ChatConversation: Codable, Equatable, Sendable {
    public let characterID: String
    public let profile: ChatProfile
    public let messages: [ChatMessage]
    public init(characterID: String, profile: ChatProfile = .init(), messages: [ChatMessage] = []) throws {
        self.characterID = characterID
        self.profile = profile
        self.messages = messages
        try validate()
    }
    public func validate() throws {
        guard ManifestDecoder.isValidID(characterID), messages.count <= 24, messages.count.isMultiple(of: 2) else {
            throw SkinError("角色聊天标识或完整对话轮次无效。")
        }
        try profile.validate()
        for (index, message) in messages.enumerated() {
            guard message.role == (index.isMultiple(of: 2) ? .user : .assistant) else {
                throw SkinError("聊天记录必须由完整的提问和回答交替组成。")
            }
            try ChatText.validate(message.content, maxUTF16: message.role == .user ? 2000 : 8000, allowEmpty: false)
        }
    }
    public func appending(user: String, assistant: String) throws -> Self {
        try validate()
        try ChatText.validate(user, maxUTF16: 2000, allowEmpty: false)
        try ChatText.validate(assistant, maxUTF16: 8000, allowEmpty: false)
        let next = messages + [
            ChatMessage(role: .user, content: user.trimmingCharacters(in: .whitespacesAndNewlines)),
            ChatMessage(role: .assistant, content: assistant.trimmingCharacters(in: .whitespacesAndNewlines))
        ]
        return try Self(characterID: characterID, profile: profile, messages: Array(next.suffix(24)))
    }
}

public struct ChatPromptSnapshot: Equatable, Sendable {
    public let characterID: String
    public let model: ChatModel
    public let messages: [ChatMessage]
    public init(characterID: String, characterName: String, conversation: ChatConversation, model: ChatModel, input: String) throws {
        try conversation.validate()
        guard characterID == conversation.characterID else { throw SkinError("当前角色与聊天记录不匹配。") }
        try ChatText.validate(characterName, maxUTF16: 64, allowEmpty: false)
        try ChatText.validate(input, maxUTF16: 2000, allowEmpty: false)
        self.characterID = characterID
        self.model = model
        self.messages = [ChatMessage(role: .system, content: conversation.profile.prompt(characterName: characterName))]
            + conversation.messages
            + [ChatMessage(role: .user, content: input.trimmingCharacters(in: .whitespacesAndNewlines))]
    }
}

import Foundation

public protocol TranscriptParser: Sendable {
    func parse(_ data: Data, agent: AgentKind) throws -> [AgentActivityBlock]
}

public enum TranscriptParserError: Error, Equatable {
    case invalidUTF8
}

public struct CodexTranscriptParser: TranscriptParser {
    public init() {}

    public func parse(_ data: Data, agent: AgentKind = .codex) throws -> [AgentActivityBlock] {
        guard let text = String(data: data, encoding: .utf8) else {
            throw TranscriptParserError.invalidUTF8
        }

        return text
            .split(whereSeparator: \.isNewline)
            .compactMap { parseLine(String($0)) }
    }

    private func parseLine(_ line: String) -> AgentActivityBlock? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        let payload = (object["payload"] as? [String: Any]) ?? object
        let envelopeType = object["type"] as? String
        let payloadType = payload["type"] as? String
        let role = payload["role"] as? String
        let itemType = payload["item_type"] as? String
        let message = payload["message"] as? String
        let body = extractBody(from: payload)
        let kind = classifyCodexBlock(envelopeType: envelopeType, payloadType: payloadType, role: role, itemType: itemType, body: body)
        let title = titleFor(kind: kind, type: payloadType ?? envelopeType, itemType: itemType, payload: payload)

        guard !body.isEmpty || message != nil else {
            return nil
        }

        var metadata: [String: String] = [:]
        metadata["envelopeType"] = envelopeType
        metadata["payloadType"] = payloadType
        metadata["role"] = role
        metadata["itemType"] = itemType
        metadata["name"] = payload["name"] as? String
        metadata["callId"] = (payload["call_id"] as? String) ?? (payload["callId"] as? String)
        metadata["itemId"] = (payload["id"] as? String) ?? (payload["item_id"] as? String)
        metadata["status"] = payload["status"] as? String
        metadata["arguments"] = payload["arguments"] as? String
        metadata["output"] = payload["output"] as? String
        metadata["createdAt"] = (payload["created_at"] as? String) ?? (payload["createdAt"] as? String)

        return AgentActivityBlock(
            kind: kind,
            title: title,
            body: body.isEmpty ? (message ?? "") : body,
            metadata: metadata.compactMapValues { $0 },
            createdAt: Self.createdAt(from: payload)
        )
    }

    private static func createdAt(from payload: [String: Any]) -> Date? {
        if let timestamp = payload["created_at"] as? TimeInterval {
            return Date(timeIntervalSince1970: timestamp)
        }

        if let timestamp = payload["createdAt"] as? TimeInterval {
            return Date(timeIntervalSince1970: timestamp)
        }

        if let value = (payload["created_at"] as? String) ?? (payload["createdAt"] as? String) {
            return ISO8601DateFormatter().date(from: value)
        }

        return nil
    }

    private func extractBody(from object: [String: Any]) -> String {
        if let text = object["text"] as? String {
            return text
        }

        if let message = object["message"] as? String {
            return message
        }

        if let name = object["name"] as? String {
            let arguments = object["arguments"] as? String
            let output = object["output"] as? String
            return [name, arguments, output]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        }

        if let output = object["output"] as? String {
            return output
        }

        if let content = object["content"] as? [[String: Any]] {
            let parts = content.compactMap { item -> String? in
                if let text = item["text"] as? String {
                    return text
                }

                if let output = item["output"] as? String {
                    return output
                }

                return nil
            }
            let joined = parts.joined(separator: "\n")
            if !joined.isEmpty {
                return joined
            }
        }

        if let summary = object["summary"] as? [[String: Any]] {
            let parts = summary.compactMap { item -> String? in
                item["text"] as? String
            }
            let joined = parts.joined(separator: "\n")
            if !joined.isEmpty {
                return joined
            }
        }

        if let item = object["item"] as? [String: Any] {
            if let text = item["text"] as? String {
                return text
            }

            if let content = item["content"] as? String {
                return content
            }

            if let name = item["name"] as? String {
                return name
            }
        }

        if let summary = object["summary"] as? String {
            return summary
        }

        return ""
    }

    private func classifyCodexBlock(envelopeType: String?, payloadType: String?, role: String?, itemType: String?, body: String) -> AgentActivityKind {
        switch payloadType {
        case "message":
            if role == "user" {
                return .userMessage
            }

            if role == "assistant" {
                return .assistantMessage
            }
        case "function_call", "function_call_output", "custom_tool_call", "custom_tool_call_output":
            return .toolCall
        case "reasoning":
            return .thinking
        case "plan", "todo_list":
            return .plan
        case "approval_request":
            return .approval
        default:
            break
        }

        if role == "user" {
            return .userMessage
        }

        if role == "assistant" {
            return .assistantMessage
        }

        let combined = [envelopeType, payloadType, itemType, body].compactMap { $0?.lowercased() }.joined(separator: " ")

        if combined.contains("tool") || combined.contains("function") {
            return .toolCall
        }

        if combined.contains("plan") || combined.contains("todo") {
            return .plan
        }

        if combined.contains("approval") || combined.contains("confirm") {
            return .approval
        }

        if combined.contains("think") || combined.contains("reason") {
            return .thinking
        }

        return .system
    }

    private func titleFor(kind: AgentActivityKind, type: String?, itemType: String?, payload: [String: Any]) -> String {
        switch kind {
        case .userMessage:
            return "User"
        case .assistantMessage:
            return "Assistant"
        case .thinking:
            return "Thinking"
        case .toolCall:
            if type == "function_call_output" || type == "custom_tool_call_output" {
                return "Tool Output"
            }

            return (payload["name"] as? String) ?? "Tool Call"
        case .plan:
            return "Plan"
        case .approval:
            return "Approval"
        case .file:
            return "File"
        case .system:
            return itemType ?? type ?? "System"
        }
    }
}

public struct AgentActivityCompactionOptions: Equatable, Sendable {
    public var maxPreviewCharacters: Int
    public var mergeConsecutiveSystemBlocks: Bool
    public var mergeConsecutiveThinkingBlocks: Bool
    public var mergeConsecutivePlanBlocks: Bool

    public init(
        maxPreviewCharacters: Int = 320,
        mergeConsecutiveSystemBlocks: Bool = true,
        mergeConsecutiveThinkingBlocks: Bool = true,
        mergeConsecutivePlanBlocks: Bool = true
    ) {
        self.maxPreviewCharacters = maxPreviewCharacters
        self.mergeConsecutiveSystemBlocks = mergeConsecutiveSystemBlocks
        self.mergeConsecutiveThinkingBlocks = mergeConsecutiveThinkingBlocks
        self.mergeConsecutivePlanBlocks = mergeConsecutivePlanBlocks
    }
}

public struct AgentActivityCompactor: Sendable {
    public var options: AgentActivityCompactionOptions

    public init(options: AgentActivityCompactionOptions = AgentActivityCompactionOptions()) {
        self.options = options
    }

    public init(maxPreviewCharacters: Int) {
        self.options = AgentActivityCompactionOptions(maxPreviewCharacters: maxPreviewCharacters)
    }

    public func compact(_ blocks: [AgentActivityBlock]) -> [CompactedAgentActivityCard] {
        var cards: [CompactedAgentActivityCard] = []
        var pendingGroup: ActivityGroup?

        for block in blocks {
            let key = groupKey(for: block)

            if var group = pendingGroup,
               block.kind == .toolCall,
               block.title == "Tool Output",
               block.metadata["callId"] == nil,
               block.metadata["itemId"] == nil,
               group.blocks.last?.kind == .toolCall {
                group.blocks.append(block)
                pendingGroup = group
                continue
            }

            if var group = pendingGroup, group.key == key {
                group.blocks.append(block)
                pendingGroup = group
                continue
            }

            if let pendingGroup {
                cards.append(card(for: pendingGroup))
            }

            pendingGroup = ActivityGroup(key: key, blocks: [block])
        }

        if let pendingGroup {
            cards.append(card(for: pendingGroup))
        }

        return cards
    }

    public func expandedBlocks(for card: CompactedAgentActivityCard, in blocks: [AgentActivityBlock]) -> [AgentActivityBlock] {
        let ids = Set(card.sourceBlockIds)
        return blocks.filter { ids.contains($0.id) }
    }

    private func groupKey(for block: AgentActivityBlock) -> String {
        if block.kind == .toolCall {
            if let callId = block.metadata["callId"] {
                return "tool:\(callId)"
            }

            if let itemId = block.metadata["itemId"] {
                return "tool:\(itemId)"
            }

            return "tool:\(block.id.uuidString)"
        }

        switch block.kind {
        case .thinking where options.mergeConsecutiveThinkingBlocks:
            return block.kind.rawValue
        case .plan where options.mergeConsecutivePlanBlocks:
            return block.kind.rawValue
        case .system where options.mergeConsecutiveSystemBlocks:
            return block.kind.rawValue
        default:
            return "\(block.kind.rawValue):\(block.id.uuidString)"
        }
    }

    private func card(for group: ActivityGroup) -> CompactedAgentActivityCard {
        let first = group.blocks[0]
        let title = title(for: group.blocks, fallback: first.title)
        let preview = preview(for: group.blocks)
        var metadata = first.metadata
        metadata["compactionKey"] = group.key
        metadata["sourceKinds"] = joinedUnique(group.blocks.map { $0.kind.rawValue })
        metadata["toolNames"] = joinedUnique(toolNames(from: group.blocks))
        metadata["hiddenCharacterCount"] = String(hiddenCharacterCount(for: group.blocks, preview: preview))
        metadata["hiddenBlockCount"] = String(max(0, group.blocks.count - 1))
        metadata["status"] = group.blocks.reversed().compactMap { $0.metadata["status"] }.first
        metadata["callId"] = group.blocks.compactMap { $0.metadata["callId"] }.first

        if group.blocks.count > 1 {
            metadata["blockCount"] = String(group.blocks.count)
        }

        return CompactedAgentActivityCard(
            kind: first.kind,
            title: title,
            preview: preview,
            blockCount: group.blocks.count,
            sourceBlockIds: group.blocks.map(\.id),
            metadata: metadata.compactMapValues { $0 },
            createdAt: first.createdAt
        )
    }

    private func title(for blocks: [AgentActivityBlock], fallback: String) -> String {
        if blocks[0].kind == .toolCall {
            return blocks.first { block in
                block.title != "Tool Call" && block.title != "Tool Output"
            }?.title ?? fallback
        }

        return fallback
    }

    private func preview(for blocks: [AgentActivityBlock]) -> String {
        let joined = blocks
            .map { block in
                if blocks.count == 1 {
                    return block.body
                }

                return "\(block.title)\n\(block.body)"
            }
            .joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return truncate(joined)
    }

    private func truncate(_ text: String) -> String {
        guard text.count > options.maxPreviewCharacters else {
            return text
        }

        let end = text.index(text.startIndex, offsetBy: options.maxPreviewCharacters)
        return String(text[..<end]).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }

    private func hiddenCharacterCount(for blocks: [AgentActivityBlock], preview: String) -> Int {
        let bodyCount = blocks.reduce(0) { partialResult, block in
            partialResult + block.body.count
        }

        return max(0, bodyCount - preview.count)
    }

    private func toolNames(from blocks: [AgentActivityBlock]) -> [String] {
        blocks
            .filter { $0.kind == .toolCall }
            .map(\.title)
            .filter { $0 != "Tool Call" && $0 != "Tool Output" }
    }

    private func joinedUnique(_ values: [String]) -> String? {
        var seen = Set<String>()
        let uniqueValues = values.filter { value in
            guard !value.isEmpty, !seen.contains(value) else {
                return false
            }

            seen.insert(value)
            return true
        }

        guard !uniqueValues.isEmpty else {
            return nil
        }

        return uniqueValues.joined(separator: ",")
    }

    private struct ActivityGroup {
        var key: String
        var blocks: [AgentActivityBlock]
    }
}

public struct TranscriptCorrelator: Sendable {
    public init() {}

    public func bestMatch(for pane: TmuxPane, candidates: [TranscriptLink]) -> TranscriptLink? {
        guard !candidates.isEmpty else {
            return nil
        }

        if let currentPath = pane.currentPath {
            let pathMatched = candidates.first { candidate in
                candidate.remotePath.contains(currentPath)
            }
            if let pathMatched {
                return pathMatched
            }
        }

        if let command = pane.currentCommand?.lowercased() {
            if command.contains("codex"), let codex = candidates.first(where: { $0.agent == .codex }) {
                return codex
            }

            if command.contains("claude"), let claude = candidates.first(where: { $0.agent == .claude }) {
                return claude
            }
        }

        return candidates.first
    }
}

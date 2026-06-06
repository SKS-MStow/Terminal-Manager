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

        let type = object["type"] as? String
        let role = object["role"] as? String
        let itemType = object["item_type"] as? String
        let message = object["message"] as? String
        let body = extractBody(from: object)
        let kind = classifyCodexBlock(type: type, role: role, itemType: itemType, body: body)
        let title = titleFor(kind: kind, type: type, itemType: itemType)

        guard !body.isEmpty || message != nil else {
            return nil
        }

        var metadata: [String: String] = [:]
        metadata["type"] = type
        metadata["role"] = role
        metadata["itemType"] = itemType

        return AgentActivityBlock(
            kind: kind,
            title: title,
            body: body.isEmpty ? (message ?? "") : body,
            metadata: metadata.compactMapValues { $0 }
        )
    }

    private func extractBody(from object: [String: Any]) -> String {
        if let text = object["text"] as? String {
            return text
        }

        if let message = object["message"] as? String {
            return message
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

    private func classifyCodexBlock(type: String?, role: String?, itemType: String?, body: String) -> AgentActivityKind {
        let combined = [type, role, itemType, body].compactMap { $0?.lowercased() }.joined(separator: " ")

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

        if role == "user" {
            return .userMessage
        }

        if role == "assistant" {
            return .assistantMessage
        }

        return .system
    }

    private func titleFor(kind: AgentActivityKind, type: String?, itemType: String?) -> String {
        switch kind {
        case .userMessage:
            return "User"
        case .assistantMessage:
            return "Assistant"
        case .thinking:
            return "Thinking"
        case .toolCall:
            return "Tool Call"
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

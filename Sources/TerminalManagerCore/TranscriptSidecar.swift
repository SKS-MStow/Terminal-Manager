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

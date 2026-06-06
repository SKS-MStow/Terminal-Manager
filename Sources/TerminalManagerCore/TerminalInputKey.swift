import Foundation

public enum TerminalInputKey: String, CaseIterable, Identifiable, Sendable {
    case escape
    case tab
    case tmuxPrefix
    case controlC
    case arrowLeft
    case arrowDown
    case arrowUp
    case arrowRight
    case enter
    case backspace

    public var id: String {
        rawValue
    }

    public var label: String {
        switch self {
        case .escape:
            return "Esc"
        case .tab:
            return "Tab"
        case .tmuxPrefix:
            return "C-b"
        case .controlC:
            return "C-c"
        case .arrowLeft:
            return "Left"
        case .arrowDown:
            return "Down"
        case .arrowUp:
            return "Up"
        case .arrowRight:
            return "Right"
        case .enter:
            return "Enter"
        case .backspace:
            return "Backspace"
        }
    }

    public var systemImageName: String? {
        switch self {
        case .arrowLeft:
            return "arrow.left"
        case .arrowDown:
            return "arrow.down"
        case .arrowUp:
            return "arrow.up"
        case .arrowRight:
            return "arrow.right"
        case .enter:
            return "return"
        case .backspace:
            return "delete.left"
        default:
            return nil
        }
    }

    public var bytes: Data {
        switch self {
        case .escape:
            return Data([0x1B])
        case .tab:
            return Data([0x09])
        case .tmuxPrefix:
            return Data([0x02])
        case .controlC:
            return Data([0x03])
        case .arrowLeft:
            return Data("\u{1B}[D".utf8)
        case .arrowDown:
            return Data("\u{1B}[B".utf8)
        case .arrowUp:
            return Data("\u{1B}[A".utf8)
        case .arrowRight:
            return Data("\u{1B}[C".utf8)
        case .enter:
            return Data([0x0D])
        case .backspace:
            return Data([0x7F])
        }
    }
}

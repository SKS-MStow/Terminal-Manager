import Foundation

public struct TerminalScrollbackBuffer: Sendable, Equatable {
    public private(set) var maxLineCount: Int

    private var history: [[UnicodeScalar]]
    private var currentLine: [UnicodeScalar]
    private var cursorColumn: Int
    private var parserState: ParserState

    public var lines: [String] {
        var rendered = history.map { String(String.UnicodeScalarView($0)) }
        if !currentLine.isEmpty || rendered.isEmpty {
            rendered.append(String(String.UnicodeScalarView(currentLine)))
        }
        return rendered
    }

    public init(lines: [String] = [], maxLineCount: Int = 1_000) {
        self.maxLineCount = max(1, maxLineCount)
        if let last = lines.last {
            self.history = lines.dropLast().map { Array($0.unicodeScalars) }
            self.currentLine = Array(last.unicodeScalars)
            self.cursorColumn = self.currentLine.count
        } else {
            self.history = []
            self.currentLine = []
            self.cursorColumn = 0
        }
        self.parserState = .normal
        trimToLimit()
    }

    public mutating func reset(lines: [String] = []) {
        self = TerminalScrollbackBuffer(lines: lines, maxLineCount: maxLineCount)
    }

    public mutating func append(_ text: String) {
        for scalar in text.unicodeScalars {
            consume(scalar)
        }
        trimToLimit()
    }

    private mutating func consume(_ scalar: UnicodeScalar) {
        switch parserState {
        case .normal:
            consumeNormal(scalar)
        case .escape:
            if scalar == "[" {
                parserState = .csi("")
            } else if scalar == "]" {
                parserState = .osc
            } else {
                parserState = .normal
            }
        case .csi(let parameters):
            if scalar.value >= 0x40 && scalar.value <= 0x7E {
                handleCSI(parameters: parameters, final: scalar)
                parserState = .normal
            } else {
                parserState = .csi(parameters + String(scalar))
            }
        case .osc:
            if scalar == "\u{07}" {
                parserState = .normal
            } else if scalar == "\u{1B}" {
                parserState = .oscEscape
            }
        case .oscEscape:
            if scalar == "\\" {
                parserState = .normal
            } else {
                parserState = .osc
            }
        }
    }

    private mutating func consumeNormal(_ scalar: UnicodeScalar) {
        switch scalar {
        case "\u{1B}":
            parserState = .escape
        case "\r":
            cursorColumn = 0
        case "\n":
            history.append(currentLine)
            currentLine = []
            cursorColumn = 0
        case "\u{08}":
            cursorColumn = max(0, cursorColumn - 1)
        case "\t":
            let spaces = max(1, 4 - (cursorColumn % 4))
            for _ in 0..<spaces {
                write(" ")
            }
        default:
            guard !CharacterSet.controlCharacters.contains(scalar) else {
                return
            }
            write(scalar)
        }
    }

    private mutating func handleCSI(parameters: String, final: UnicodeScalar) {
        switch final {
        case "K":
            clearLine(parameters: parameters)
        case "G":
            cursorColumn = max(0, firstParameter(parameters, defaultValue: 1) - 1)
        case "C":
            cursorColumn += max(1, firstParameter(parameters, defaultValue: 1))
        case "D":
            cursorColumn = max(0, cursorColumn - max(1, firstParameter(parameters, defaultValue: 1)))
        default:
            break
        }
    }

    private mutating func clearLine(parameters: String) {
        let mode = firstParameter(parameters, defaultValue: 0)
        switch mode {
        case 1:
            let eraseCount = min(cursorColumn + 1, currentLine.count)
            guard eraseCount > 0 else {
                return
            }
            currentLine.replaceSubrange(
                0..<eraseCount,
                with: Array(repeating: UnicodeScalar(" "), count: eraseCount)
            )
        case 2:
            currentLine.removeAll()
            cursorColumn = 0
        default:
            if cursorColumn < currentLine.count {
                currentLine.removeSubrange(cursorColumn..<currentLine.count)
            }
        }
    }

    private mutating func write(_ scalar: UnicodeScalar) {
        if cursorColumn < currentLine.count {
            currentLine[cursorColumn] = scalar
        } else {
            if cursorColumn > currentLine.count {
                currentLine.append(contentsOf: Array(repeating: UnicodeScalar(" "), count: cursorColumn - currentLine.count))
            }
            currentLine.append(scalar)
        }
        cursorColumn += 1
    }

    private func firstParameter(_ parameters: String, defaultValue: Int) -> Int {
        let trimmed = parameters.trimmingCharacters(in: CharacterSet(charactersIn: "?"))
        return trimmed
            .split(separator: ";", omittingEmptySubsequences: false)
            .first
            .flatMap { Int($0) }
            ?? defaultValue
    }

    private mutating func trimToLimit() {
        while lines.count > maxLineCount, !history.isEmpty {
            history.removeFirst()
        }
    }
}

private enum ParserState: Sendable, Equatable {
    case normal
    case escape
    case csi(String)
    case osc
    case oscEscape
}

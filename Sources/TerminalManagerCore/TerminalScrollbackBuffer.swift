import Foundation

public struct TerminalScrollbackBuffer: Sendable, Equatable {
    public private(set) var maxLineCount: Int

    private var rows: [[UnicodeScalar]]
    private var cursorRow: Int
    private var cursorColumn: Int
    private var columnCount: Int?
    private var pendingAutoWrap: Bool
    private var parserState: ParserState

    public var lines: [String] {
        rows.map(Self.renderRow)
    }

    public init(lines: [String] = [], maxLineCount: Int = 1_000, size: TerminalSize? = nil) {
        self.maxLineCount = max(1, maxLineCount)
        self.rows = lines.isEmpty ? [[]] : lines.map { Array($0.unicodeScalars) }
        self.cursorRow = max(0, self.rows.count - 1)
        self.cursorColumn = self.rows.last?.count ?? 0
        self.columnCount = size.map { max(1, $0.columns) }
        self.pendingAutoWrap = false
        self.parserState = .normal
        if let columnCount {
            reflowRows(to: columnCount)
        }
        trimToLimit()
    }

    public mutating func reset(lines: [String] = []) {
        self = TerminalScrollbackBuffer(
            lines: lines,
            maxLineCount: maxLineCount,
            size: columnCount.map { TerminalSize(columns: $0, rows: maxLineCount) }
        )
    }

    public mutating func resize(to size: TerminalSize) {
        let newColumnCount = max(1, size.columns)
        columnCount = newColumnCount
        reflowRows(to: newColumnCount)
        pendingAutoWrap = false
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
            pendingAutoWrap = false
            parserState = .escape
        case "\r":
            pendingAutoWrap = false
            cursorColumn = 0
        case "\n":
            pendingAutoWrap = false
            lineFeed()
        case "\u{08}":
            pendingAutoWrap = false
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
        let values = numericParameters(parameters)
        pendingAutoWrap = false

        switch final {
        case "A":
            cursorRow = max(0, cursorRow - max(1, values.first ?? 1))
        case "B":
            cursorRow += max(1, values.first ?? 1)
            ensureRow(cursorRow)
        case "C":
            cursorColumn += max(1, values.first ?? 1)
            clampCursorColumn()
        case "D":
            cursorColumn = max(0, cursorColumn - max(1, values.first ?? 1))
        case "G":
            cursorColumn = max(0, firstParameter(parameters, defaultValue: 1) - 1)
            clampCursorColumn()
        case "H", "f":
            let row = max(1, values.indices.contains(0) ? values[0] : 1)
            let column = max(1, values.indices.contains(1) ? values[1] : 1)
            cursorRow = row - 1
            cursorColumn = column - 1
            clampCursorColumn()
            ensureRow(cursorRow)
        case "J":
            clearDisplay(parameters: parameters)
        case "K":
            clearLine(parameters: parameters)
        default:
            break
        }
    }

    private mutating func clearDisplay(parameters: String) {
        let mode = firstParameter(parameters, defaultValue: 0)
        ensureRow(cursorRow)

        switch mode {
        case 1:
            for rowIndex in 0..<cursorRow {
                rows[rowIndex].removeAll()
            }
            clearLine(parameters: "1")
        case 2, 3:
            rows = [[]]
            cursorRow = 0
            cursorColumn = 0
        default:
            clearLine(parameters: "0")
            if cursorRow + 1 < rows.count {
                rows.removeSubrange((cursorRow + 1)..<rows.count)
            }
        }
    }

    private mutating func clearLine(parameters: String) {
        ensureRow(cursorRow)

        let mode = firstParameter(parameters, defaultValue: 0)
        switch mode {
        case 1:
            let eraseCount = min(cursorColumn + 1, rows[cursorRow].count)
            guard eraseCount > 0 else {
                return
            }
            rows[cursorRow].replaceSubrange(
                0..<eraseCount,
                with: Array(repeating: UnicodeScalar(" "), count: eraseCount)
            )
        case 2:
            rows[cursorRow].removeAll()
        default:
            if cursorColumn < rows[cursorRow].count {
                rows[cursorRow].removeSubrange(cursorColumn..<rows[cursorRow].count)
            }
        }
    }

    private mutating func write(_ scalar: UnicodeScalar) {
        if pendingAutoWrap {
            lineFeed()
            pendingAutoWrap = false
        }

        ensureRow(cursorRow)
        if let columnCount, cursorColumn >= columnCount {
            lineFeed()
            ensureRow(cursorRow)
        }

        if cursorColumn < rows[cursorRow].count {
            rows[cursorRow][cursorColumn] = scalar
        } else {
            if cursorColumn > rows[cursorRow].count {
                rows[cursorRow].append(
                    contentsOf: Array(repeating: UnicodeScalar(" "), count: cursorColumn - rows[cursorRow].count)
                )
            }
            rows[cursorRow].append(scalar)
        }

        if let columnCount, cursorColumn == columnCount - 1 {
            pendingAutoWrap = true
        } else {
            cursorColumn += 1
        }
    }

    private mutating func lineFeed() {
        cursorRow += 1
        cursorColumn = 0
        ensureRow(cursorRow)
        trimToLimit()
    }

    private mutating func ensureRow(_ row: Int) {
        while row >= rows.count {
            rows.append([])
        }
    }

    private mutating func clampCursorColumn() {
        if let columnCount {
            cursorColumn = min(cursorColumn, columnCount - 1)
        }
    }

    private func firstParameter(_ parameters: String, defaultValue: Int) -> Int {
        numericParameters(parameters).first ?? defaultValue
    }

    private func numericParameters(_ parameters: String) -> [Int] {
        let trimmed = parameters.trimmingCharacters(in: CharacterSet(charactersIn: "?"))
        guard !trimmed.isEmpty else {
            return []
        }
        return trimmed
            .split(separator: ";", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? 1 : (Int($0) ?? 1) }
    }

    private mutating func trimToLimit() {
        while rows.count > maxLineCount {
            rows.removeFirst()
            cursorRow = max(0, cursorRow - 1)
        }
        if rows.isEmpty {
            rows = [[]]
            cursorRow = 0
            cursorColumn = 0
        }
    }

    private mutating func reflowRows(to columns: Int) {
        var reflowedRows: [[UnicodeScalar]] = []
        var reflowedCursorRow = 0
        var reflowedCursorColumn = 0

        for (rowIndex, row) in rows.enumerated() {
            let rowStart = reflowedRows.count
            let chunks = Self.chunks(for: row, columns: columns)
            reflowedRows.append(contentsOf: chunks)

            guard rowIndex == cursorRow else {
                continue
            }

            let clampedCursorColumn = min(max(0, cursorColumn), max(row.count, 0))
            let cursorChunkOffset = min(max(0, clampedCursorColumn / columns), max(0, chunks.count - 1))
            reflowedCursorRow = rowStart + cursorChunkOffset
            reflowedCursorColumn = min(clampedCursorColumn % columns, columns - 1)
        }

        rows = reflowedRows.isEmpty ? [[]] : reflowedRows
        cursorRow = min(reflowedCursorRow, max(0, rows.count - 1))
        cursorColumn = reflowedCursorColumn
        trimToLimit()
    }

    private static func chunks(for row: [UnicodeScalar], columns: Int) -> [[UnicodeScalar]] {
        guard !row.isEmpty else {
            return [[]]
        }

        var chunks: [[UnicodeScalar]] = []
        var startIndex = 0
        while startIndex < row.count {
            let endIndex = min(startIndex + columns, row.count)
            chunks.append(Array(row[startIndex..<endIndex]))
            startIndex = endIndex
        }
        return chunks
    }

    private static func renderRow(_ row: [UnicodeScalar]) -> String {
        var trimmed = row
        while trimmed.last == " " {
            trimmed.removeLast()
        }
        return String(String.UnicodeScalarView(trimmed))
    }
}

private enum ParserState: Sendable, Equatable {
    case normal
    case escape
    case csi(String)
    case osc
    case oscEscape
}

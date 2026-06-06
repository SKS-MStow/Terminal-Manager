import Foundation

public struct TerminalUTF8StreamDecoder: Sendable {
    private var pendingBytes: Data

    public init() {
        self.pendingBytes = Data()
    }

    public mutating func append(_ data: Data) -> String {
        guard !data.isEmpty else {
            return ""
        }

        pendingBytes.append(data)
        let emitCount = Self.completePrefixByteCount(in: pendingBytes)
        guard emitCount > 0 else {
            return ""
        }

        let prefix = pendingBytes.prefix(emitCount)
        pendingBytes.removeFirst(emitCount)
        return String(decoding: prefix, as: UTF8.self)
    }

    public mutating func finish() -> String {
        guard !pendingBytes.isEmpty else {
            return ""
        }

        let remaining = pendingBytes
        pendingBytes.removeAll(keepingCapacity: false)
        return String(decoding: remaining, as: UTF8.self)
    }

    private static func completePrefixByteCount(in data: Data) -> Int {
        let bytes = Array(data)
        var index = 0
        var completeIndex = 0

        while index < bytes.count {
            let byte = bytes[index]
            if byte < 0x80 {
                index += 1
                completeIndex = index
                continue
            }

            guard let width = utf8SequenceWidth(startingWith: byte) else {
                index += 1
                completeIndex = index
                continue
            }

            guard index + width <= bytes.count else {
                if hasInvalidAvailableContinuation(bytes: bytes, startIndex: index, width: width) {
                    index += 1
                    completeIndex = index
                    continue
                }

                break
            }

            if isValidUTF8Sequence(Array(bytes[index..<(index + width)])) {
                index += width
                completeIndex = index
            } else {
                index += 1
                completeIndex = index
            }
        }

        return completeIndex
    }

    private static func utf8SequenceWidth(startingWith byte: UInt8) -> Int? {
        switch byte {
        case 0xC2...0xDF:
            return 2
        case 0xE0...0xEF:
            return 3
        case 0xF0...0xF4:
            return 4
        default:
            return nil
        }
    }

    private static func isValidUTF8Sequence(_ bytes: [UInt8]) -> Bool {
        guard let first = bytes.first else {
            return false
        }

        switch bytes.count {
        case 2:
            return isContinuation(bytes[1])
        case 3:
            guard isContinuation(bytes[1]), isContinuation(bytes[2]) else {
                return false
            }
            if first == 0xE0 {
                return bytes[1] >= 0xA0
            }
            if first == 0xED {
                return bytes[1] <= 0x9F
            }
            return true
        case 4:
            guard isContinuation(bytes[1]), isContinuation(bytes[2]), isContinuation(bytes[3]) else {
                return false
            }
            if first == 0xF0 {
                return bytes[1] >= 0x90
            }
            if first == 0xF4 {
                return bytes[1] <= 0x8F
            }
            return true
        default:
            return false
        }
    }

    private static func isContinuation(_ byte: UInt8) -> Bool {
        (0x80...0xBF).contains(byte)
    }

    private static func hasInvalidAvailableContinuation(bytes: [UInt8], startIndex: Int, width: Int) -> Bool {
        let available = min(width, bytes.count - startIndex)
        guard available > 1 else {
            return false
        }

        for offset in 1..<available {
            guard isContinuation(bytes[startIndex + offset]) else {
                return true
            }
        }

        let first = bytes[startIndex]
        let second = bytes[startIndex + 1]
        if first == 0xE0, second < 0xA0 {
            return true
        }
        if first == 0xED, second > 0x9F {
            return true
        }
        if first == 0xF0, second < 0x90 {
            return true
        }
        if first == 0xF4, second > 0x8F {
            return true
        }

        return false
    }
}

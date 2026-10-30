import Foundation

/// Loose version comparison for the many formats apps use:
/// "2.0" == "2.0.0", "v1.4" == "1.4", "1.0b2" < "1.0", "2024.1 (241)" compares numerically.
public struct Version: Comparable, CustomStringConvertible {
    public let raw: String
    let tokens: [Token]

    enum Token: Equatable {
        case number(Int)
        case word(String)
    }

    public init(_ raw: String) {
        self.raw = raw
        var tokens: [Token] = []
        var current = ""
        var currentIsDigit = false
        func flush() {
            guard !current.isEmpty else { return }
            if currentIsDigit {
                // Clamp absurdly long digit runs (hashes, dates with time) instead of overflowing.
                tokens.append(.number(Int(current.prefix(18)) ?? 0))
            } else {
                tokens.append(.word(current.lowercased()))
            }
            current = ""
        }
        var body = raw.trimmingCharacters(in: .whitespaces)
        if body.first == "v" || body.first == "V", body.dropFirst().first?.isNumber == true {
            body.removeFirst()
        }
        for ch in body {
            if ch.isASCII && ch.isNumber {
                if !currentIsDigit { flush() }
                currentIsDigit = true
                current.append(ch)
            } else if ch.isASCII && ch.isLetter {
                if currentIsDigit { flush() }
                currentIsDigit = false
                current.append(ch)
            } else {
                flush()
            }
        }
        flush()
        self.tokens = tokens
    }

    public var description: String { raw }

    public var isEmpty: Bool { tokens.isEmpty }

    /// A missing component counts as 0, so 2.0.0 == 2.0 == 2.
    public static func == (lhs: Version, rhs: Version) -> Bool { !(lhs < rhs) && !(rhs < lhs) }

    public static func < (lhs: Version, rhs: Version) -> Bool {
        let count = max(lhs.tokens.count, rhs.tokens.count)
        for i in 0..<count {
            let a = i < lhs.tokens.count ? lhs.tokens[i] : nil
            let b = i < rhs.tokens.count ? rhs.tokens[i] : nil
            switch (a, b) {
            case let (.number(x)?, .number(y)?):
                if x != y { return x < y }
            case let (.word(x)?, .word(y)?):
                if x != y { return x < y }
            // A pre-release word ranks below a number or the end: 1.0b1 < 1.0 < 1.0.1.
            case (.word?, .number?), (.word?, nil):
                return true
            case (.number?, .word?), (nil, .word?):
                return false
            case let (nil, .number(y)?):
                if y != 0 { return 0 < y }
            case let (.number(x)?, nil):
                if x != 0 { return x < 0 }
            case (nil, nil):
                return false
            }
        }
        return false
    }
}

import Foundation

/// One displayed subtitle line: a settled (final) part followed by a pending part that the
/// speech service may still revise. The overlay shows the pending part dimmed.
public struct CaptionLine: Equatable, Sendable {
    public var settled: String
    public var pending: String

    public init(settled: String, pending: String = "") {
        self.settled = settled
        self.pending = pending
    }

    public var text: String { settled + pending }
}

public enum CaptionWrapper {
    /// Wraps `settled + pending` into lines of at most `width` characters (breaking at spaces,
    /// splitting only words longer than a line) and returns the last `maxLines` lines, so the
    /// newest words are always visible. Whitespace runs collapse to one space.
    public static func lastLines(settled: String, pending: String, width: Int, maxLines: Int) -> [CaptionLine] {
        guard width > 0, maxLines > 0 else { return [] }

        // Characters with a flag saying whether they are settled. Flags are monotonic:
        // every settled character comes before every pending one.
        var chars: [(Character, Bool)] = []
        var lastWasSpace = true
        for (part, isSettled) in [(settled, true), (pending, false)] {
            for ch in part {
                if ch.isWhitespace {
                    if !lastWasSpace { chars.append((" ", isSettled)) }
                    lastWasSpace = true
                } else {
                    chars.append((ch, isSettled))
                    lastWasSpace = false
                }
            }
        }
        while let last = chars.last, last.0 == " " { chars.removeLast() }
        guard !chars.isEmpty else { return [] }

        // Split into words (runs without spaces).
        var words: [[(Character, Bool)]] = []
        var current: [(Character, Bool)] = []
        for item in chars {
            if item.0 == " " {
                if !current.isEmpty { words.append(current); current = [] }
            } else {
                current.append(item)
            }
        }
        if !current.isEmpty { words.append(current) }

        // Greedy wrap. A space between two words is settled only if the next word starts settled.
        var lines: [[(Character, Bool)]] = []
        var line: [(Character, Bool)] = []
        func flush() {
            if !line.isEmpty { lines.append(line); line = [] }
        }
        for var word in words {
            while word.count > width {  // a word longer than a line is split
                flush()
                lines.append(Array(word.prefix(width)))
                word.removeFirst(width)
            }
            if word.isEmpty { continue }
            if line.isEmpty {
                line = word
            } else if line.count + 1 + word.count <= width {
                line.append((" ", word[0].1))
                line.append(contentsOf: word)
            } else {
                flush()
                line = word
            }
        }
        flush()

        return lines.suffix(maxLines).map { chars in
            var settledPart = ""
            var pendingPart = ""
            for (ch, isSettled) in chars {
                if isSettled { settledPart.append(ch) } else { pendingPart.append(ch) }
            }
            return CaptionLine(settled: settledPart, pending: pendingPart)
        }
    }
}

import Foundation

/// What the overlay should show right now.
public struct SubtitleFrame: Equatable, Sendable {
    public var english: [CaptionLine]
    public var hebrew: [CaptionLine]

    public init(english: [CaptionLine] = [], hebrew: [CaptionLine] = []) {
        self.english = english
        self.hebrew = hebrew
    }

    public static let empty = SubtitleFrame()
    public var isEmpty: Bool { english.isEmpty && hebrew.isEmpty }
}

/// Turns the stream of Soniox responses into rolling subtitle lines.
///
/// Final tokens are appended once and never change; non-final tokens are provisional and are
/// replaced by every response. Text disappears `fadeAfter` seconds after the last change, and
/// the next speech after such a pause starts on a clean screen.
public struct SubtitleAssembler: Sendable {
    public var englishWidth: Int
    public var englishLines: Int
    public var hebrewWidth: Int
    public var fadeAfter: TimeInterval
    public var targetLanguage: String

    private var englishSettled = ""
    private var englishPending = ""
    private var hebrewSettled = ""
    private var hebrewPending = ""
    public private(set) var lastChange: Date?

    /// Keep at most this many characters of settled text (only the tail is ever shown).
    private let bufferLimit = 600

    public init(englishWidth: Int = 42, englishLines: Int = 2, hebrewWidth: Int = 60,
                fadeAfter: TimeInterval = 4, targetLanguage: String = "en") {
        self.englishWidth = englishWidth
        self.englishLines = englishLines
        self.hebrewWidth = hebrewWidth
        self.fadeAfter = fadeAfter
        self.targetLanguage = targetLanguage
    }

    public mutating func apply(_ response: SonioxResponse, at now: Date) {
        var newEnglishPending = ""
        var newHebrewPending = ""
        var settledEnglish = ""
        var settledHebrew = ""

        for token in response.tokens {
            switch token.role(targetLanguage: targetLanguage) {
            case .marker:
                continue
            case .target:
                if token.isFinal { settledEnglish += token.text } else { newEnglishPending += token.text }
            case .source:
                if token.isFinal { settledHebrew += token.text } else { newHebrewPending += token.text }
            }
        }

        let hasNewText = !(settledEnglish + settledHebrew).allSatisfy(\.isWhitespace)
        let pendingChanged = newEnglishPending != englishPending || newHebrewPending != hebrewPending
        let pendingHasText = !(newEnglishPending + newHebrewPending).allSatisfy(\.isWhitespace)
        guard hasNewText || pendingChanged else { return }

        // After a pause long enough for the text to fade, start on a clean screen.
        if let lastChange, now.timeIntervalSince(lastChange) >= fadeAfter, hasNewText || pendingHasText {
            englishSettled = ""
            hebrewSettled = ""
        }

        englishSettled = Self.trimmed(englishSettled + settledEnglish, limit: bufferLimit)
        hebrewSettled = Self.trimmed(hebrewSettled + settledHebrew, limit: bufferLimit)
        englishPending = newEnglishPending
        hebrewPending = newHebrewPending

        if hasNewText || pendingHasText { lastChange = now }
    }

    public func frame(at now: Date) -> SubtitleFrame {
        guard let lastChange, now.timeIntervalSince(lastChange) < fadeAfter else { return .empty }
        return SubtitleFrame(
            english: CaptionWrapper.lastLines(settled: englishSettled, pending: englishPending,
                                              width: englishWidth, maxLines: englishLines),
            hebrew: CaptionWrapper.lastLines(settled: hebrewSettled, pending: hebrewPending,
                                             width: hebrewWidth, maxLines: 1)
        )
    }

    public mutating func reset() {
        englishSettled = ""
        englishPending = ""
        hebrewSettled = ""
        hebrewPending = ""
        lastChange = nil
    }

    /// Keeps the tail of `text`, cut at a space so no word is chopped.
    static func trimmed(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let tail = text.suffix(limit)
        if let space = tail.firstIndex(where: \.isWhitespace) {
            return String(tail[space...])
        }
        return String(tail)
    }
}

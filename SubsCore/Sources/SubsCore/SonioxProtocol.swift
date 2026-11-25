import Foundation

/// Constants and message shapes for Soniox's real-time WebSocket API
/// (https://docs.soniox.com/api-reference/stt/websocket-api).
public enum Soniox {
    public static let websocketURL = URL(string: "wss://stt-rt.soniox.com/transcribe-websocket")!
    /// Cheap authenticated GET used to check a key (200 = valid, 401 = invalid).
    public static let modelsURL = URL(string: "https://api.soniox.com/v1/models")!
    public static let consoleURL = URL(string: "https://console.soniox.com")!
    public static let model = "stt-rt-v6"
    /// Audio we send: 16 kHz mono signed 16-bit little-endian PCM.
    public static let sampleRate = 16_000
    /// A stream may last at most 300 minutes; start a fresh one well before that.
    public static let maxStreamSeconds: TimeInterval = 280 * 60
    /// The server ends a stream after 20 s without any message; keepalive well inside that.
    public static let keepaliveInterval: TimeInterval = 8

    /// Text frame asking the server to finalize everything heard so far.
    public static let finalizeMessage = #"{"type":"finalize"}"#
    /// Text frame that keeps an idle stream open (no audio is billed).
    public static let keepaliveMessage = #"{"type":"keepalive"}"#
    /// An empty text frame ends the audio; the server then sends `finished`.
    public static let endOfAudioMessage = ""
}

/// The first message on the socket. The API key is NOT part of it: it goes in the
/// `Authorization: Bearer` header of the WebSocket upgrade request.
public struct StartRequest: Encodable, Equatable, Sendable {
    public struct Translation: Encodable, Equatable, Sendable {
        public var type: String
        public var targetLanguage: String
    }

    public var model: String
    public var audioFormat: String
    public var sampleRate: Int
    public var numChannels: Int
    public var languageHints: [String]
    public var enableEndpointDetection: Bool
    public var translation: Translation

    public static func hebrewToEnglish(model: String = Soniox.model) -> StartRequest {
        StartRequest(
            model: model,
            audioFormat: "pcm_s16le",
            sampleRate: Soniox.sampleRate,
            numChannels: 1,
            languageHints: ["he"],
            enableEndpointDetection: true,
            translation: Translation(type: "one_way", targetLanguage: "en")
        )
    }

    public func jsonString() throws -> String {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}

public struct SonioxToken: Decodable, Equatable, Sendable {
    public var text: String
    public var isFinal: Bool
    /// "none", "original" (spoken text that will be translated) or "translation".
    public var translationStatus: String?
    /// Language of `text`.
    public var language: String?
    public var startMs: Double?
    public var endMs: Double?

    public init(text: String, isFinal: Bool, translationStatus: String? = nil,
                language: String? = nil, startMs: Double? = nil, endMs: Double? = nil) {
        self.text = text
        self.isFinal = isFinal
        self.translationStatus = translationStatus
        self.language = language
        self.startMs = startMs
        self.endMs = endMs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        isFinal = try c.decodeIfPresent(Bool.self, forKey: .isFinal) ?? false
        translationStatus = try c.decodeIfPresent(String.self, forKey: .translationStatus)
        language = try c.decodeIfPresent(String.self, forKey: .language)
        startMs = try c.decodeIfPresent(Double.self, forKey: .startMs)
        endMs = try c.decodeIfPresent(Double.self, forKey: .endMs)
    }

    enum CodingKeys: String, CodingKey {
        case text, isFinal, translationStatus, language, startMs, endMs
    }

    public enum Role: Equatable, Sendable {
        /// Text for the subtitle line (a translation, or speech already in the target language).
        case target
        /// The spoken (Hebrew) text.
        case source
        /// Control markers such as `<end>` (endpoint) and `<fin>` (finalized); never shown.
        case marker
    }

    public func role(targetLanguage: String = "en") -> Role {
        if text.hasPrefix("<"), text.hasSuffix(">"), !text.contains(" ") { return .marker }
        switch translationStatus {
        case "translation": return .target
        case "original": return .source
        default: return language == targetLanguage ? .target : .source
        }
    }
}

public struct SonioxResponse: Decodable, Equatable, Sendable {
    public var tokens: [SonioxToken]
    public var finished: Bool
    public var errorCode: Int?
    public var errorType: String?
    public var errorMessage: String?

    public init(tokens: [SonioxToken] = [], finished: Bool = false, errorCode: Int? = nil,
                errorType: String? = nil, errorMessage: String? = nil) {
        self.tokens = tokens
        self.finished = finished
        self.errorCode = errorCode
        self.errorType = errorType
        self.errorMessage = errorMessage
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tokens = try c.decodeIfPresent([SonioxToken].self, forKey: .tokens) ?? []
        finished = try c.decodeIfPresent(Bool.self, forKey: .finished) ?? false
        errorCode = try c.decodeIfPresent(Int.self, forKey: .errorCode)
        errorType = try c.decodeIfPresent(String.self, forKey: .errorType)
        errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
    }

    enum CodingKeys: String, CodingKey {
        case tokens, finished, errorCode, errorType, errorMessage
    }

    public var isError: Bool { errorCode != nil || errorType != nil }

    public static func decode(_ text: String) throws -> SonioxResponse {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(SonioxResponse.self, from: Data(text.utf8))
    }
}

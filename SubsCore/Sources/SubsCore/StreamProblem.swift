import Foundation

/// Why subtitles stopped or paused, with the one plain sentence the overlay/menu shows.
public enum StreamProblem: Equatable, Sendable {
    case missingKey
    case badKey
    case noCredit
    case needsPermission
    case offline
    /// Temporary trouble (server busy, connection dropped, stream time limit): retried quietly.
    case temporary
    /// The service rejected our request format: the app needs an update.
    case needsUpdate

    /// Maps a Soniox error response (https://docs.soniox.com/api-reference/errors).
    public static func from(errorCode: Int?, errorType: String?) -> StreamProblem {
        switch errorType {
        case "unauthenticated", "permission_denied", "temp_api_key_session_expired":
            return .badKey
        case "invalid_request", "model_not_available":
            return .needsUpdate
        case let type? where type.contains("balance") || type.contains("budget") || type.contains("usage_limit"):
            return .noCredit
        default:
            break
        }
        switch errorCode {
        case 401, 403: return .badKey
        case 402: return .noCredit
        case 400: return .needsUpdate
        default: return .temporary
        }
    }

    /// Maps the HTTP status of the key check (GET /v1/models).
    public static func fromKeyCheck(status: Int) -> StreamProblem? {
        switch status {
        case 200..<300: return nil
        case 401, 403: return .badKey
        case 402: return .noCredit
        default: return .temporary
        }
    }

    /// Worth reconnecting automatically?
    public var isRetryable: Bool {
        switch self {
        case .offline, .temporary: return true
        default: return false
        }
    }

    public var message: String {
        switch self {
        case .missingKey:
            return "Add your Soniox key: click the LiveSubs icon in the menu bar, then Setup."
        case .badKey:
            return "Your Soniox key isn't working. Click the LiveSubs icon in the menu bar, then Setup, to enter it again."
        case .noCredit:
            return "Your Soniox balance or monthly limit has run out. Check console.soniox.com, then turn subtitles on again."
        case .needsPermission:
            return "LiveSubs can't hear your Mac's sound. Click the LiveSubs icon in the menu bar, then Setup."
        case .offline:
            return "No internet connection. Subtitles will come back when you're online."
        case .temporary:
            return "Reconnecting…"
        case .needsUpdate:
            return "The speech service changed. LiveSubs needs an update."
        }
    }
}

/// Delays between reconnect attempts: quick at first, then backing off.
public struct ReconnectPolicy: Sendable {
    public let delays: [TimeInterval]
    public private(set) var attempt = 0

    public init(delays: [TimeInterval] = [0.5, 1, 2, 4, 8, 15]) {
        self.delays = delays
    }

    public mutating func nextDelay() -> TimeInterval {
        defer { attempt += 1 }
        return delays[min(attempt, delays.count - 1)]
    }

    public mutating func reset() { attempt = 0 }
}

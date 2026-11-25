import Foundation
import SubsCore

enum SessionEvent: Sendable {
    case response(SonioxResponse)
    /// The stream ended: nil = finished normally, otherwise why.
    case ended(StreamProblem?)
}

/// One Soniox real-time stream: Hebrew audio in, Hebrew text + English translation out.
actor SonioxSession {
    nonisolated let events: AsyncStream<SessionEvent>
    private let continuation: AsyncStream<SessionEvent>.Continuation
    private let key: String
    private let urlSession = URLSession(configuration: .ephemeral)
    private var task: URLSessionWebSocketTask?
    private var lastSent = Date()
    private var ended = false
    private var receiveTask: Task<Void, Never>?
    private var keepaliveTask: Task<Void, Never>?

    init(key: String) {
        self.key = key
        var cont: AsyncStream<SessionEvent>.Continuation?
        events = AsyncStream { cont = $0 }
        continuation = cont!
    }

    /// Connects and sends the start request. Returns false if that failed (an `.ended` event
    /// with the reason has then been sent).
    func start() async -> Bool {
        var request = URLRequest(url: Soniox.websocketURL)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let task = urlSession.webSocketTask(with: request)
        task.maximumMessageSize = 4 * 1024 * 1024
        self.task = task
        task.resume()
        do {
            try await task.send(.string(try StartRequest.hebrewToEnglish().jsonString()))
            lastSent = Date()
        } catch {
            finish(problem(for: error))
            return false
        }
        receiveTask = Task { await self.receiveLoop() }
        keepaliveTask = Task { await self.keepaliveLoop() }
        return true
    }

    func send(_ item: Outgoing) async {
        guard let task, !ended else { return }
        do {
            switch item {
            case .audio(let data): try await task.send(.data(data))
            case .finalize: try await task.send(.string(Soniox.finalizeMessage))
            }
            lastSent = Date()
        } catch {
            finish(problem(for: error))
        }
    }

    /// Ends the stream on purpose (subtitles turned off, or replaced by a fresh stream).
    func close() async {
        guard !ended, let task else { return }
        try? await task.send(.string(Soniox.endOfAudioMessage))
        ended = true
        cleanUp()
        continuation.finish()
    }

    private func receiveLoop() async {
        while !ended, let task {
            do {
                let message = try await task.receive()
                let text: String
                switch message {
                case .string(let s): text = s
                case .data(let d): text = String(decoding: d, as: UTF8.self)
                @unknown default: continue
                }
                guard let response = try? SonioxResponse.decode(text) else { continue }
                if response.isError {
                    NSLog("LiveSubs: Soniox error \(response.errorCode ?? 0) \(response.errorType ?? "")")
                    finish(StreamProblem.from(errorCode: response.errorCode, errorType: response.errorType))
                    return
                }
                continuation.yield(.response(response))
                if response.finished {
                    finish(nil)
                    return
                }
            } catch {
                finish(problem(for: error))
                return
            }
        }
    }

    /// Soniox closes a stream after 20 s without messages; silence isn't sent, so keep it alive.
    private func keepaliveLoop() async {
        while !ended {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if Task.isCancelled || ended { return }
            if Date().timeIntervalSince(lastSent) >= Soniox.keepaliveInterval, let task {
                try? await task.send(.string(Soniox.keepaliveMessage))
                lastSent = Date()
            }
        }
    }

    private func finish(_ problem: StreamProblem?) {
        guard !ended else { return }
        ended = true
        continuation.yield(.ended(problem))
        continuation.finish()
        cleanUp()
    }

    private func cleanUp() {
        keepaliveTask?.cancel()
        receiveTask?.cancel()
        task?.cancel(with: .normalClosure, reason: nil)
        urlSession.finishTasksAndInvalidate()
    }

    private func problem(for error: Error) -> StreamProblem {
        if let http = task?.response as? HTTPURLResponse, [401, 402, 403].contains(http.statusCode) {
            return StreamProblem.fromKeyCheck(status: http.statusCode) ?? .temporary
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff, .cannotFindHost,
                 .dnsLookupFailed:
                return .offline
            default:
                break
            }
        }
        return .temporary
    }
}

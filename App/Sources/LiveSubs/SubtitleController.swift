import AppKit
import Foundation
import SubsCore

/// Glues capture → silence gate → Soniox → subtitle lines, and owns On/Off.
@MainActor
final class SubtitleController: ObservableObject {
    @Published private(set) var isOn = false
    @Published private(set) var frame: SubtitleFrame = .empty
    /// Why subtitles are paused or off (nil when all is well).
    @Published private(set) var problem: StreamProblem?

    var onNeedsSetup: (() -> Void)?

    private let settings: Settings
    private var assembler = SubtitleAssembler()
    private var capture: SystemAudioCapture?
    private var session: SonioxSession?
    private var sessionStarted: Date?
    private var reconnect = ReconnectPolicy()
    private var reconnectTask: Task<Void, Never>?
    private var eventsTask: Task<Void, Never>?
    private var pumpTask: Task<Void, Never>?
    private var tick: Timer?
    private var problemSince: Date?
    private let router = AudioRouter()

    init(settings: Settings) {
        self.settings = settings
    }

    /// The message to show over the video, if any (temporary hiccups stay quiet).
    var notice: String? {
        guard let problem, problem != .temporary else { return nil }
        return problem.message
    }

    var statusLine: String {
        if let problem { return problem == .temporary ? "Reconnecting…" : problem.message }
        return isOn ? "Subtitles are on" : "Subtitles are off"
    }

    func toggle() { isOn ? turnOff() : turnOn() }

    func turnOn() {
        guard !isOn else { return }
        guard let key = KeyStore.load() else {
            show(.missingKey)
            onNeedsSetup?()
            return
        }
        guard ScreenPermission.isGranted else {
            show(.needsPermission)
            onNeedsSetup?()
            return
        }
        isOn = true
        show(nil)
        assembler.reset()
        reconnect.reset()
        startTick()
        startPump()
        Task {
            await startCapture()
            if isOn { await connect(key: key) }
        }
    }

    func turnOff() {
        stop(showing: nil)
    }

    /// Characters per line, from the panel width and font size (set by the overlay).
    func setLineWidths(english: Int, hebrew: Int) {
        assembler.englishWidth = max(16, english)
        assembler.hebrewWidth = max(16, hebrew)
        frame = assembler.frame(at: Date())
    }

    // MARK: - Internals

    private func stop(showing problem: StreamProblem?) {
        isOn = false
        show(problem)
        reconnectTask?.cancel()
        eventsTask?.cancel()
        pumpTask?.cancel()
        router.setSink(nil)
        let oldSession = session
        let oldCapture = capture
        session = nil
        capture = nil
        Task {
            await oldCapture?.stop()
            await oldSession?.close()
        }
        assembler.reset()
        frame = .empty
    }

    private func show(_ problem: StreamProblem?) {
        self.problem = problem
        problemSince = problem == nil ? nil : Date()
        if problem != nil { startTick() }
    }

    private func startCapture() async {
        let router = self.router
        let capture = SystemAudioCapture(
            onSamples: { samples in router.handle(samples) },
            onStop: { [weak self] error in
                let reason = error.localizedDescription
                Task { @MainActor in self?.captureStopped(reason) }
            })
        do {
            try await capture.start()
            guard isOn else {
                await capture.stop()
                return
            }
            self.capture = capture
        } catch {
            NSLog("LiveSubs: capture failed: \(error.localizedDescription)")
            stop(showing: ScreenPermission.isGranted ? .temporary : .needsPermission)
        }
    }

    private func captureStopped(_ reason: String) {
        guard isOn else { return }
        NSLog("LiveSubs: capture stopped: \(reason)")
        capture = nil
        if !ScreenPermission.isGranted {
            stop(showing: .needsPermission)
            return
        }
        // Display change, sleep/wake…: start capturing again shortly.
        Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if isOn, capture == nil { await startCapture() }
        }
    }

    /// Sends gated audio to whichever session is current, strictly in order.
    private func startPump() {
        pumpTask?.cancel()
        var cont: AsyncStream<Outgoing>.Continuation?
        let stream = AsyncStream<Outgoing>(bufferingPolicy: .bufferingNewest(100)) { cont = $0 }
        router.setSink(cont)
        pumpTask = Task { [weak self] in
            for await item in stream {
                guard let session = self?.session else { continue }
                await session.send(item)
            }
        }
    }

    private func connect(key: String) async {
        let newSession = SonioxSession(key: key)
        router.reset()
        let connected = await newSession.start()
        guard isOn else {
            await newSession.close()
            return
        }
        let previous = session
        session = newSession
        sessionStarted = Date()
        eventsTask?.cancel()
        eventsTask = Task { [weak self] in
            for await event in newSession.events {
                self?.handle(event, from: newSession)
            }
        }
        if connected {
            if problem?.isRetryable == true { show(nil) }
        }
        if let previous { await previous.close() }
    }

    private func handle(_ event: SessionEvent, from source: SonioxSession) {
        guard source === session else { return }
        switch event {
        case .response(let response):
            reconnect.reset()
            if problem?.isRetryable == true { show(nil) }
            assembler.apply(response, at: Date())
            frame = assembler.frame(at: Date())
        case .ended(let problem):
            session = nil
            guard isOn else { return }
            if let problem, !problem.isRetryable {
                stop(showing: problem)
                return
            }
            if let problem { show(problem) }
            scheduleReconnect()
        }
    }

    private func scheduleReconnect() {
        reconnectTask?.cancel()
        let delay = reconnect.nextDelay()
        reconnectTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, isOn, session == nil, let key = KeyStore.load() else { return }
            await connect(key: key)
        }
    }

    private func startTick() {
        guard tick == nil else { return }
        tick = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.onTick() }
        }
    }

    private func onTick() {
        let now = Date()
        let newFrame = assembler.frame(at: now)
        if newFrame != frame { frame = newFrame }

        // Messages over the video disappear after a while (except "offline", while it lasts).
        if let problem, problem != .offline, let since = problemSince, now.timeIntervalSince(since) > 12 {
            if !isOn || problem == .temporary { show(nil) }
        }

        // Start a fresh stream before Soniox's 300-minute limit.
        if isOn, let started = sessionStarted, session != nil,
           now.timeIntervalSince(started) > Soniox.maxStreamSeconds, let key = KeyStore.load() {
            sessionStarted = now
            Task { await connect(key: key) }
        }

        if !isOn, problem == nil, frame.isEmpty {
            tick?.invalidate()
            tick = nil
        }
    }
}

/// Runs on the capture queue: silence gate + chunking, then hands items to the pump.
final class AudioRouter: @unchecked Sendable {
    private let lock = NSLock()
    private var pipeline = AudioPipeline()
    private var sink: AsyncStream<Outgoing>.Continuation?

    func handle(_ samples: [Int16]) {
        lock.lock()
        defer { lock.unlock() }
        guard let sink else { return }
        for item in pipeline.append(samples, at: Date()) {
            sink.yield(item)
        }
    }

    func setSink(_ newSink: AsyncStream<Outgoing>.Continuation?) {
        lock.lock()
        defer { lock.unlock() }
        sink?.finish()
        sink = newSink
        pipeline.reset()
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        pipeline.reset()
    }
}

import AppKit
import Combine
import SubsCore
import SwiftUI

@MainActor
final class OverlayState: ObservableObject {
    @Published var isMoving = false
}

/// A transparent, click-through panel that floats above everything, including full-screen
/// video in other apps, and shows the subtitles near the bottom of the screen.
@MainActor
final class OverlayPanel: NSPanel {
    let state = OverlayState()
    private let settings: Settings
    private let controller: SubtitleController
    private var cancellables = Set<AnyCancellable>()
    private var dragStart: (mouse: NSPoint, origin: NSPoint)?

    init(controller: SubtitleController, settings: Settings) {
        self.settings = settings
        self.controller = controller
        super.init(contentRect: NSRect(x: 0, y: 0, width: 900, height: 200),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = true

        contentView = NSHostingView(rootView: OverlayView(
            controller: controller, settings: settings, state: state,
            onDrag: { [weak self] ended in self?.drag(ended: ended) },
            onDone: { [weak self] in self?.finishMoving() }))

        layout(keepOrigin: settings.overlayOrigin)
        orderFrontRegardless()

        settings.$fontSize.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.layout(keepOrigin: self?.frame.origin) }
        }.store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.layout(keepOrigin: self?.frame.origin) }
            .store(in: &cancellables)
    }

    override var canBecomeKey: Bool { state.isMoving }

    func startMoving() {
        state.isMoving = true
        ignoresMouseEvents = false
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
    }

    func finishMoving() {
        state.isMoving = false
        ignoresMouseEvents = true
        settings.overlayOrigin = frame.origin
        orderFrontRegardless()
    }

    func resetPosition() {
        settings.overlayOrigin = nil
        layout(keepOrigin: nil)
    }

    override func cancelOperation(_ sender: Any?) {  // Esc while moving
        if state.isMoving { finishMoving() }
    }

    /// Size from the font; bottom-center by default, otherwise the saved spot kept on screen.
    private func layout(keepOrigin origin: NSPoint?) {
        guard let screen = screenFor(origin) else { return }
        let visible = screen.visibleFrame
        let width = min(1100, visible.width * 0.8)
        let size = settings.fontSize
        let height = (size * 1.3 * 2) + (size * 0.62 * 1.4) + 60
        var newOrigin = origin ?? NSPoint(x: visible.midX - width / 2, y: visible.minY + 40)
        newOrigin.x = min(max(newOrigin.x, visible.minX), visible.maxX - width)
        newOrigin.y = min(max(newOrigin.y, visible.minY), visible.maxY - height)
        setFrame(NSRect(origin: newOrigin, size: NSSize(width: width, height: height)), display: true)

        // Rough characters per line for the wrapper; SwiftUI shrinks anything that still overflows.
        let usable = width - 2 * 22
        controller.setLineWidths(english: Int(usable / (size * 0.52)),
                                 hebrew: Int(usable / (size * 0.62 * 0.5)))
    }

    private func screenFor(_ origin: NSPoint?) -> NSScreen? {
        if let origin, let s = NSScreen.screens.first(where: { $0.frame.contains(origin) }) { return s }
        return NSScreen.main ?? NSScreen.screens.first
    }

    private func drag(ended: Bool) {
        let mouse = NSEvent.mouseLocation
        if dragStart == nil { dragStart = (mouse, frame.origin) }
        guard let start = dragStart else { return }
        setFrameOrigin(NSPoint(x: start.origin.x + mouse.x - start.mouse.x,
                               y: start.origin.y + mouse.y - start.mouse.y))
        if ended { dragStart = nil }
    }
}

struct OverlayView: View {
    @ObservedObject var controller: SubtitleController
    @ObservedObject var settings: Settings
    @ObservedObject var state: OverlayState
    let onDrag: (_ ended: Bool) -> Void
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.25), value: controller.frame.isEmpty)
        .animation(.easeOut(duration: 0.25), value: controller.notice)
    }

    @ViewBuilder private var content: some View {
        if state.isMoving {
            box {
                Text("Drag to move the subtitles")
                    .font(.system(size: settings.fontSize, weight: .semibold))
                    .foregroundColor(.white)
                Button("Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
                    .padding(.top, 6)
            }
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in onDrag(false) }
                .onEnded { _ in onDrag(true) })
        } else if let notice = controller.notice {
            box {
                Text(notice)
                    .font(.system(size: max(18, settings.fontSize * 0.6), weight: .medium))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
            }
            .transition(.opacity)
        } else if !controller.frame.isEmpty {
            box {
                if settings.showHebrew {
                    ForEach(Array(controller.frame.hebrew.enumerated()), id: \.offset) { _, line in
                        lineText(line, size: settings.fontSize * 0.62, color: Color(white: 0.85))
                            .environment(\.layoutDirection, .rightToLeft)
                    }
                }
                ForEach(Array(controller.frame.english.enumerated()), id: \.offset) { _, line in
                    lineText(line, size: settings.fontSize, color: .white)
                }
            }
            .transition(.opacity)
        }
    }

    private func lineText(_ line: CaptionLine, size: Double, color: Color) -> some View {
        (Text(line.settled).foregroundColor(color) + Text(line.pending).foregroundColor(color.opacity(0.6)))
            .font(.system(size: size, weight: .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .shadow(color: .black.opacity(0.6), radius: 1, x: 0, y: 1)
    }

    private func box<Content: View>(@ViewBuilder _ inner: () -> Content) -> some View {
        VStack(spacing: 4, content: inner)
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.72)))
            .padding(.bottom, 8)
    }
}

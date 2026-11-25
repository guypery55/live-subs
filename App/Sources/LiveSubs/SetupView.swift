import AppKit
import SubsCore
import SwiftUI

@MainActor
final class SetupModel: ObservableObject {
    enum KeyState: Equatable {
        case none, saved, checking, works, failed(String)
    }

    @Published var keyText = ""
    @Published var keyState: KeyState
    @Published var permissionGranted = ScreenPermission.isGranted
    @Published var askedForPermission = false
    private var poll: Timer?

    init() {
        keyState = KeyStore.load() == nil ? .none : .saved
        // Notice the permission being granted in System Settings while this window is open.
        poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let granted = ScreenPermission.isGranted
                if granted != self.permissionGranted { self.permissionGranted = granted }
            }
        }
    }

    var keyReady: Bool { keyState == .saved || keyState == .works }
    var allDone: Bool { keyReady && permissionGranted }

    func stop() {
        poll?.invalidate()
        poll = nil
    }

    func saveKey() {
        let key = keyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        keyState = .checking
        Task {
            if let problem = await KeyCheck.check(key) {
                switch problem {
                case .badKey: keyState = .failed("That key didn't work. Copy it again from console.soniox.com.")
                case .offline: keyState = .failed("No internet connection. Connect and try again.")
                case .noCredit: keyState = .failed("The key works, but the Soniox account has no balance yet.")
                default: keyState = .failed("Soniox didn't answer. Try again in a minute.")
                }
                return
            }
            do {
                try KeyStore.save(key)
                keyText = ""
                keyState = .works
            } catch {
                keyState = .failed("Couldn't save the key: \(error.localizedDescription)")
            }
        }
    }

    func requestPermission() {
        askedForPermission = true
        ScreenPermission.request()
        ScreenPermission.openSettings()
    }
}

/// First-run window: paste the Soniox key, allow sound capture, done. Reachable later from
/// the menu (Setup…) to change the key.
struct SetupView: View {
    @ObservedObject var model: SetupModel
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Set up LiveSubs")
                .font(.title2.weight(.bold))
            Text("LiveSubs shows English subtitles for Hebrew speech playing on this Mac.")
                .foregroundColor(.secondary)

            if !AppLocation.isInApplications {
                Label("Move LiveSubs into your Applications folder first, then open it from there.",
                      systemImage: "exclamationmark.triangle")
                    .foregroundColor(.orange)
            }

            step(1, "Your Soniox key", done: model.keyReady) {
                Text("Soniox turns the Hebrew speech into English. Paste the API key from your Soniox account.")
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    SecureField(model.keyReady ? "Key saved. Paste a new one to replace it" : "Paste your key here",
                                text: $model.keyText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { model.saveKey() }
                    Button("Save") { model.saveKey() }
                        .disabled(model.keyText.trimmingCharacters(in: .whitespaces).isEmpty
                                  || model.keyState == .checking)
                }
                keyStatus
                Link("Open console.soniox.com", destination: Soniox.consoleURL)
                    .font(.callout)
            }

            step(2, "Let LiveSubs hear your Mac's sound", done: model.permissionGranted) {
                if model.permissionGranted {
                    Text("Allowed.").foregroundColor(.secondary)
                } else {
                    Text("In System Settings, turn on LiveSubs under “Screen & System Audio Recording” (or “Screen Recording”). If macOS asks to quit and reopen LiveSubs, click Quit & Reopen.")
                        .fixedSize(horizontal: false, vertical: true)
                    Button(model.askedForPermission ? "Open System Settings Again" : "Allow…") {
                        model.requestPermission()
                    }
                }
            }

            Divider()

            HStack(alignment: .center) {
                if model.allDone {
                    Text("All set. To turn subtitles on, click the LiveSubs icon in the menu bar or press ⌥⌘S.")
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Finish both steps to use LiveSubs.").foregroundColor(.secondary)
                }
                Spacer()
                Button("Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.allDone)
            }
        }
        .padding(26)
        .frame(width: 520)
    }

    @ViewBuilder private var keyStatus: some View {
        switch model.keyState {
        case .none: EmptyView()
        case .saved: Label("Key saved.", systemImage: "checkmark.circle.fill").foregroundColor(.green)
        case .checking: HStack { ProgressView().controlSize(.small); Text("Checking…") }
        case .works: Label("Key works and is saved.", systemImage: "checkmark.circle.fill").foregroundColor(.green)
        case .failed(let message): Label(message, systemImage: "xmark.circle.fill").foregroundColor(.red)
        }
    }

    private func step<Content: View>(_ number: Int, _ title: String, done: Bool,
                                     @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle().fill(done ? Color.green : Color.accentColor).frame(width: 28, height: 28)
                if done {
                    Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundColor(.white)
                } else {
                    Text("\(number)").font(.system(size: 14, weight: .bold)).foregroundColor(.white)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                content()
            }
        }
    }
}

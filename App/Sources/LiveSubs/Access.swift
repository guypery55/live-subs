import AppKit
import CoreGraphics
import Foundation
import ServiceManagement
import SubsCore

/// The friend's own Soniox API key, kept in a private file in Application Support
/// (readable only by their user account). A file rather than the Keychain so that app
/// updates never trigger Keychain password prompts.
enum KeyStore {
    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("LiveSubs", isDirectory: true).appendingPathComponent("soniox-key")
    }

    static func load() -> String? {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return nil }
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }

    static func save(_ key: String) throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try Data(key.utf8).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

enum KeyCheck {
    /// nil when the key works.
    static func check(_ key: String) async -> StreamProblem? {
        var request = URLRequest(url: Soniox.modelsURL, timeoutInterval: 15)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return StreamProblem.fromKeyCheck(status: (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch {
            return .offline
        }
    }
}

/// "Screen & System Audio Recording" permission, which ScreenCaptureKit needs to hear the Mac.
enum ScreenPermission {
    static var isGranted: Bool { CGPreflightScreenCaptureAccess() }

    /// Shows the system prompt the first time and adds LiveSubs to the list in System Settings.
    static func request() { _ = CGRequestScreenCaptureAccess() }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("LiveSubs: login item change failed: \(error.localizedDescription)")
        }
    }
}

enum AppLocation {
    /// Login items and permissions are most reliable from /Applications.
    static var isInApplications: Bool {
        let path = Bundle.main.bundlePath
        return path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/")
    }
}

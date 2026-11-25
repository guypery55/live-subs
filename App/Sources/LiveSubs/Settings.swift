import AppKit
import Foundation

/// User preferences (UserDefaults). Sensible defaults: large text, English only, bottom-center.
@MainActor
final class Settings: ObservableObject {
    private let defaults = UserDefaults.standard

    static let fontSizes: ClosedRange<Double> = 20...60
    static let fontStep: Double = 4

    @Published var showHebrew: Bool {
        didSet { defaults.set(showHebrew, forKey: "showHebrew") }
    }

    @Published var fontSize: Double {
        didSet { defaults.set(fontSize, forKey: "fontSize") }
    }

    var setupDone: Bool {
        get { defaults.bool(forKey: "setupDone") }
        set { defaults.set(newValue, forKey: "setupDone") }
    }

    /// Bottom-left corner of the subtitle panel, in screen coordinates; nil = default place.
    var overlayOrigin: NSPoint? {
        get {
            guard defaults.object(forKey: "overlayX") != nil else { return nil }
            return NSPoint(x: defaults.double(forKey: "overlayX"), y: defaults.double(forKey: "overlayY"))
        }
        set {
            if let p = newValue {
                defaults.set(p.x, forKey: "overlayX")
                defaults.set(p.y, forKey: "overlayY")
            } else {
                defaults.removeObject(forKey: "overlayX")
                defaults.removeObject(forKey: "overlayY")
            }
        }
    }

    init() {
        showHebrew = defaults.object(forKey: "showHebrew") as? Bool ?? false
        let size = defaults.object(forKey: "fontSize") as? Double ?? 34
        fontSize = min(Self.fontSizes.upperBound, max(Self.fontSizes.lowerBound, size))
    }

    func biggerText() { fontSize = min(Self.fontSizes.upperBound, fontSize + Self.fontStep) }
    func smallerText() { fontSize = max(Self.fontSizes.lowerBound, fontSize - Self.fontStep) }
}

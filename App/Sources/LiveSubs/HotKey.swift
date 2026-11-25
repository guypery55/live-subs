import Carbon.HIToolbox

/// A system-wide keyboard shortcut (⌥⌘S by default) that works whatever app is in front.
@MainActor
final class HotKey {
    private static var action: (() -> Void)?
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    init(keyCode: Int = kVK_ANSI_S, modifiers: Int = optionKey | cmdKey, action: @escaping () -> Void) {
        HotKey.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            // Carbon delivers hot-key events on the main thread.
            MainActor.assumeIsolated { HotKey.action?() }
            return noErr
        }, 1, &spec, nil, &handlerRef)
        let id = EventHotKeyID(signature: OSType(0x4C53_5542), id: 1)  // 'LSUB'
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }
}

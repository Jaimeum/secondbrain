import Carbon.HIToolbox
import Foundation

/// A global shortcut (⌥⌘R, the capture one) via Carbon's RegisterEventHotKey, which needs no Accessibility permission.
/// `isRegistered` is false when another app already registered the same combination.
@MainActor
final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void
    private(set) var isRegistered = false

    nonisolated(unsafe) private static var registry: [UInt32: GlobalHotKey] = [:]
    nonisolated(unsafe) private static var nextId: UInt32 = 1

    init(keyCode: Int = kVK_ANSI_R, modifiers: Int = optionKey | cmdKey, action: @escaping () -> Void) {
        self.action = action
        let id = Self.nextId
        Self.nextId += 1

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hkId = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hkId)
            let key = hkId.id
            DispatchQueue.main.async {
                MainActor.assumeIsolated { GlobalHotKey.registry[key]?.action() }
            }
            return noErr
        }, 1, &spec, nil, &handlerRef)

        let hotKeyId = EventHotKeyID(signature: OSType(0x5342_524E), id: id) // "SBRN"
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyId, GetApplicationEventTarget(), 0, &hotKeyRef)
        isRegistered = status == noErr && hotKeyRef != nil
        Self.registry[id] = self
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        hotKeyRef = nil
        handlerRef = nil
        Self.registry = Self.registry.filter { $0.value !== self }
    }
}

/// Shortcuts macOS itself owns (Ajustes del Sistema › Teclado › Atajos: input sources, Spotlight, Mission Control…).
/// A global shortcut registered on one of them never fires while it is enabled there.
enum SystemHotKeys {
    /// Whether `keyCode` + Carbon `modifiers` is an enabled system shortcut.
    static func isTaken(keyCode: Int, modifiers: Int) -> Bool {
        var unmanaged: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&unmanaged) == noErr, let array = unmanaged?.takeRetainedValue() as? [[String: Any]] else {
            return false
        }
        let relevant = cmdKey | shiftKey | optionKey | controlKey
        return array.contains { entry in
            guard (entry[kHISymbolicHotKeyEnabled as String] as? Bool) ?? false,
                  let code = (entry[kHISymbolicHotKeyCode as String] as? NSNumber)?.intValue,
                  let mods = (entry[kHISymbolicHotKeyModifiers as String] as? NSNumber)?.intValue else { return false }
            return code == keyCode && (mods & relevant) == (modifiers & relevant)
        }
    }
}

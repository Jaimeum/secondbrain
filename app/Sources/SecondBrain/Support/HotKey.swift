import Carbon.HIToolbox
import Foundation

/// Global ⌥⌘R via Carbon's RegisterEventHotKey, which needs no Accessibility permission.
@MainActor
final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void

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
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyId, GetApplicationEventTarget(), 0, &hotKeyRef)
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

import AppKit
import Carbon
import Foundation

/// Registers and dispatches Carbon global hot keys. Each registered hot key
/// is identified by an integer tag delivered to the handler closure.
final class HotKeyController {
    private struct Registration {
        var ref: EventHotKeyRef
        var id: UInt32
    }

    private var handlerRef: EventHandlerRef?
    private var registrations: [UInt32: Registration] = [:]
    private var nextId: UInt32 = 1
    private let onPressed: (UInt32) -> Void

    init(onPressed: @escaping (UInt32) -> Void) {
        self.onPressed = onPressed
        installHandler()
    }

    deinit {
        unregisterAll()
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    @discardableResult
    func register(hotKey: HotKey) -> UInt32? {
        guard hotKey.isEnabled else { return nil }
        let id = nextId
        nextId &+= 1

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x44697474), id: id)
        let result = RegisterEventHotKey(
            hotKey.keyCode,
            hotKey.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard result == noErr, let ref else { return nil }
        registrations[id] = Registration(ref: ref, id: id)
        return id
    }

    func unregister(id: UInt32) {
        if let registration = registrations.removeValue(forKey: id) {
            UnregisterEventHotKey(registration.ref)
        }
    }

    func unregisterAll() {
        for registration in registrations.values {
            UnregisterEventHotKey(registration.ref)
        }
        registrations.removeAll()
    }

    private func installHandler() {
        guard handlerRef == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, eventRef, userData in
                guard let userData else { return noErr }
                let controller = Unmanaged<HotKeyController>.fromOpaque(userData).takeUnretainedValue()
                var hotKeyID = EventHotKeyID()
                GetEventParameter(
                    eventRef,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                controller.onPressed(hotKeyID.id)
                return noErr
            },
            1,
            &eventType,
            selfPointer,
            &handlerRef
        )
    }
}

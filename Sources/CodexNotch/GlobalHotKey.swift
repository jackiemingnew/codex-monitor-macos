import Carbon.HIToolbox

/// A process-local Carbon hot key. Carbon registration avoids requiring
/// Accessibility or Input Monitoring permission for a single global shortcut.
final class GlobalHotKey {
    private static let monitorToggleSignature: OSType = 0x4344_584D // CDXM
    private static let monitorToggleIdentifier: UInt32 = 1

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private let action: () -> Void

    static func registerMonitorToggle(action: @escaping () -> Void) -> GlobalHotKey? {
        GlobalHotKey(
            keyCode: UInt32(kVK_ANSI_M),
            modifiers: UInt32(cmdKey | optionKey | controlKey),
            signature: monitorToggleSignature,
            identifier: monitorToggleIdentifier,
            action: action
        )
    }

    private init?(
        keyCode: UInt32,
        modifiers: UInt32,
        signature: OSType,
        identifier: UInt32,
        action: @escaping () -> Void
    ) {
        self.action = action

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            Self.handleEvent,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )
        guard handlerStatus == noErr else {
            return nil
        }

        let hotKeyID = EventHotKeyID(signature: signature, id: identifier)
        let registrationStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard registrationStatus == noErr else {
            if let eventHandlerRef {
                RemoveEventHandler(eventHandlerRef)
            }
            eventHandlerRef = nil
            return nil
        }
    }

    deinit {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
    }

    private static let handleEvent: EventHandlerUPP = { _, event, userData in
        guard let event, let userData else {
            return OSStatus(eventNotHandledErr)
        }

        var hotKeyID = EventHotKeyID()
        let parameterStatus = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )
        guard parameterStatus == noErr,
              hotKeyID.signature == monitorToggleSignature,
              hotKeyID.id == monitorToggleIdentifier else {
            return OSStatus(eventNotHandledErr)
        }

        let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
        hotKey.action()
        return noErr
    }
}

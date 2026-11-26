import AppKit
import Carbon

enum PointerAction: Int, CaseIterable {
    case grow, center, nextDisplay

    var title: String {
        switch self {
        case .grow: return "Grow pointer"
        case .center: return "Center on current display"
        case .nextDisplay: return "Center on next display"
        }
    }

    var preferenceKey: String {
        switch self {
        case .grow: return "shortcut"
        case .center: return "centerShortcut"
        case .nextDisplay: return "nextDisplayShortcut"
        }
    }

    var defaultHotkey: Hotkey {
        let (code, name): (Int, String)
        switch self {
        case .grow: (code, name) = (kVK_ANSI_M, "M")
        case .center: (code, name) = (kVK_ANSI_C, "C")
        case .nextDisplay: (code, name) = (kVK_ANSI_N, "N")
        }
        return Hotkey(keyCode: UInt32(code), modifiers: UInt32(controlKey | cmdKey), keyName: name)
    }
}

struct Hotkey: Codable {
    let keyCode: UInt32
    let modifiers: UInt32
    let keyName: String

    private static let modifierMap: [(NSEvent.ModifierFlags, UInt32, String)] = [
        (.control, UInt32(controlKey), "⌃"),
        (.option, UInt32(optionKey), "⌥"),
        (.shift, UInt32(shiftKey), "⇧"),
        (.command, UInt32(cmdKey), "⌘"),
    ]

    fileprivate init(keyCode: UInt32, modifiers: UInt32, keyName: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyName = keyName
    }

    var title: String {
        var title = ""
        for (_, flag, symbol) in Self.modifierMap where modifiers & flag != 0 { title += symbol }
        return title + keyName
    }

    init?(keyDown event: NSEvent) {
        var marks: UInt32 = 0
        for (flag, carbon, _) in Self.modifierMap where event.modifierFlags.contains(flag) { marks |= carbon }
        let key = event.charactersIgnoringModifiers ?? ""
        let scalar = key.unicodeScalars.first?.value ?? 0
        let isFunctionKey = (UInt32(NSF1FunctionKey)...UInt32(NSF20FunctionKey)).contains(scalar)
        guard marks != 0 || isFunctionKey else { return nil }

        let name: String
        if isFunctionKey {
            name = "F\(scalar - UInt32(NSF1FunctionKey) + 1)"
        } else {
            switch event.keyCode {
            case 36, 76: name = "Return"
            case 48: name = "Tab"
            case 49: name = "Space"
            case 51: name = "Delete"
            case 53: name = "Esc"
            case 117: name = "Forward Delete"
            case 123: name = "←"
            case 124: name = "→"
            case 125: name = "↓"
            case 126: name = "↑"
            default: name = key.isEmpty ? "Key \(event.keyCode)" : key.uppercased()
            }
        }
        self.init(keyCode: UInt32(event.keyCode), modifiers: marks, keyName: name)
    }
}

final class GlobalHotkey {
    private static let signature: OSType = 0x57684D4D // WhMM
    private struct Binding {
        let action: PointerAction
        let keyCode: UInt32
        let modifiers: UInt32
        let ref: EventHotKeyRef
        var isDown = false
    }

    private var handler: EventHandlerRef?
    private var bindings: [UInt32: Binding] = [:]
    private var identifier: UInt32 = 0
    var onPress: ((PointerAction) -> Void)?

    func register(_ key: Hotkey, for action: PointerAction) -> OSStatus {
        let previous = bindings.first { $0.value.action == action }
        if let previous, previous.value.keyCode == key.keyCode, previous.value.modifiers == key.modifiers { return noErr }
        let target = GetApplicationEventTarget()
        if handler == nil {
            let events = [kEventHotKeyPressed, kEventHotKeyReleased].map {
                EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32($0))
            }
            let status = InstallEventHandler(target, { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                return Unmanaged<GlobalHotkey>.fromOpaque(context).takeUnretainedValue().handle(event)
            }, events.count, events, Unmanaged.passUnretained(self).toOpaque(), &handler)
            if status != noErr { return status }
        }

        let next = identifier &+ 1
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(key.keyCode, key.modifiers, EventHotKeyID(signature: Self.signature, id: next),
                                         target, OptionBits(kEventHotKeyExclusive), &reference)
        guard status == noErr, let reference else { return status == noErr ? OSStatus(eventInternalErr) : status }
        if let previous {
            UnregisterEventHotKey(previous.value.ref)
            bindings.removeValue(forKey: previous.key)
        }
        bindings[next] = Binding(action: action, keyCode: key.keyCode, modifiers: key.modifiers, ref: reference)
        identifier = next
        return noErr
    }

    func stop() {
        for binding in bindings.values { UnregisterEventHotKey(binding.ref) }
        if let handler { RemoveEventHandler(handler) }
        bindings.removeAll()
        handler = nil
    }

    deinit { stop() }

    private func handle(_ event: EventRef) -> OSStatus {
        var id = EventHotKeyID()
        guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
              id.signature == Self.signature, let binding = bindings[id.id] else { return OSStatus(eventNotHandledErr) }
        if GetEventKind(event) == kEventHotKeyReleased {
            bindings[id.id]?.isDown = false
        } else if !binding.isDown {
            bindings[id.id]?.isDown = true
            onPress?(binding.action)
        }
        return noErr
    }
}

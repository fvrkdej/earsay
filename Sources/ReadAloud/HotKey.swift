// HotKey: claim a key combination for the whole Mac.
//
// We ask macOS (through its old but reliable "Carbon" keyboard API) to send us
// a message whenever, say, Control+Option+R is pressed, whatever app is in front.
// This kind of shortcut needs no special permission.
import Carbon

final class HotKey {
    private var ref: EventHotKeyRef?
    private var id: UInt32 = 0

    /// Give the key combination back to macOS, so other apps can use it again.
    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        HotKey.actions[id] = nil
    }
    // Every hotkey we register gets a number; this maps the number to what it should do.
    private static var actions: [UInt32: () -> Void] = [:]
    private static var listening = false

    init(id: UInt32, keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        HotKey.startListeningIfNeeded()
        HotKey.actions[id] = action
        let hotKeyID = EventHotKeyID(signature: OSType(0x5241_4C44), id: id) // "RALD"
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        self.id = id
        Log.write(status == noErr ? "hotkey \(id) registered" : "hotkey \(id) FAILED (\(status)), another app may own it")
    }

    // One listener for all our hotkeys: read which one fired, run its action.
    private static func startListeningIfNeeded() {
        guard !listening else { return }
        listening = true
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                    eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hk)
            HotKey.actions[hk.id]?()
            return noErr
        }, 1, &pressed, nil, nil)
    }
}

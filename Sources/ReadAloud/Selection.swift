// Selection: get the text you've highlighted in whatever app is in front.
//
// Two ways, tried in order:
// 1. Ask macOS's accessibility system (what screen readers use) for the selected
//    text. Works in most native Mac apps: Notes, Mail, Safari, Pages, TextEdit.
// 2. Apps built on web tech (Antigravity, VS Code, Slack, Chrome pages) often
//    answer with nothing. Then we press Cmd+C for you, read what was copied,
//    and put your clipboard back exactly as it was.
// Both need the Accessibility permission (System Settings > Privacy & Security).
import AppKit
import ApplicationServices
import Carbon

enum Selection {
    /// Do we have the Accessibility permission? With prompt: true, macOS shows its
    /// "Earsay would like to control this computer" box if we don't.
    static func hasPermission(prompt: Bool) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// The highlighted text, or nil if nothing is highlighted.
    static func grab() async -> (text: String, how: String)? {
        if let t = viaAccessibility() { return (t, "accessibility") }
        if let t = await viaCopy() { return (t, "copy") }
        return nil
    }

    // Way 1: ask the focused element for its selected text.
    static func viaAccessibility() -> String? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused else { return nil }
        var selected: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element as! AXUIElement, kAXSelectedTextAttribute as CFString, &selected) == .success,
              let text = selected as? String, !isBlank(text) else { return nil }
        return text
    }

    // Way 2: press Cmd+C, read the clipboard, then restore what was there before.
    static func viaCopy() async -> String? {
        let board = NSPasteboard.general
        let saved = snapshot(board)
        let before = board.changeCount

        pressCommandC()
        // Wait up to half a second for the app to copy.
        for _ in 0..<20 where board.changeCount == before {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        guard board.changeCount != before else { return nil }   // nothing was selected
        let text = board.string(forType: .string)
        // VS Code and apps built on it (Antigravity, Cursor) copy the whole current line when
        // nothing is highlighted, and mark it. That isn't a selection, so ignore it.
        let vscode = board.string(forType: NSPasteboard.PasteboardType("vscode-editor-data")) ?? ""
        let emptySelection = vscode.contains("\"isFromEmptySelection\":true")
        restore(board, saved)
        if emptySelection { return nil }
        guard let text, !isBlank(text) else { return nil }
        return text
    }

    private static func pressCommandC() {
        // A private event source, so the Control and Option you're still holding
        // from the shortcut don't leak in and turn it into Control+Option+Cmd+C.
        let source = CGEventSource(stateID: .privateState)
        let c = CGKeyCode(kVK_ANSI_C)
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: c, keyDown: keyDown)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
    }

    // Copy every item on the clipboard, in every format (text, images, files...).
    private static func snapshot(_ board: NSPasteboard) -> [[(NSPasteboard.PasteboardType, Data)]] {
        (board.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
    }

    private static func restore(_ board: NSPasteboard, _ saved: [[(NSPasteboard.PasteboardType, Data)]]) {
        board.clearContents()
        let items = saved.map { pairs -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in pairs { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { board.writeObjects(items) }
    }

    private static func isBlank(_ s: String) -> Bool {
        s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

import AppKit
import ApplicationServices
import Carbon.HIToolbox
import SnippetModel

/// Everything on the clipboard, so it can be put back.
nonisolated struct ClipboardContents: Hashable, Sendable {
    /// One dictionary per clipboard item: the data for each type it offers.
    var items: [[String: Data]] = []
}

/// What insertion does to the Mac: the clipboard and the few keys the app presses. Tests replace it.
protocol InsertionDevice: AnyObject {
    /// True when macOS lets the app press keys in other apps (the Accessibility permission).
    var isTrusted: Bool { get }
    /// Shows the system's request for the Accessibility permission.
    func askForTrust()
    /// True while Shift, Control, Option or Command is held down.
    var modifiersAreDown: Bool { get }
    func saveClipboard() -> ClipboardContents
    /// Puts saved contents back, unless something else has been copied since `setClipboard`.
    func restoreClipboard(_ contents: ClipboardContents)
    func setClipboard(_ text: String)
    /// Presses ⌘V.
    func paste()
    /// Presses the Left Arrow key a number of times.
    func moveLeft(_ count: Int)
    /// The text selected in the frontmost app, read through the Accessibility interface.
    func selectedText() -> String?
    /// Presses ⌘C.
    func copy()
    /// A number that changes whenever the clipboard does.
    var clipboardChangeCount: Int { get }
    func clipboardText() -> String?
}

nonisolated struct InsertionTiming: Sendable {
    /// How long the target window gets to become key again after the panel closes.
    var focusDelay = Duration.milliseconds(200)
    /// How long to wait for the hotkey's modifier keys to be let go.
    var modifierTimeout = Duration.seconds(3)
    var modifierPoll = Duration.milliseconds(20)
    /// How long the target app gets to read the clipboard after ⌘V, before the clipboard is put back.
    var pasteSettle = Duration.milliseconds(250)
    /// How long the pasted text gets to arrive before the cursor is moved.
    var cursorSettle = Duration.milliseconds(80)

    static let immediate = InsertionTiming(
        focusDelay: .zero, modifierTimeout: .milliseconds(20), modifierPoll: .milliseconds(1),
        pasteSettle: .zero, cursorSettle: .zero
    )
}

nonisolated enum InsertionError: Error, Equatable {
    case needsAccessibility
    /// A modifier key stayed down, so pressing ⌘V would have done something else.
    case modifiersHeld
    case engine(String)

    var message: String {
        switch self {
        case .needsAccessibility:
            return "Abbrio needs the Accessibility permission to paste into other apps. Allow it in System Settings › Privacy & Security › Accessibility, then try again."
        case .modifiersHeld:
            return "Nothing was inserted because a modifier key was still held down."
        case .engine(let message):
            return message
        }
    }
}

/// Puts a snippet into the frontmost app.
struct TextInserter {
    var device: any InsertionDevice
    var timing = InsertionTiming()

    /// Carries out a plan.
    ///
    /// Plain text is put on the clipboard and pasted. A snippet that needs Espanso has its trigger pasted
    /// instead; Espanso then deletes those characters and inserts the expansion. Either way the clipboard is
    /// put back, and for Espanso before it runs, so a clipboard variable sees what the user copied.
    ///
    /// - Parameter expand: Asks Espanso to expand a trigger.
    func insert(_ plan: InsertionPlan, expand: (String) async throws -> Void) async throws(InsertionError) {
        guard device.isTrusted else { throw .needsAccessibility }
        await pause(timing.focusDelay)

        // Espanso holds its own typing back while modifiers are down, and ⌘V with Control held is not Paste.
        let deadline = ContinuousClock.now + timing.modifierTimeout
        while device.modifiersAreDown {
            guard ContinuousClock.now < deadline else { throw .modifiersHeld }
            await pause(timing.modifierPoll)
        }

        let saved = device.saveClipboard()
        switch plan {
        case .paste(let text, let cursorBack):
            device.setClipboard(text)
            device.paste()
            if cursorBack > 0 {
                await pause(timing.cursorSettle)
                device.moveLeft(cursorBack)
            }
            await pause(timing.pasteSettle)
            device.restoreClipboard(saved)
        case .engine(let trigger):
            device.setClipboard(trigger)
            device.paste()
            await pause(timing.pasteSettle)
            device.restoreClipboard(saved)
            // Espanso types the expansion with whatever modifiers the system reports as down. With Command
            // down, its Backspace deletes the line and a space opens Spotlight.
            let clear = ContinuousClock.now + timing.modifierTimeout
            while device.modifiersAreDown {
                guard ContinuousClock.now < clear else {
                    throw .engine("A modifier key is still down. The abbreviation \(trigger) was left in the text.")
                }
                await pause(timing.modifierPoll)
            }
            do {
                try await expand(trigger)
            } catch {
                throw .engine(AppModel.message(for: error) + " The abbreviation \(trigger) was left in the text.")
            }
        }
    }

    private func pause(_ duration: Duration) async {
        guard duration > .zero else { return }
        try? await Task.sleep(for: duration)
    }
}

/// The real clipboard and keyboard.
final class SystemInsertionDevice: InsertionDevice {
    private let pasteboard = NSPasteboard.general
    /// The clipboard's change count right after the app last wrote to it.
    private var ownChangeCount: Int?

    var isTrusted: Bool { AXIsProcessTrusted() }

    func askForTrust() {
        let prompt = "AXTrustedCheckOptionPrompt" as CFString
        _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
    }

    var modifiersAreDown: Bool {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        return !flags.isDisjoint(with: [.maskShift, .maskControl, .maskAlternate, .maskCommand])
    }

    var clipboardChangeCount: Int { pasteboard.changeCount }

    func clipboardText() -> String? { pasteboard.string(forType: .string) }

    func saveClipboard() -> ClipboardContents {
        var contents = ClipboardContents()
        for item in pasteboard.pasteboardItems ?? [] {
            var data: [String: Data] = [:]
            for type in item.types {
                if let value = item.data(forType: type) { data[type.rawValue] = value }
            }
            contents.items.append(data)
        }
        return contents
    }

    func restoreClipboard(_ contents: ClipboardContents) {
        // Something copied in the meantime is newer than what was saved; leave it.
        guard ownChangeCount == pasteboard.changeCount else { return }
        pasteboard.clearContents()
        let items = contents.items.map { data -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, value) in data {
                item.setData(value, forType: NSPasteboard.PasteboardType(type))
            }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
        ownChangeCount = nil
    }

    func setClipboard(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        // Clipboard managers that follow this convention don't keep the entry in their history.
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        ownChangeCount = pasteboard.changeCount
    }

    func paste() {
        press(Self.keyCode(for: "v") ?? CGKeyCode(kVK_ANSI_V), flags: .maskCommand)
    }

    func copy() {
        press(Self.keyCode(for: "c") ?? CGKeyCode(kVK_ANSI_C), flags: .maskCommand)
    }

    func moveLeft(_ count: Int) {
        for _ in 0..<count {
            press(CGKeyCode(kVK_LeftArrow), flags: [])
        }
    }

    func selectedText() -> String? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return nil }
        var selection: CFTypeRef?
        // The type was checked above, so the cast can't fail.
        let element = focused as! AXUIElement
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selection) == .success,
              let text = selection as? String, !text.isEmpty
        else { return nil }
        return text
    }

    private func press(_ key: CGKeyCode, flags: CGEventFlags) {
        // A private source keeps these events out of the session's own key state. The key-up carries no
        // modifiers, so the system does not go on reporting Command as down after a paste.
        let source = CGEventSource(stateID: .privateState)
        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: isDown) else { continue }
            event.flags = isDown ? flags : []
            event.post(tap: .cghidEventTap)
        }
    }

    /// The key that types a letter in the current keyboard layout. ⌘V sits on a different key in Dvorak
    /// than in QWERTY.
    static func keyCode(for letter: Character) -> CGKeyCode? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        return data.withUnsafeBytes { bytes -> CGKeyCode? in
            guard let layout = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            for key in 0..<UInt16(50) {
                var deadKeys: UInt32 = 0
                var length = 0
                var characters = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(
                    layout, key, UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                    OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, characters.count, &length, &characters
                )
                if status == noErr, length == 1, String(utf16CodeUnits: characters, count: 1) == String(letter) {
                    return CGKeyCode(key)
                }
            }
            return nil
        }
    }
}

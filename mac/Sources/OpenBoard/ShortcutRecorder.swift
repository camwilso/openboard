import AppKit
import OpenBoardKit
import SwiftUI

/**
 A button that records the next chord pressed on the keyboard.

 Click it, press the keys, and the chord is handed back; Escape on its own cancels. The
 button's label is the recorded chord, so the control and its value are one thing —
 the same shape as the keycap buttons beside it.

 ## Why a system event tap and not `NSEvent.addLocalMonitorForEvents`

 The chord being recorded is, almost by definition, one another app already owns — a
 push-to-talk hotkey, say. That app holds a global event tap and consumes the
 keystroke, so an in-app monitor never sees the main key: it saw Control go down and
 come back up around a Tab that had been eaten, and recorded a lone ⌃. A listen-only
 tap inserted at the head of the chain sees every keystroke before anyone can consume
 it. Listen-only means the keystroke still reaches its owner, so recording a
 push-to-talk chord will start a recording there for a moment; harmless.

 ## Two things worth knowing

 - **The tap must not outlive the recording.** It is removed on record, on cancel and
   when the view goes away.
 - **A modifier on its own is a chord too.** A lone right ⌥ is a common push-to-talk
   hotkey. `keyDown` never fires for it, so `flagsChanged` is watched as well: the last
   modifier to go down is remembered and recorded when everything comes back up with no
   key pressed in between.
 */
struct ShortcutRecorder: View {
    let shortcut: Shortcut?
    let onRecord: (Shortcut) -> Void

    @StateObject private var capture = ChordCapture()

    var body: some View {
        Button(capture.isRecording ? "Press keys…" : (shortcut?.label ?? "Record shortcut")) {
            capture.isRecording ? capture.stop() : capture.start(onRecord)
        }
        .controlSize(.small)
        .onDisappear { capture.stop() }
    }
}

/// The tap, its run-loop source and the recording state. A class because the tap's
/// C callback needs a stable pointer to come back to.
@MainActor
final class ChordCapture: ObservableObject {
    @Published private(set) var isRecording = false
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var lastModifier: Shortcut?
    private var onRecord: ((Shortcut) -> Void)?

    func start(_ onRecord: @escaping (Shortcut) -> Void) {
        guard !isRecording else { return }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, _, event, context in
                if let context, let nsEvent = NSEvent(cgEvent: event) {
                    let capture = Unmanaged<ChordCapture>.fromOpaque(context).takeUnretainedValue()
                    // The source is on the main run loop, so this is the main thread.
                    MainActor.assumeIsolated { capture.handle(nsEvent) }
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: context
        ) else {
            Log.write("record: could not create an event tap — is Accessibility granted?")
            return
        }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        self.onRecord = onRecord
        lastModifier = nil
        isRecording = true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        onRecord = nil
        isRecording = false
    }

    private func handle(_ event: NSEvent) {
        let code = Int(event.keyCode)
        let modifiers = Self.modifiers(in: event.modifierFlags, keyCode: code)
        switch event.type {
        case .keyDown:
            if code == Self.escape, modifiers.isEmpty {
                stop()
                return
            }
            let name = Self.names[code] ?? (event.charactersIgnoringModifiers ?? "").uppercased()
            record(Shortcut(keyCode: code, modifiers: modifiers, key: name))
        case .flagsChanged:
            if let modifier = Self.modifierKeys[code], modifiers.contains(modifier) {
                lastModifier = Shortcut(keyCode: code, modifiers: [modifier], key: "")
            } else if modifiers.isEmpty, let chord = lastModifier {
                record(chord)
            }
        default:
            break
        }
    }

    private func record(_ chord: Shortcut) {
        let deliver = onRecord
        stop()
        deliver?(chord)
    }

    private static let escape = 53

    /// Keys with no printable character, or whose character is not their name.
    private static let names: [Int: String] = [
        49: "Space", 36: "Return", 76: "Enter", 48: "Tab", 53: "Escape",
        51: "Delete", 117: "Forward Delete",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        115: "Home", 119: "End", 116: "Page Up", 121: "Page Down",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    /// AppKit sets the `function` flag for these whether or not fn is held, so fn is
    /// only believed on a key outside this set.
    private static let functionKeys: Set<Int> = [
        123, 124, 125, 126, 115, 119, 116, 121, 117,
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111,
    ]

    /// The modifier keys by their own key codes, left and right.
    private static let modifierKeys: [Int: Shortcut.Modifier] = [
        55: .command, 54: .command,
        56: .shift, 60: .shift,
        58: .option, 61: .option,
        59: .control, 62: .control,
        63: .function,
    ]

    private static func modifiers(in flags: NSEvent.ModifierFlags, keyCode: Int) -> Set<Shortcut.Modifier> {
        var result: Set<Shortcut.Modifier> = []
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.function), !functionKeys.contains(keyCode) { result.insert(.function) }
        return result
    }
}

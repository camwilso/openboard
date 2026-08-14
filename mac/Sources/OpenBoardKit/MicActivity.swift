import CoreAudio
import Foundation

/**
 Whether the default input device is actually recording, for anyone.

 `kAudioDevicePropertyDeviceIsRunningSomewhere` is the ground truth behind the orange
 menu-bar dot: it flips when *any* process starts or stops pulling from the device,
 dictation included. Reading it needs no microphone permission — it is device state,
 not audio — and the listener is event-driven, so there is no polling.

 Two listeners, both necessary:

 - the running-state property on the current default input device, and
 - the default-device property on the system object, because AirPods connecting (or a
   USB interface waking) silently moves the default, and a listener left on the old
   device reports on hardware nobody is recording from.

 System-wide on purpose. This cannot say *who* is recording — that conjunction with
 the board's own belief is `VoiceSignal`'s job, and the split is what keeps each half
 testable.
 */
public final class MicActivity: @unchecked Sendable {
    private let queue = DispatchQueue(label: "board.mic-activity")
    private var onChange: (@Sendable (Bool) -> Void)?
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var runningBlock: AudioObjectPropertyListenerBlock?
    private var defaultBlock: AudioObjectPropertyListenerBlock?

    private static let runningAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private static let defaultAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    public init() {}

    /// The current default input device's running state, read on demand. `false` when
    /// there is no input device at all — a Mac mini with nothing plugged in is not
    /// recording, whatever else is wrong with it.
    public var isRunning: Bool {
        let device = Self.defaultInputDevice()
        guard device != kAudioObjectUnknown else { return false }
        return Self.isRunning(device: device)
    }

    /// Begin watching. The callback fires on an internal queue with the new running
    /// state, on every transition and on default-device moves. Idempotent start is
    /// not supported — one watcher per instance, matching how `HIDDevice.onLine`
    /// hands out its stream.
    public func watch(_ handler: @escaping @Sendable (Bool) -> Void) {
        onChange = handler
        var address = Self.defaultAddress
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            self.attachToDefaultDevice()
            self.onChange?(self.isRunning)
        }
        defaultBlock = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, queue, block
        )
        attachToDefaultDevice()
    }

    public func stop() {
        detach()
        if let defaultBlock {
            var address = Self.defaultAddress
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, queue, defaultBlock
            )
        }
        defaultBlock = nil
        onChange = nil
    }

    private func attachToDefaultDevice() {
        detach()
        let next = Self.defaultInputDevice()
        guard next != kAudioObjectUnknown else { return }
        device = next
        var address = Self.runningAddress
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            self.onChange?(self.isRunning)
        }
        runningBlock = block
        AudioObjectAddPropertyListenerBlock(device, &address, queue, block)
    }

    private func detach() {
        if let runningBlock, device != kAudioObjectUnknown {
            var address = Self.runningAddress
            AudioObjectRemovePropertyListenerBlock(device, &address, queue, runningBlock)
        }
        runningBlock = nil
        device = AudioObjectID(kAudioObjectUnknown)
    }

    private static func defaultInputDevice() -> AudioObjectID {
        var address = defaultAddress
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
        )
        return status == noErr ? device : AudioObjectID(kAudioObjectUnknown)
    }

    private static func isRunning(device: AudioObjectID) -> Bool {
        var address = runningAddress
        var running = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running)
        return status == noErr && running != 0
    }
}

import AudioToolbox
import CoreAudio
import Foundation

/// Reads, sets and observes the default output device's volume through CoreAudio.
@MainActor
final class SystemVolume {
    var onChange: ((Float) -> Void)?
    /// Volume or mute changed by the keys or another app (not Islet's own slider, not a
    /// change of output device): the island shows its volume level.
    var onUserChange: ((Float, Bool) -> Void)?

    private var device = AudioObjectID(kAudioObjectUnknown)
    private var volumeListener: AudioObjectPropertyListenerBlock?
    private var muteListener: AudioObjectPropertyListenerBlock?
    /// When Islet last set the volume itself; its own changes don't pop the level up.
    private var setByIsletAt: TimeInterval = 0
    /// When the output last switched (headphones connecting): the new device syncs its
    /// volume for a moment, which isn't the user pressing a key.
    private var deviceChangedAt: TimeInterval = 0

    private static var muteAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
    }

    var muted: Bool {
        var address = Self.muteAddress
        guard device != kAudioObjectUnknown, AudioObjectHasProperty(device, &address) else { return false }
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr && value != 0
    }
    private var deviceListener: AudioObjectPropertyListenerBlock?

    private static var volumeAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
    }

    private static var defaultDeviceAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    var volume: Float? {
        var address = Self.volumeAddress
        guard device != kAudioObjectUnknown, AudioObjectHasProperty(device, &address) else { return nil }
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    func setVolume(_ newValue: Float) {
        var address = Self.volumeAddress
        var settable = DarwinBoolean(false)
        guard device != kAudioObjectUnknown,
              AudioObjectIsPropertySettable(device, &address, &settable) == noErr,
              settable.boolValue else { return }
        setByIsletAt = ProcessInfo.processInfo.systemUptime
        writer.write(Float32(min(max(newValue, 0), 1)), to: device)
    }

    /// Setting the volume can block for 70–85 ms on Bluetooth headphones, so it happens off
    /// the main thread (a slider drag would otherwise stutter).
    private let writer = VolumeWriter()

    func setMuted(_ muted: Bool) {
        var address = Self.muteAddress
        var settable = DarwinBoolean(false)
        guard device != kAudioObjectUnknown, AudioObjectHasProperty(device, &address),
              AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue else { return }
        var value = UInt32(muted ? 1 : 0)
        setByIsletAt = ProcessInfo.processInfo.systemUptime
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }

    func startListening() {
        attachToDefaultDevice()
        var address = Self.defaultDeviceAddress
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.deviceChangedAt = ProcessInfo.processInfo.systemUptime
                self?.attachToDefaultDevice()
                if let volume = self?.volume { self?.onChange?(volume) }
            }
        }
        deviceListener = listener
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
    }

    private func attachToDefaultDevice() {
        var address = Self.volumeAddress
        if let volumeListener, device != kAudioObjectUnknown {
            AudioObjectRemovePropertyListenerBlock(device, &address, .main, volumeListener)
        }
        var mute = Self.muteAddress
        if let muteListener, device != kAudioObjectUnknown {
            AudioObjectRemovePropertyListenerBlock(device, &mute, .main, muteListener)
        }
        muteListener = nil
        var deviceAddress = Self.defaultDeviceAddress
        var newDevice = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &deviceAddress, 0, nil, &size, &newDevice)
        device = newDevice
        guard device != kAudioObjectUnknown, AudioObjectHasProperty(device, &address) else { return }
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self, let volume = self.volume else { return }
                self.onChange?(volume)
                self.reportUserChange(volume)
            }
        }
        volumeListener = listener
        AudioObjectAddPropertyListenerBlock(device, &address, .main, listener)
        if AudioObjectHasProperty(device, &mute) {
            let muteChanged: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated {
                    guard let self, let volume = self.volume else { return }
                    self.reportUserChange(volume)
                }
            }
            muteListener = muteChanged
            AudioObjectAddPropertyListenerBlock(device, &mute, .main, muteChanged)
        }
    }

    private func reportUserChange(_ volume: Float) {
        let now = ProcessInfo.processInfo.systemUptime
        Log.island.debug("Volume event \(volume, format: .fixed(precision: 3))")
        // Bluetooth headphones confirm Islet's own changes up to ~2 s late.
        guard now - setByIsletAt > 2, now - deviceChangedAt > 3 else { return }
        onUserChange?(volume, muted)
    }
}

/// Applies volume changes on a background queue, keeping only the newest while one is still
/// being sent to the device: a fast drag never queues up stale levels.
private final class VolumeWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "local.islet.volume", qos: .userInitiated)
    private let lock = NSLock()
    private var pending: (device: AudioObjectID, value: Float32)?
    private var draining = false

    func write(_ value: Float32, to device: AudioObjectID) {
        let start = lock.withLock {
            pending = (device, value)
            if draining { return false }
            draining = true
            return true
        }
        if start { queue.async { self.drain() } }
    }

    private func drain() {
        while true {
            let job: (device: AudioObjectID, value: Float32)? = lock.withLock {
                let next = pending
                pending = nil
                if next == nil { draining = false }
                return next
            }
            guard let job else { return }
            var value = job.value
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain)
            AudioObjectSetPropertyData(job.device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
        }
    }
}

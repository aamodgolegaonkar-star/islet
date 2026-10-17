import CoreAudio
import CoreGraphics
import CoreMediaIO
import Foundation
import IsletCore

/// Screen brightness changes, through DisplayServices (private; resolved at run time, and
/// silently off if missing). It reports every change, including the slow drift of
/// automatic brightness, so only clear steps, like a key press, are passed on.
@MainActor
final class BrightnessMonitor {
    static let shared = BrightnessMonitor()

    var onUserChange: ((Double) -> Void)?
    private var last: Double?

    private typealias Register = @convention(c) (CGDirectDisplayID, UnsafeRawPointer?, CFNotificationCallback) -> Int32
    private typealias Get = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private var get: Get?
    private var started = false

    func start() {
        guard !started,
              let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
              let register = dlsym(handle, "DisplayServicesRegisterForBrightnessChangeNotifications"),
              let get = dlsym(handle, "DisplayServicesGetBrightness")
        else { return }
        started = true
        self.get = unsafeBitCast(get, to: Get.self)
        last = current
        let callback: CFNotificationCallback = { _, _, _, _, info in
            let value = ((info as NSDictionary?)?["value"] as? NSNumber)?.doubleValue
            DispatchQueue.main.async {
                MainActor.assumeIsolated { BrightnessMonitor.shared.changed(to: value) }
            }
        }
        _ = unsafeBitCast(register, to: Register.self)(CGMainDisplayID(), nil, callback)
    }

    /// Sets the brightness directly (the island's slider).
    func set(_ value: Double) {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
              let symbol = dlsym(handle, "DisplayServicesSetBrightness") else { return }
        typealias Set = @convention(c) (CGDirectDisplayID, Float) -> Int32
        let clamped = min(max(value, 0), 1)
        last = clamped
        _ = unsafeBitCast(symbol, to: Set.self)(CGMainDisplayID(), Float(clamped))
    }

    /// One brightness key press (1/16, or a quarter step with ⌥⇧). Returns the new level.
    func step(_ direction: Int, fine: Bool) -> Double? {
        guard let value = current,
              let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
              let symbol = dlsym(handle, "DisplayServicesSetBrightness") else { return nil }
        typealias Set = @convention(c) (CGDirectDisplayID, Float) -> Int32
        let step = fine ? 1.0 / 64 : 1.0 / 16
        let next = min(max(((value / step).rounded() + Double(direction)) * step, 0), 1)
        _ = unsafeBitCast(symbol, to: Set.self)(CGMainDisplayID(), Float(next))
        last = next
        return next
    }

    /// The last level read or set, without asking the display again.
    var level: Double? { last ?? current }

    var current: Double? {
        var value: Float = 0
        guard let get, get(CGMainDisplayID(), &value) == 0 else { return nil }
        return Double(value)
    }

    private func changed(to reported: Double?) {
        guard let value = reported ?? current else { return }
        defer { last = value }
        // Brightness keys step by about 1/16; automatic brightness creeps in tiny steps.
        guard let last, abs(value - last) >= 0.03 else { return }
        onUserChange?(value)
    }
}

/// Headphones connecting: a new Bluetooth audio output appears in CoreAudio (no Bluetooth
/// permission needed). system_profiler then supplies the model numbers and, for Apple
/// and Beats, the battery levels.
@MainActor
final class HeadphoneMonitor {
    var onConnect: ((HeadphoneCard) -> Void)?

    private var known: Set<AudioObjectID> = []
    private var listener: AudioObjectPropertyListenerBlock?
    private var outputListener: AudioObjectPropertyListenerBlock?
    private var defaultOutput = AudioObjectID(kAudioObjectUnknown)
    /// One card per connection, however many CoreAudio events it causes.
    private var lastShown: (name: String, time: TimeInterval)?

    private static var defaultOutputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static var devicesAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    func start() {
        guard listener == nil else { return }
        known = Set(bluetoothOutputs().keys)
        var address = Self.devicesAddress
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.devicesChanged() }
        }
        listener = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        // macOS may keep a disconnected pair listed, so its return doesn't always add a
        // device: sound switching over to Bluetooth headphones counts as connecting too.
        defaultOutput = currentDefaultOutput()
        var output = Self.defaultOutputAddress
        let outputBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.outputChanged() }
        }
        outputListener = outputBlock
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &output, .main, outputBlock)
    }

    private func currentDefaultOutput() -> AudioObjectID {
        var address = Self.defaultOutputAddress
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return device
    }

    private func outputChanged() {
        let device = currentDefaultOutput()
        guard device != defaultOutput else { return }
        defaultOutput = device
        if let name = bluetoothOutputs()[device] { identify(name) }
    }

    private func devicesChanged() {
        let outputs = bluetoothOutputs()
        let added = outputs.filter { !known.contains($0.key) }
        known = Set(outputs.keys)
        for name in added.values { identify(name) }
    }

    private func identify(_ name: String) {
        let now = ProcessInfo.processInfo.systemUptime
        if let last = lastShown, last.name == name, now - last.time < 8 { return }
        lastShown = (name, now)
        Log.island.notice("Headphones connected: \(name, privacy: .public)")
        Task {
            let info = await Self.bluetoothInfo(named: name)
            let model = HeadphoneCatalog.identify(name: name, vendorID: info?.vendor, productID: info?.product)
            self.onConnect?(HeadphoneCard(deviceName: name, model: model, battery: info?.battery ?? .init()))
        }
    }

    /// Bluetooth audio outputs by CoreAudio ID, with their names.
    private func bluetoothOutputs() -> [AudioObjectID: String] {
        var address = Self.devicesAddress
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [:] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [:] }
        var result: [AudioObjectID: String] = [:]
        for id in ids {
            var transport = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                                       mScope: kAudioObjectPropertyScopeGlobal,
                                                       mElement: kAudioObjectPropertyElementMain)
            var type: UInt32 = 0
            var typeSize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(id, &transport, 0, nil, &typeSize, &type) == noErr,
                  type == kAudioDeviceTransportTypeBluetooth || type == kAudioDeviceTransportTypeBluetoothLE
            else { continue }
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                     mScope: kAudioDevicePropertyScopeOutput,
                                                     mElement: kAudioObjectPropertyElementMain)
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamSize) == noErr, streamSize > 0 else { continue }
            var nameAddress = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                         mScope: kAudioObjectPropertyScopeGlobal,
                                                         mElement: kAudioObjectPropertyElementMain)
            var name: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(id, &nameAddress, 0, nil, &nameSize, &name) == noErr,
                  let value = name?.takeRetainedValue() as String? else { continue }
            result[id] = value
        }
        return result
    }

    private struct Info: Sendable {
        var vendor: Int?
        var product: Int?
        var battery = HeadphoneBattery()
    }

    /// Model numbers and battery for a connected device, from system_profiler's JSON.
    private nonisolated static func bluetoothInfo(named name: String) async -> Info? {
        // Battery levels appear a moment after the connection.
        try? await Task.sleep(for: .seconds(1.5))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let section = (root["SPBluetoothDataType"] as? [[String: Any]])?.first,
              let connected = section["device_connected"] as? [[String: Any]],
              let entry = connected.lazy.compactMap({ $0[name] as? [String: Any] }).first
        else { return nil }
        let percent = { (key: String) -> Int? in
            (entry[key] as? String).flatMap { Int($0.replacing("%", with: "").trimmingCharacters(in: .whitespaces)) }
        }
        return Info(
            vendor: HeadphoneCatalog.number(entry["device_vendorID"] as? String),
            product: HeadphoneCatalog.number(entry["device_productID"] as? String),
            battery: HeadphoneBattery(left: percent("device_batteryLevelLeft"), right: percent("device_batteryLevelRight"),
                                      case: percent("device_batteryLevelCase"), single: percent("device_batteryLevelMain")))
    }
}

struct HeadphoneBattery: Equatable, Sendable {
    var left: Int?
    var right: Int?
    var `case`: Int?
    var single: Int?
}

/// What the island shows when headphones connect.
struct HeadphoneCard: Equatable, Sendable {
    /// The name the owner gave them ("Paarth's AirPods Max").
    var deviceName: String
    var model: HeadphoneModel?
    var battery: HeadphoneBattery
}

/// Whether any app is using a microphone or a camera right now (the iPhone's orange and
/// green dots). Both are change notifications from CoreAudio / CoreMediaIO: no polling, and
/// no access to the audio or video itself.
@MainActor
final class PrivacyMonitor {
    var onChange: ((_ mic: Bool, _ camera: Bool) -> Void)?
    private var micDevices: [AudioObjectID] = []
    private var cameraDevices: [CMIOObjectID] = []
    private var audioListener: AudioObjectPropertyListenerBlock?
    private var cameraListener: CMIOObjectPropertyListenerBlock?
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        let audio: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        audioListener = audio
        var devices = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &devices, .main, { [weak self] _, _ in
            MainActor.assumeIsolated { self?.rewatch() }
        })
        let camera: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.refresh() } }
        }
        cameraListener = camera
        rewatch()
    }

    /// Watches "running somewhere" on every input device and camera (devices come and go).
    private func rewatch() {
        guard let audioListener, let cameraListener else { return }
        var running = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        for device in micDevices { AudioObjectRemovePropertyListenerBlock(device, &running, .main, audioListener) }
        micDevices = Self.inputDevices()
        for device in micDevices { AudioObjectAddPropertyListenerBlock(device, &running, .main, audioListener) }

        var cameraRunning = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                                                      mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                                      mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        for device in cameraDevices { CMIOObjectRemovePropertyListenerBlock(device, &cameraRunning, .main, cameraListener) }
        cameraDevices = Self.cameras()
        for device in cameraDevices { CMIOObjectAddPropertyListenerBlock(device, &cameraRunning, .main, cameraListener) }
        refresh()
    }

    private func refresh() {
        let mic = micDevices.contains { Self.isRunning($0) }
        let camera = cameraDevices.contains { Self.cameraIsRunning($0) }
        onChange?(mic, camera)
    }

    private static func inputDevices() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter { id in
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                     mScope: kAudioDevicePropertyScopeInput,
                                                     mElement: kAudioObjectPropertyElementMain)
            var streamSize: UInt32 = 0
            return AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamSize) == noErr && streamSize > 0
        }
    }

    private static func isRunning(_ device: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr && value != 0
    }

    private static func cameras() -> [CMIOObjectID] {
        var address = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
                                                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var size: UInt32 = 0
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        guard CMIOObjectGetPropertyDataSize(system, &address, 0, nil, &size) == 0 else { return [] }
        var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(system, &address, 0, nil, size, &used, &ids) == 0 else { return [] }
        return ids
    }

    private static func cameraIsRunning(_ device: CMIOObjectID) -> Bool {
        var address = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                                                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var value: UInt32 = 0
        var used: UInt32 = 0
        return CMIOObjectGetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &value) == 0
            && value != 0
    }
}

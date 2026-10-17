import AppKit
import CoreAudio
import IOBluetooth
import IsletCore

/// One place sound can go: a CoreAudio output, one AirPlay receiver (a HomePod, an Apple TV)
/// of the AirPlay device, or paired Bluetooth headphones that aren't connected yet.
struct AudioOutput: Identifiable, Equatable {
    enum Kind: Equatable { case builtIn, bluetooth, airPlay, wired, virtual }

    var id: String
    var name: String
    var kind: Kind
    var symbol: String
    var isCurrent: Bool
    /// False for paired headphones that aren't connected: choosing them connects them first.
    var isConnected = true
    var device: AudioObjectID?
    /// The AirPlay receiver within the AirPlay device.
    var dataSource: UInt32?
    var bluetoothAddress: String?
}

/// Lists outputs and switches between them, like the Sound menu in Control Center. Paired
/// headphones show even before they're worn: choosing them connects them over Bluetooth.
@MainActor
enum AudioOutputs {
    static func list() -> [AudioOutput] {
        let current = defaultOutput()
        var outputs: [AudioOutput] = []
        for device in outputDevices() {
            guard !bool(device, kAudioDevicePropertyIsHidden) else { continue }
            let name = string(device, kAudioObjectPropertyName) ?? "Output"
            let transport = uint(device, kAudioDevicePropertyTransportType) ?? 0
            if transport == kAudioDeviceTransportTypeAirPlay {
                // One entry per receiver; the device itself is just "AirPlay".
                let selected = uint(device, kAudioDevicePropertyDataSource, scope: kAudioDevicePropertyScopeOutput)
                for source in dataSources(device) {
                    let receiver = dataSourceName(device, source) ?? name
                    outputs.append(AudioOutput(
                        id: "air:\(device):\(source)", name: receiver, kind: .airPlay,
                        symbol: receiver.localizedCaseInsensitiveContains("homepod") ? "homepod.fill" : "airplay.audio",
                        isCurrent: device == current && selected == source, device: device, dataSource: source))
                }
                continue
            }
            let kind: AudioOutput.Kind = switch transport {
            case kAudioDeviceTransportTypeBuiltIn: .builtIn
            case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: .bluetooth
            case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate: .virtual
            default: .wired
            }
            outputs.append(AudioOutput(id: "dev:\(device)", name: name, kind: kind,
                                       symbol: symbol(kind: kind, name: name), isCurrent: device == current,
                                       device: device))
        }
        // Paired headphones that aren't connected right now.
        var present = Set(outputs.map { $0.name.lowercased() })
        for device in pairedHeadphones() where !device.isConnected() {
            // macOS can keep two pairings of one device; list it once.
            guard let name = device.name, present.insert(name.lowercased()).inserted else { continue }
            outputs.append(AudioOutput(id: "bt:\(device.addressString ?? name)", name: name, kind: .bluetooth,
                                       symbol: symbol(kind: .bluetooth, name: name), isCurrent: false,
                                       isConnected: false, bluetoothAddress: device.addressString))
        }
        return outputs
    }

    /// The current output's name and glyph, for the island's button.
    static var currentSymbol: String {
        list().first(where: \.isCurrent)?.symbol ?? "hifispeaker.fill"
    }

    static func select(_ output: AudioOutput) {
        if let device = output.device {
            if let source = output.dataSource {
                var value = source
                set(device, kAudioDevicePropertyDataSource, &value, scope: kAudioDevicePropertyScopeOutput)
            }
            setDefaultOutput(device)
            return
        }
        guard let address = output.bluetoothAddress else { return }
        let name = output.name
        Log.media.notice("Connecting \(name, privacy: .public)")
        Task.detached {
            let result = await MainActor.run { IOBluetoothDevice(addressString: address)?.openConnection() }
            guard result == kIOReturnSuccess else {
                Log.media.error("Couldn't connect \(name, privacy: .public)")
                return
            }
            // The headphones become an output a moment after they connect.
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(400))
                let found = await MainActor.run { () -> Bool in
                    guard let device = outputDevices().first(where: { (string($0, kAudioObjectPropertyName) ?? "") == name })
                    else { return false }
                    setDefaultOutput(device)
                    return true
                }
                if found { return }
            }
        }
    }

    // MARK: - AirPods listening mode

    /// Noise control on AirPods Pro, AirPods Max, AirPods 4 (ANC) and similar Beats.
    enum ListeningMode: UInt8, CaseIterable {
        case off = 1
        case noiseCancellation = 2
        case transparency = 3
        case adaptive = 4

        var title: String {
            switch self {
            case .off: "Off"
            case .noiseCancellation: "Noise Cancellation"
            case .transparency: "Transparency"
            case .adaptive: "Adaptive"
            }
        }

        var symbol: String {
            switch self {
            case .off: "person.fill"
            case .noiseCancellation: "person.crop.circle.badge.minus"
            case .transparency: "person.wave.2.fill"
            case .adaptive: "sparkles"
            }
        }
    }

    /// The connected headphones playing now, when they have noise control.
    static func noiseControlHeadphones() -> IOBluetoothDevice? {
        guard let current = list().first(where: \.isCurrent), current.kind == .bluetooth else { return nil }
        return pairedHeadphones().first { device in
            device.isConnected() && device.name == current.name
                && responds(device, "isANCSupported") && responds(device, "listeningMode")
                && (call(device, "isANCSupported") || call(device, "isTransparencySupported"))
        }
    }

    static func listeningMode(of device: IOBluetoothDevice) -> ListeningMode? {
        typealias Get = @convention(c) (AnyObject, Selector) -> UInt8
        let selector = NSSelectorFromString("listeningMode")
        guard let method = class_getInstanceMethod(type(of: device), selector) else { return nil }
        return ListeningMode(rawValue: unsafeBitCast(method_getImplementation(method), to: Get.self)(device, selector))
    }

    static func setListeningMode(_ mode: ListeningMode, on device: IOBluetoothDevice) {
        typealias Set = @convention(c) (AnyObject, Selector, UInt8) -> Void
        let selector = NSSelectorFromString("setListeningMode:")
        guard let method = class_getInstanceMethod(type(of: device), selector) else { return }
        unsafeBitCast(method_getImplementation(method), to: Set.self)(device, selector, mode.rawValue)
    }

    /// The modes these headphones offer (Adaptive only on models that have it).
    static func listeningModes(of device: IOBluetoothDevice) -> [ListeningMode] {
        var modes: [ListeningMode] = [.off]
        if call(device, "isANCSupported") { modes.append(.noiseCancellation) }
        if call(device, "isTransparencySupported") { modes.append(.transparency) }
        let name = (device.name ?? "").lowercased()
        let adaptive = name.contains("airpods pro") || name.contains("airpods 4")
            || listeningMode(of: device) == .adaptive
        if adaptive, modes.contains(.noiseCancellation) { modes.append(.adaptive) }
        return modes
    }

    // MARK: - Bluetooth

    /// Paired headphones and speakers (Bluetooth major class "audio").
    static func pairedHeadphones() -> [IOBluetoothDevice] {
        (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? [])
            .filter { $0.deviceClassMajor == kBluetoothDeviceClassMajorAudio }
    }

    private static func responds(_ device: IOBluetoothDevice, _ name: String) -> Bool {
        device.responds(to: NSSelectorFromString(name))
    }

    private static func call(_ device: IOBluetoothDevice, _ name: String) -> Bool {
        typealias Get = @convention(c) (AnyObject, Selector) -> Bool
        let selector = NSSelectorFromString(name)
        guard let method = class_getInstanceMethod(type(of: device), selector) else { return false }
        return unsafeBitCast(method_getImplementation(method), to: Get.self)(device, selector)
    }

    // MARK: - CoreAudio

    private static func symbol(kind: AudioOutput.Kind, name: String) -> String {
        switch kind {
        case .builtIn: return "laptopcomputer"
        case .airPlay: return "airplay.audio"
        case .virtual: return "square.stack.3d.down.forward.fill"
        case .wired: return name.localizedCaseInsensitiveContains("display") ? "display" : "hifispeaker.fill"
        case .bluetooth:
            if let model = HeadphoneCatalog.identify(name: name, vendorID: nil, productID: nil) { return model.symbol }
            return name.localizedCaseInsensitiveContains("speaker") || name.localizedCaseInsensitiveContains("jbl")
                ? "hifispeaker.fill" : "headphones"
        }
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func defaultOutput() -> AudioObjectID {
        uint(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice) ?? 0
    }

    private static func setDefaultOutput(_ device: AudioObjectID) {
        var value = device
        set(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, &value)
    }

    /// Devices with output streams.
    static func outputDevices() -> [AudioObjectID] {
        var address = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter { id in
            var streams = Self.address(kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeOutput)
            var streamSize: UInt32 = 0
            return AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamSize) == noErr && streamSize > 0
        }
    }

    private static func dataSources(_ device: AudioObjectID) -> [UInt32] {
        var address = address(kAudioDevicePropertyDataSources, scope: kAudioDevicePropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var sources = [UInt32](repeating: 0, count: Int(size) / MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &sources) == noErr else { return [] }
        return sources
    }

    private static func dataSourceName(_ device: AudioObjectID, _ source: UInt32) -> String? {
        var address = address(kAudioDevicePropertyDataSourceNameForIDCFString, scope: kAudioDevicePropertyScopeOutput)
        var input = source
        var name: Unmanaged<CFString>?
        return withUnsafeMutablePointer(to: &input) { inputPointer in
            withUnsafeMutablePointer(to: &name) { namePointer in
                var translation = AudioValueTranslation(
                    mInputData: inputPointer, mInputDataSize: UInt32(MemoryLayout<UInt32>.size),
                    mOutputData: namePointer, mOutputDataSize: UInt32(MemoryLayout<Unmanaged<CFString>?>.size))
                var size = UInt32(MemoryLayout<AudioValueTranslation>.size)
                guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &translation) == noErr else { return nil }
                return namePointer.pointee?.takeRetainedValue() as String?
            }
        }
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private static func uint(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                             scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        var address = address(selector, scope: scope)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func bool(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Bool {
        (uint(object, selector) ?? 0) != 0
    }

    private static func set(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: inout UInt32,
                            scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) {
        var address = address(selector, scope: scope)
        AudioObjectSetPropertyData(object, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }
}

/// The output picker: a menu of outputs (with the headphones' noise control when they have
/// it), opened under a button in the island.
@MainActor
final class OutputMenu: NSObject {
    static let shared = OutputMenu()
    private var outputs: [AudioOutput] = []
    private weak var headphones: IOBluetoothDevice?

    /// Shows the menu under `view`; returns once it closes.
    func show(from view: NSView) {
        outputs = AudioOutputs.list()
        let menu = NSMenu()
        menu.autoenablesItems = false
        let connected = outputs.filter(\.isConnected)
        let paired = outputs.filter { !$0.isConnected }
        menu.addItem(.sectionHeader(title: "Sound Output"))
        for output in connected { menu.addItem(item(for: output)) }
        if !paired.isEmpty {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: "Headphones"))
            for output in paired { menu.addItem(item(for: output)) }
        }
        if let device = AudioOutputs.noiseControlHeadphones() {
            headphones = device
            let current = AudioOutputs.listeningMode(of: device)
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: "Noise Control"))
            for mode in AudioOutputs.listeningModes(of: device) {
                let entry = NSMenuItem(title: mode.title, action: #selector(chooseMode(_:)), keyEquivalent: "")
                entry.target = self
                entry.tag = Int(mode.rawValue)
                entry.image = NSImage(systemSymbolName: mode.symbol, accessibilityDescription: nil)
                entry.state = mode == current ? .on : .off
                menu.addItem(entry)
            }
        }
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Sound Settings…", action: #selector(openSoundSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 4), in: view)
    }

    private func item(for output: AudioOutput) -> NSMenuItem {
        let entry = NSMenuItem(title: output.name, action: #selector(choose(_:)), keyEquivalent: "")
        entry.target = self
        entry.representedObject = output.id
        entry.image = NSImage(systemSymbolName: output.symbol, accessibilityDescription: nil)
        entry.state = output.isCurrent ? .on : .off
        if !output.isConnected { entry.toolTip = "Connect and switch to \(output.name)" }
        return entry
    }

    @objc private func choose(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let output = outputs.first(where: { $0.id == id }) else { return }
        AudioOutputs.select(output)
    }

    @objc private func chooseMode(_ sender: NSMenuItem) {
        guard let headphones, let mode = AudioOutputs.ListeningMode(rawValue: UInt8(sender.tag)) else { return }
        AudioOutputs.setListeningMode(mode, on: headphones)
    }

    @objc private func openSoundSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// The current output's glyph and the headphones' noise-control mode, for the island.
@MainActor
@Observable
final class OutputStatus {
    static let shared = OutputStatus()

    private(set) var symbol = "hifispeaker.fill"
    private(set) var name = ""
    /// Set while headphones with noise control are playing.
    private(set) var listeningMode: AudioOutputs.ListeningMode?
    @ObservationIgnored private var listener: AudioObjectPropertyListenerBlock?

    func start() {
        guard listener == nil else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        listener = block
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        refresh()
    }

    func refresh() {
        let current = AudioOutputs.list().first(where: \.isCurrent)
        if symbol != current?.symbol ?? "hifispeaker.fill" { symbol = current?.symbol ?? "hifispeaker.fill" }
        if name != current?.name ?? "" { name = current?.name ?? "" }
        let mode = AudioOutputs.noiseControlHeadphones().flatMap(AudioOutputs.listeningMode(of:))
        if listeningMode != mode { listeningMode = mode }
    }
}

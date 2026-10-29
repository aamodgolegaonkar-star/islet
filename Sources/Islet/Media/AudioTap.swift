import Accelerate
import AppKit
import AudioToolbox
import CoreAudio
import Observation
import Synchronization

/// Taps the playing app's audio with a Core Audio process tap (macOS 14.2+) for two things:
///
/// - The equalizer: the app's own output is muted while tapped, its audio runs through ten
///   biquad filters on the real-time thread, and Islet plays the result on the same output.
///   If Islet stops or quits, the tap goes away and the app is heard directly again.
/// - The live waveform: the same audio (or, without the equalizer, an unmuted tap) is
///   analysed into frequency bands for the bars.
///
/// Both need the Audio Recording permission (asked once, the first time a tap is made).
@MainActor
final class AudioTapEngine {
    static let shared = AudioTapEngine()

    /// What should run; set by the app, which knows the settings and what's playing.
    struct Wants: Equatable {
        var target: String?
        var equalizer = false
        var levels = false
    }

    private var wants = Wants()
    private var running: (wants: Wants, processes: [AudioObjectID], output: AudioObjectID)?
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var aggregate = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let shared = TapState()
    private var bands: [Double] = Equalizer.flat
    private var preamp: Double = 0
    private var sampleRate: Double = 48000
    private var listeners: [(AudioObjectPropertySelector, AudioObjectPropertyListenerBlock)] = []
    private var rebuildTask: Task<Void, Never>?
    private var analysisTimer: Timer?
    /// The tap couldn't be made (permission refused): don't keep trying until wants change.
    private var failedFor: Wants?

    private init() {}

    func update(_ new: Wants) {
        guard new != wants else { return }
        wants = new
        failedFor = nil
        // Coalesced: building a tap makes a private audio device on the output, and a
        // quick run of changes (a track change, the island opening) shouldn't each do it.
        scheduleRebuild(delay: 0.8)
    }

    func setEqualizer(bands: [Double], preamp: Double) {
        guard bands != self.bands || preamp != self.preamp else { return }
        self.bands = bands
        self.preamp = preamp
        pushCoefficients()
    }

    // MARK: - Building the tap

    private func scheduleRebuild(delay: Double) {
        rebuildTask?.cancel()
        rebuildTask = Task { @MainActor [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard let self, !Task.isCancelled else { return }
            self.rebuild()
        }
    }

    /// Waiting for the Audio Recording answer.
    private var permissionWatch: Task<Void, Never>?

    private func rebuild() {
        watchSystem()
        var active = wants.target != nil && (wants.equalizer || wants.levels) && failedFor != wants
        let wants = self.wants
        if active, AudioCapturePermission.status != .granted {
            // Without permission a tap hears silence (and an equalizer tap would mute the
            // app), and no prompt comes for a self-signed app. Make none: wait for the
            // switch in Privacy & Security, then build.
            active = false
            watchPermission()
        }
        let processes = active ? Self.processes(for: wants.target ?? "") : []
        let output = AudioOutputs.defaultOutput()
        if let running, running.wants == wants, running.processes == processes, running.output == output { return }
        teardown()
        guard active, !processes.isEmpty, output != kAudioObjectUnknown,
              let outputUID = AudioOutputs.string(output, kAudioDevicePropertyDeviceUID) else { return }
        if build(processes: processes, outputUID: outputUID, wants: wants) {
            running = (wants, processes, output)
            Log.media.notice("Audio tap on \(wants.target ?? "", privacy: .public): eq \(wants.equalizer) levels \(wants.levels)")
        } else {
            teardown()
            failedFor = self.wants
        }
        updateAnalysis()
    }

    private func watchPermission() {
        guard permissionWatch == nil else { return }
        permissionWatch = Task { @MainActor [weak self] in
            // Until the switch is turned on (checked every 3 s; a cheap local lookup).
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self, !Task.isCancelled else { return }
                // Waveform and equalizer turned off: nothing to wait for.
                guard self.wants.target != nil, self.wants.equalizer || self.wants.levels else {
                    self.permissionWatch = nil
                    return
                }
                if AudioCapturePermission.status == .granted {
                    Log.media.notice("Audio Recording access granted")
                    self.permissionWatch = nil
                    self.running = nil
                    self.scheduleRebuild(delay: 0)
                    return
                }
            }
            self?.permissionWatch = nil
        }
    }

    private func build(processes: [AudioObjectID], outputUID: String, wants: Wants) -> Bool {
        let description = CATapDescription(stereoMixdownOfProcesses: processes)
        description.name = "Islet"
        description.isPrivate = true
        description.muteBehavior = wants.equalizer ? .mutedWhenTapped : .unmuted
        var tapID = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(description, &tapID) == noErr else {
            Log.media.error("Couldn't create the audio tap (Audio Recording permission?)")
            return false
        }
        tap = tapID
        let settings: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Islet Tap",
            kAudioAggregateDeviceUIDKey: "local.islet.tap.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateAggregateDevice(settings as CFDictionary, &aggregateID) == noErr else {
            Log.media.error("Couldn't create the tap's aggregate device")
            return false
        }
        aggregate = aggregateID
        sampleRate = Self.nominalRate(aggregateID) ?? 48000
        shared.reset(equalizer: wants.equalizer)
        pushCoefficients()

        guard let proc = Self.makeIOProc(on: aggregateID, state: shared) else { return false }
        procID = proc
        guard AudioDeviceStart(aggregateID, proc) == noErr else {
            Log.media.error("Couldn't start the audio tap")
            return false
        }
        return true
    }

    /// Made outside the main actor: the block runs on Core Audio's real-time thread, and a
    /// closure formed in main-actor code would trap there on Swift's isolation check.
    private nonisolated static func makeIOProc(on device: AudioObjectID, state: TapState) -> AudioDeviceIOProcID? {
        var proc: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&proc, device, nil) { _, input, _, output, _ in
            state.process(input: input, output: output)
        }
        return status == noErr ? proc : nil
    }

    private func teardown() {
        if aggregate != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregate, procID)
                AudioDeviceDestroyIOProcID(aggregate, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregate)
        }
        if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap) }
        procID = nil
        aggregate = AudioObjectID(kAudioObjectUnknown)
        tap = AudioObjectID(kAudioObjectUnknown)
        running = nil
    }

    /// Stops everything (app quitting), so the tapped app is heard directly again.
    func stop() {
        rebuildTask?.cancel()
        analysisTimer?.invalidate()
        teardown()
    }

    /// Rebuild when the output changes or the app starts or ends a helper process.
    private func watchSystem() {
        guard listeners.isEmpty else { return }
        for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyProcessObjectList] {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated { self?.scheduleRebuild(delay: 0.4) }
            }
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
            listeners.append((selector, block))
        }
    }

    // MARK: - Equalizer

    private func pushCoefficients() {
        let gains = bands.count == Equalizer.frequencies.count ? bands : Equalizer.flat
        var coefficients: [Float] = []
        for (band, gain) in gains.enumerated() {
            coefficients += Equalizer.coefficients(band: band, gain: gain, sampleRate: sampleRate)
        }
        shared.publish(coefficients: coefficients, preamp: Float(pow(10, preamp / 20)))
    }

    // MARK: - Waveform

    private func updateAnalysis() {
        let analysing = running?.wants.levels == true
        if analysing, analysisTimer == nil {
            analysisTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.analyse() }
            }
        } else if !analysing {
            analysisTimer?.invalidate()
            analysisTimer = nil
            WaveformLevels.shared.clear()
        }
    }

    private let analyser = SpectrumAnalyser()

    /// Debug: the loudest recent sample (0 means the tap hears silence).
    var debugPeak: Float { shared.latestSamples(count: 4096).map(abs).max() ?? 0 }
    var debugInfo: String {
        "callbacks \(shared.callbacks.load(ordering: .relaxed)) shape \(shared.inputShape.load(ordering: .relaxed)) tap \(tap) aggregate \(aggregate) rate \(sampleRate)"
    }

    private func analyse() {
        let samples = shared.latestSamples(count: SpectrumAnalyser.size)
        WaveformLevels.shared.set(analyser.bands(samples, sampleRate: sampleRate))
    }

    // MARK: - Processes

    /// The tap's process objects for an app: the app itself and its helpers (browsers play
    /// web audio from helper processes; Safari's comes from WebKit's GPU process).
    private static func processes(for bundle: String) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        let webKit = ["com.apple.Safari", "com.apple.SafariTechnologyPreview"].contains(bundle)
        return ids.filter { id in
            guard let process = processBundle(id) else { return false }
            return process == bundle || process.hasPrefix(bundle + ".")
                || (webKit && process == "com.apple.WebKit.GPU")
        }
    }

    private static func processBundle(_ id: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private static func nominalRate(_ device: AudioObjectID) -> Double? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate) == noErr && rate > 0 ? rate : nil
    }
}

/// The Audio Recording permission process taps need. A tap made without it hears silence;
/// Core Audio shows the system prompt the first time a tap starts. Islet only reads the
/// answer (through TCC's preflight check), so it knows when the equalizer can take over.
enum AudioCapturePermission {
    enum Status { case granted, denied, unknown }

    private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int
    nonisolated(unsafe) private static let service = "kTCCServiceAudioCapture" as CFString
    nonisolated(unsafe) private static let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    static var status: Status {
        guard let handle, let symbol = dlsym(handle, "TCCAccessPreflight") else { return .unknown }
        return switch unsafeBitCast(symbol, to: Preflight.self)(service, nil) {
        case 0: .granted
        case 1: .denied
        default: .unknown
        }
    }
}

/// State shared with the real-time audio thread. The audio thread never allocates or
/// waits: new filter settings arrive through a sequence lock it only reads, and the analysis
/// samples go into a ring the main thread reads (a torn read only affects one bar frame).
final class TapState: @unchecked Sendable {
    static let bandCount = Equalizer.frequencies.count
    static let ringSize = 4096

    private let sequence = Atomic<Int>(0)
    private let pending = UnsafeMutablePointer<Float>.allocate(capacity: bandCount * 5 + 1)
    private let active = UnsafeMutablePointer<Float>.allocate(capacity: bandCount * 5 + 1)
    private var seen = -1
    /// Filter memory: two values per band per channel (stereo).
    private let memory = UnsafeMutablePointer<Float>.allocate(capacity: bandCount * 2 * 2)
    private let ring = UnsafeMutablePointer<Float>.allocate(capacity: ringSize)
    private let writeIndex = Atomic<Int>(0)
    private let equalizing = Atomic<Bool>(false)

    init() {
        pending.initialize(repeating: 0, count: Self.bandCount * 5 + 1)
        active.initialize(repeating: 0, count: Self.bandCount * 5 + 1)
        memory.initialize(repeating: 0, count: Self.bandCount * 4)
        ring.initialize(repeating: 0, count: Self.ringSize)
    }

    /// Before a tap starts (the audio thread isn't running).
    func reset(equalizer: Bool) {
        memory.update(repeating: 0, count: Self.bandCount * 4)
        equalizing.store(equalizer, ordering: .releasing)
        seen = -1
    }

    /// From the main thread: new coefficients (5 per band) and the preamp gain.
    func publish(coefficients: [Float], preamp: Float) {
        guard coefficients.count == Self.bandCount * 5 else { return }
        sequence.add(1, ordering: .acquiringAndReleasing)          // odd: being written
        for (index, value) in coefficients.enumerated() { pending[index] = value }
        pending[Self.bandCount * 5] = preamp
        sequence.add(1, ordering: .acquiringAndReleasing)          // even: complete
    }

    /// From the main thread: the newest `count` samples, oldest first.
    func latestSamples(count: Int) -> [Float] {
        let end = writeIndex.load(ordering: .acquiring)
        return (0..<count).map { ring[(end - count + $0 + Self.ringSize * 2) % Self.ringSize] }
    }

    // MARK: Real-time thread

    /// Debug counters: callbacks so far, and the last input's buffers and bytes.
    let callbacks = Atomic<Int>(0)
    let inputShape = Atomic<Int>(0)

    func process(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        adoptCoefficients()
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        callbacks.add(1, ordering: .relaxed)
        inputShape.store(inputs.count * 1_000_000 + Int(inputs.first?.mDataByteSize ?? 0) * 10 + Int(inputs.first?.mNumberChannels ?? 0), ordering: .relaxed)
        let outputs = UnsafeMutableAudioBufferListPointer(output)
        let frames = Self.frameCount(inputs)
        let equalize = equalizing.load(ordering: .relaxed)
        var write = writeIndex.load(ordering: .relaxed)
        let preamp = active[Self.bandCount * 5]
        for frame in 0..<frames {
            var left = Self.sample(inputs, frame: frame, channel: 0)
            var right = Self.sample(inputs, frame: frame, channel: 1)
            if equalize {
                left = filter(left * preamp, channel: 0)
                right = filter(right * preamp, channel: 1)
                left = Self.softClip(left)
                right = Self.softClip(right)
            }
            ring[write] = (left + right) * 0.5
            write = (write + 1) % Self.ringSize
            Self.write(outputs, frame: frame, left: equalize ? left : 0, right: equalize ? right : 0)
        }
        writeIndex.store(write, ordering: .releasing)
    }

    private func adoptCoefficients() {
        let before = sequence.load(ordering: .acquiring)
        guard before != seen, before % 2 == 0 else { return }
        active.update(from: pending, count: Self.bandCount * 5 + 1)
        if sequence.load(ordering: .acquiring) == before { seen = before }
    }

    /// The ten bands in series (transposed direct form II).
    private func filter(_ sample: Float, channel: Int) -> Float {
        var x = sample
        for band in 0..<Self.bandCount {
            let c = active + band * 5
            if c[0] == 1, c[1] == 0, c[2] == 0, c[3] == 0, c[4] == 0 { continue }
            let z = memory + (channel * Self.bandCount + band) * 2
            let y = c[0] * x + z[0]
            z[0] = c[1] * x - c[3] * y + z[1]
            z[1] = c[2] * x - c[4] * y
            x = y
        }
        return x
    }

    /// Gentle limiting above 0.9 instead of hard clipping (which crackles).
    private static func softClip(_ x: Float) -> Float {
        let magnitude = abs(x)
        guard magnitude > 0.9 else { return x }
        let over = magnitude - 0.9
        return (0.9 + 0.1 * over / (over + 0.1)) * (x < 0 ? -1 : 1)
    }

    private static func frameCount(_ buffers: UnsafeMutableAudioBufferListPointer) -> Int {
        guard let first = buffers.first, first.mNumberChannels > 0 else { return 0 }
        return Int(first.mDataByteSize) / MemoryLayout<Float>.size / Int(first.mNumberChannels)
    }

    /// One sample of a stream whether it's interleaved (one buffer) or one buffer per channel.
    private static func sample(_ buffers: UnsafeMutableAudioBufferListPointer, frame: Int, channel: Int) -> Float {
        if buffers.count == 1 {
            let buffer = buffers[0]
            let channels = Int(buffer.mNumberChannels)
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self), channels > 0 else { return 0 }
            return data[frame * channels + min(channel, channels - 1)]
        }
        guard !buffers.isEmpty else { return 0 }
        let buffer = buffers[min(channel, buffers.count - 1)]
        guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { return 0 }
        return data[frame]
    }

    /// Stereo into the output device's first two channels; any others are silent.
    private static func write(_ buffers: UnsafeMutableAudioBufferListPointer, frame: Int, left: Float, right: Float) {
        var channelBase = 0
        for buffer in buffers {
            let channels = Int(buffer.mNumberChannels)
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self), channels > 0 else { continue }
            let frames = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / channels
            guard frame < frames else { continue }
            for channel in 0..<channels {
                let absolute = channelBase + channel
                data[frame * channels + channel] = absolute == 0 ? left : absolute == 1 ? right : 0
            }
            channelBase += channels
        }
    }
}

/// Turns the latest samples into a few bar heights (log-spaced bands, in dB).
@MainActor
final class SpectrumAnalyser {
    static let size = 1024
    static let barCount = 4
    private let fft = vDSP.FFT(log2n: vDSP_Length(10), radix: .radix2, ofType: DSPSplitComplex.self)
    private let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: size, isHalfWindow: false)
    private var smoothed = [Float](repeating: 0, count: barCount)

    func bands(_ samples: [Float], sampleRate: Double) -> [Float] {
        guard samples.count == Self.size, let fft else { return smoothed }
        let windowed = vDSP.multiply(samples, window)
        var real = [Float](repeating: 0, count: Self.size / 2)
        var imaginary = [Float](repeating: 0, count: Self.size / 2)
        var magnitudes = [Float](repeating: 0, count: Self.size / 2)
        real.withUnsafeMutableBufferPointer { realPointer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imaginaryPointer.baseAddress!)
                windowed.withUnsafeBufferPointer { input in
                    input.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: Self.size / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(Self.size / 2))
                    }
                }
                fft.forward(input: split, output: &split)
                vDSP.absolute(split, result: &magnitudes)
            }
        }
        // Bands from 60 Hz to 12 kHz, evenly spaced on a log scale.
        let binWidth = sampleRate / Double(Self.size)
        let edges = (0...Self.barCount).map { 60 * pow(12000.0 / 60, Double($0) / Double(Self.barCount)) }
        for bar in 0..<Self.barCount {
            let low = max(1, Int(edges[bar] / binWidth))
            let high = max(low + 1, min(magnitudes.count, Int(edges[bar + 1] / binWidth)))
            let peak = magnitudes[low..<high].max() ?? 0
            let decibels = 20 * log10(max(peak / Float(Self.size / 4), 1e-6))
            let level = min(max((decibels + 50) / 45, 0), 1)
            // Rise at once, fall gently, like a meter.
            smoothed[bar] = level > smoothed[bar] ? level : smoothed[bar] * 0.82 + level * 0.18
        }
        return smoothed
    }
}

/// The bar heights views draw, and who's watching (the tap runs only while someone is).
@MainActor
@Observable
final class WaveformLevels {
    static let shared = WaveformLevels()
    private(set) var levels: [Float] = []
    /// Bars on screen right now; the engine samples audio only while there are some.
    @ObservationIgnored var onViewersChanged: () -> Void = {}
    @ObservationIgnored private(set) var viewers = 0 {
        didSet { if (viewers > 0) != (oldValue > 0) { onViewersChanged() } }
    }

    var isLive: Bool { !levels.isEmpty }
    /// Every new frame of levels, for listeners that need each one (the edge glow's beat).
    @ObservationIgnored var onFrame: (([Float]) -> Void)?

    func set(_ new: [Float]) {
        levels = new
        onFrame?(new)
    }
    func clear() { if !levels.isEmpty { levels = [] } }
    func appeared() { viewers += 1 }
    func disappeared() { viewers = max(0, viewers - 1) }
}

import AudioToolbox
import CoreAudio
import Observation

/// The default output device: name, kind and volume, kept current with CoreAudio listeners.
@MainActor
@Observable
final class AudioOutput {
    static let shared = AudioOutput()

    struct Device: Equatable {
        var id: AudioObjectID
        var name: String
        var modelUID: String
        var transport: UInt32
        var hasVolume: Bool

        var product: AudioProduct? { AudioProduct(modelUID: modelUID, name: name) }

        var isBuiltIn: Bool { transport == kAudioDeviceTransportTypeBuiltIn }

        /// SF Symbol for the device (spec §2.7 recognises many more models from BP10 on).
        var symbolName: String {
            if let product { return product.symbolName }
            let lower = name.lowercased()
            if lower.contains("airpods") { return "airpods" }
            if lower.contains("homepod") { return "homepod.fill" }
            switch transport {
            case kAudioDeviceTransportTypeBuiltIn: return "laptopcomputer"
            case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "headphones"
            case kAudioDeviceTransportTypeAirPlay: return "airplayaudio"
            case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "tv"
            default: return "speaker.wave.2.fill"
            }
        }
    }

    private(set) var device: Device? {
        get { debugDevice ?? realDevice }
        set { realDevice = newValue }
    }
    private var realDevice: Device?
    /// DEBUG: pretend this is the output, to check device-specific UI without the hardware.
    var debugDevice: Device?
    /// 0…1.
    private(set) var volume: Float = 0
    private(set) var isMuted = false

    private var listenedDevice: AudioObjectID?
    private let listenerQueue = DispatchQueue(label: "notcher.audio-output")
    private var isStarted = false

    private init() {}

    func start() {
        guard !isStarted else { return }
        isStarted = true
        Self.addListener(
            to: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDefaultOutputDevice,
            scope: kAudioObjectPropertyScopeGlobal,
            queue: listenerQueue
        ) {
            Task { @MainActor in AudioOutput.shared.refreshDevice() }
        }
        refreshDevice()
    }

    func setVolume(_ value: Float) {
        guard let id = device?.id else { return }
        var scalar = min(max(value, 0), 1)
        var address = Self.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        let status = AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &scalar)
        if status == noErr {
            volume = scalar
            if isMuted, scalar > 0 { setMuted(false) }
        }
    }

    func setMuted(_ muted: Bool) {
        guard let id = device?.id else { return }
        var value: UInt32 = muted ? 1 : 0
        var address = Self.address(kAudioDevicePropertyMute)
        if AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr {
            isMuted = muted
        }
    }

    /// Media-key step: 1/16 of the range, or 1/64 with Option+Shift (as macOS does).
    /// Returns false when the volume is already at the limit in that direction, so the HUD
    /// can rubber-band instead (spec §5.4).
    @discardableResult
    func step(up: Bool, fine: Bool) -> Bool {
        guard device?.hasVolume == true else { return false }
        if up, isMuted {
            setMuted(false)
            if volume > 0 { return true }
        }
        let steps: Float = fine ? 64 : 16
        let current = isMuted ? 0 : volume
        if up ? current >= 1 : current <= 0 { return false }
        let target = min(max(((current * steps).rounded() + (up ? 1 : -1)) / steps, 0), 1)
        setVolume(target)
        if target == 0 { setMuted(true) }
        return true
    }

    func toggleMute() {
        setMuted(!isMuted)
    }

    /// The system "Play feedback when volume is changed" preference.
    var playsFeedback: Bool {
        UserDefaults(suiteName: UserDefaults.globalDomain)?.object(forKey: "com.apple.sound.beep.feedback") as? Int == 1
    }

    // MARK: Reading

    private func refreshDevice() {
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
              id != kAudioObjectUnknown
        else {
            device = nil
            return
        }

        var volumeAddress = Self.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        device = Device(
            id: id,
            name: Self.string(id, kAudioObjectPropertyName) ?? "Output",
            modelUID: Self.string(id, kAudioDevicePropertyModelUID) ?? "",
            transport: Self.uint32(id, kAudioDevicePropertyTransportType, scope: kAudioObjectPropertyScopeGlobal) ?? 0,
            hasVolume: AudioObjectHasProperty(id, &volumeAddress)
        )
        listenForVolume(on: id)
        refreshVolume()
    }

    private func refreshVolume() {
        guard let id = device?.id else { return }
        var scalar: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        var address = Self.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        if AudioObjectGetPropertyData(id, &address, 0, nil, &size, &scalar) == noErr {
            volume = scalar
        }
        isMuted = (Self.uint32(id, kAudioDevicePropertyMute) ?? 0) != 0
    }

    private func listenForVolume(on id: AudioObjectID) {
        guard listenedDevice != id else { return }
        listenedDevice = id
        for selector in [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyMute] {
            Self.addListener(to: id, selector: selector, queue: listenerQueue) {
                Task { @MainActor in AudioOutput.shared.refreshVolume() }
            }
        }
    }

    /// CoreAudio calls listeners on `queue`. A block written inside this main-actor class would
    /// inherit main-actor isolation and trap when called there, so it is built out here.
    private nonisolated static func addListener(
        to id: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioDevicePropertyScopeOutput,
        queue: DispatchQueue,
        handler: @escaping @Sendable () -> Void
    ) {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(id, &address, queue) { _, _ in handler() }
    }

    private static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioDevicePropertyScopeOutput
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func uint32(
        _ id: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioDevicePropertyScopeOutput
    ) -> UInt32? {
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = address(selector, scope: scope)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var address = address(selector, scope: kAudioObjectPropertyScopeGlobal)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}

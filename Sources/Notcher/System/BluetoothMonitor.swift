import AppKit
import IOBluetooth

/// Bluetooth audio devices connecting (spec §2.7, §9.7).
///
/// IOBluetooth connect notifications, filtered to the audio device class. Apple devices report
/// per-bud battery through `IOBluetoothDevice`'s battery properties; they can lag the connection
/// by a moment, so the monitor waits up to 2 s for a reading before announcing the device.
@MainActor
final class BluetoothMonitor: NSObject {
    struct Device: Equatable {
        enum Buds: Equatable { case both, left, right, single }

        var name: String
        var product: AudioProduct?
        var symbolName: String
        /// 0…100, nil when the device doesn't report it.
        var battery: Int?
        var buds: Buds
    }

    var onConnect: ((Device) -> Void)?

    private var connectNotification: IOBluetoothUserNotification?
    private var isStarting = false
    private var startedAt = Date.distantPast

    /// Registers off the main thread: until the user answers the Bluetooth permission prompt,
    /// IOBluetooth blocks the call, and on the main thread that froze the whole island.
    func start() {
        guard connectNotification == nil, !isStarting else { return }
        isStarting = true
        startedAt = .now
        let observer = self
        DispatchQueue.global(qos: .utility).async {
            nonisolated(unsafe) let notification = IOBluetoothDevice.register(
                forConnectNotifications: observer,
                selector: #selector(BluetoothMonitor.deviceDidConnect(_:device:))
            )
            Task { @MainActor in
                observer.connectNotification = notification
                observer.isStarting = false
                // Connections reported for devices already connected at registration aren't news.
                observer.startedAt = .now
            }
        }
    }

    /// IOBluetooth calls this on its own queue; the device is looked up again on the main actor.
    @objc nonisolated private func deviceDidConnect(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        guard device.deviceClassMajor == UInt32(kBluetoothDeviceClassMajorAudio),
              let address = device.addressString
        else { return }
        Task { @MainActor [weak self] in
            self?.audioDeviceDidConnect(address: address)
        }
    }

    private func audioDeviceDidConnect(address: String) {
        // Registering reports every device that is already connected; those aren't news.
        guard Date.now.timeIntervalSince(startedAt) > 2,
              let device = IOBluetoothDevice(addressString: address)
        else { return }
        Task { [weak self] in
            var info = Self.read(device)
            for _ in 0..<10 where info.battery == nil {
                try? await Task.sleep(for: .milliseconds(200))
                info = Self.read(device)
            }
            self?.onConnect?(info)
        }
    }

    static func read(_ device: IOBluetoothDevice) -> Device {
        let name = device.name ?? "Headphones"
        let productID = (device.value(forKey: "productID") as? Int) ?? 0
        let product = AudioProduct(modelUID: String(format: "%04x", productID), name: name)

        func percent(_ key: String) -> Int? {
            guard device.responds(to: NSSelectorFromString(key)),
                  let value = device.value(forKey: key) as? Int, value > 0 else { return nil }
            return value
        }
        let left = percent("batteryPercentLeft")
        let right = percent("batteryPercentRight")
        let single = percent("batteryPercentSingle")

        let buds: Device.Buds
        let battery: Int?
        switch (left, right) {
        case let (l?, r?):
            buds = .both
            battery = min(l, r)
        case let (l?, nil):
            buds = .left
            battery = l
        case let (nil, r?):
            buds = .right
            battery = r
        case (nil, nil):
            buds = .single
            battery = single
        }

        return Device(
            name: name,
            product: product,
            symbolName: product?.symbolName ?? Self.symbol(minorClass: device.deviceClassMinor),
            battery: battery,
            buds: buds
        )
    }

    /// Generic audio devices by Bluetooth minor class (spec §9.7 step 4).
    private static func symbol(minorClass: BluetoothDeviceClassMinor) -> String {
        switch Int(minorClass) {
        case kBluetoothDeviceClassMinorAudioHeadset, kBluetoothDeviceClassMinorAudioHeadphones:
            "headphones"
        case kBluetoothDeviceClassMinorAudioHandsFree:
            "headphones"
        case kBluetoothDeviceClassMinorAudioLoudspeaker, kBluetoothDeviceClassMinorAudioPortable,
             kBluetoothDeviceClassMinorAudioHiFi:
            "hifispeaker.fill"
        case kBluetoothDeviceClassMinorAudioCar:
            "car.fill"
        default:
            "speaker.wave.2.fill"
        }
    }
}

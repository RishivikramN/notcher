import AppKit
import CoreAudio
import IOBluetooth
import Observation

/// Owns one island per target display (spec §9.4: `controllersByDisplayUUID`) and the system
/// monitors that feed them, and keeps both in step with Settings and the display setup.
@MainActor
final class AppState {
    /// Debug override of the detected display mode (nil = automatic).
    var modeOverride: DisplayMode? {
        didSet { refresh() }
    }

    private(set) var windowControllers: [String: NotchWindowController] = [:]
    private var mediaObservers: [String: UUID] = [:]

    let mediaKeys = MediaKeyMonitor()
    private let battery = BatteryMonitor()
    private let fullscreen = FullscreenMonitor()
    private let swipes = NotchSwipeMonitor()
    private let bluetooth = BluetoothMonitor()
    private let settings = Settings.shared
    private lazy var volumeFeedback = NSSound(named: "volume")

    /// Islands in a stable order (main display first).
    var controllers: [NotchController] {
        windowControllers.values
            .sorted { ($0.screen.displayID == CGMainDisplayID() ? 0 : 1) < ($1.screen.displayID == CGMainDisplayID() ? 0 : 1) }
            .map(\.controller)
    }

    func start() {
        refresh()
        observeSettings()

        mediaKeys.onPress = { [weak self] press in self?.handle(press) ?? false }
        mediaKeys.start()

        battery.lowBatteryThreshold = settings.lowBatteryThreshold
        battery.onEvent = { [weak self] event, state in self?.batteryDidChange(event, state) }
        battery.start()

        fullscreen.onChange = { [weak self] _ in self?.applyVisibility() }
        fullscreen.start()

        swipes.controllerUnderPointer = { [weak self] in
            self?.controllers.first { $0.isMouseInside }
        }
        swipes.start()

        bluetooth.onConnect = { [weak self] device in
            guard let self, self.settings.enableConnectivity else { return }
            self.present(.connected(device))
        }
        bluetooth.start()

        #if DEBUG
        // Debug: the Tuning window posts locally; scripts can post the same names distributed.
        // Release builds don't listen, so other processes can't drive the island.
        for center in [NotificationCenter.default, DistributedNotificationCenter.default()] {
            center.addObserver(forName: .debugSimulateSongChange, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.controllers.forEach { $0.showQuickPeek() } }
            }
            // Debug: pretend the output is a device, by Bluetooth product ID ("201B"), "builtin",
            // or "none" to stop pretending.
            center.addObserver(forName: .init("notcher.debug.simulateOutput"), object: nil, queue: .main) { note in
                let product = note.object as? String
                MainActor.assumeIsolated {
                    AudioOutput.shared.debugDevice = product.flatMap { product in
                        switch product {
                        case "none": nil
                        case "builtin": AudioOutput.Device(
                            id: 0, name: "MacBook Pro Speakers", modelUID: "Speaker",
                            transport: kAudioDeviceTransportTypeBuiltIn, hasVolume: true
                        )
                        default: AudioOutput.Device(
                            id: 0, name: "Simulated \(product)", modelUID: "\(product) 4C",
                            transport: kAudioDeviceTransportTypeBluetooth, hasVolume: true
                        )
                        }
                    }
                }
            }
            #if DEBUG
            // Debug: "on" makes media commands dry runs (see MediaManager.debugDryRun).
            center.addObserver(forName: .init("notcher.debug.dryRunMedia"), object: nil, queue: .main) { note in
                let on = note.object as? String == "on"
                MainActor.assumeIsolated { MediaManager.shared.debugDryRun = on }
            }
            #endif
            center.addObserver(forName: .debugSimulateNotification, object: nil, queue: .main) { [weak self] note in
                let kind = (note.object as? String).flatMap(DebugNotification.init(rawValue:))
                MainActor.assumeIsolated { self?.simulate(kind) }
            }
        }
        #endif
    }

    // MARK: Displays

    func refresh() {
        let screens = ScreenGeometry.screens(for: settings.displayChoice)
        let wanted = Set(screens.map(\.displayUUID))

        for (uuid, windowController) in windowControllers where !wanted.contains(uuid) {
            windowController.close()
            windowControllers[uuid] = nil
            if let token = mediaObservers.removeValue(forKey: uuid) {
                MediaManager.shared.removeObserver(token)
            }
        }

        for screen in screens {
            let metrics = ScreenGeometry.metrics(
                for: screen,
                forceSimulatedNotch: settings.forceSimulatedNotch,
                modeOverride: modeOverride,
                widthOffset: settings.notchWidthOffset,
                heightOffset: settings.notchHeightOffset
            )
            let uuid = screen.displayUUID
            if let windowController = windowControllers[uuid] {
                windowController.controller.update(metrics: metrics)
                windowController.move(to: screen)
            } else {
                let controller = NotchController(metrics: metrics)
                mediaObservers[uuid] = MediaManager.shared.addObserver { [weak controller] old, new in
                    controller?.mediaDidChange(old: old, new: new)
                }
                let windowController = NotchWindowController(screen: screen, controller: controller)
                windowController.show()
                windowControllers[uuid] = windowController
            }
        }
        applyVisibility()
    }

    /// Hide islands over fullscreen Spaces when the setting is on.
    private func applyVisibility() {
        for (uuid, windowController) in windowControllers {
            windowController.controller.setHidden(settings.hideInFullscreen && fullscreen.fullscreenDisplays.contains(uuid))
        }
    }

    /// Re-applies display-related settings whenever they change.
    private func observeSettings() {
        withObservationTracking {
            _ = settings.displayChoice
            _ = settings.forceSimulatedNotch
            _ = settings.notchWidthOffset
            _ = settings.notchHeightOffset
            _ = settings.hideInFullscreen
            _ = settings.lowBatteryThreshold
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.battery.lowBatteryThreshold = self.settings.lowBatteryThreshold
                self.refresh()
                self.observeSettings()
            }
        }
    }

    // MARK: Volume HUD (spec §2.5, §9.3)

    /// Returns true when the key was handled and must be swallowed.
    private func handle(_ press: MediaKeyMonitor.Press) -> Bool {
        guard settings.enableVolumeHUD else { return false }
        let output = AudioOutput.shared
        // Outputs without software volume (e.g. some HDMI displays) stay with the system.
        guard output.device?.hasVolume == true else { return false }

        switch press.key {
        case .volumeUp, .volumeDown:
            let moved = output.step(up: press.key == .volumeUp, fine: press.isFine)
            if !moved { controllers.forEach { $0.stretchEdge() } }
            if moved, !press.isRepeat, output.playsFeedback {
                volumeFeedback?.stop()
                volumeFeedback?.play()
            }
        case .mute:
            guard !press.isRepeat else { return true }
            output.toggleMute()
        }
        present(.volume)
        return true
    }

    // MARK: Battery (spec §2.6)

    private func batteryDidChange(_ event: BatteryMonitor.Event, _ state: BatteryMonitor.State) {
        let enabled = switch event {
        case .charging: settings.notifyCharging
        case .lowBattery: settings.warnOnLowBattery
        case .lowPowerMode: settings.notifyLowPowerMode
        }
        if enabled { present(.battery(event, state)) }
    }

    private func present(_ notification: IslandNotification) {
        let duration = switch notification {
        case .volume: settings.hudDuration
        case .battery: settings.batteryDuration
        case .connected: settings.connectivityDuration
        }
        controllers.forEach { $0.present(notification, duration: duration) }
    }

    #if DEBUG
    private func simulate(_ kind: DebugNotification?) {
        let state = BatteryMonitor.read()
            ?? BatteryMonitor.State(percentage: 80, isCharging: false, isPluggedIn: false, isLowPowerMode: false)
        switch kind {
        case .volume: present(.volume)
        case .charging:
            var charging = state
            charging.isPluggedIn = true
            charging.isCharging = true
            present(.battery(.charging, charging))
        case .lowBattery:
            var low = state
            low.percentage = 12
            low.isPluggedIn = false
            present(.battery(.lowBattery, low))
        case .lowPower: present(.battery(.lowPowerMode, state))
        case .connected:
            // The first connected Bluetooth audio device, else a made-up AirPods 4.
            let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
            let device = paired.first { $0.isConnected() && $0.deviceClassMajor == UInt32(kBluetoothDeviceClassMajorAudio) }
                .map(BluetoothMonitor.read)
                ?? BluetoothMonitor.Device(name: "AirPods", product: .airPods4, symbolName: "airpods.gen4", battery: 85, buds: .both)
            present(.connected(device))
        case nil: break
        }
    }
    #endif
}

import AppKit
import CoreGraphics

/// Active event tap on the media keys (spec §9.3). Handled keys are swallowed, which is what
/// keeps the system volume HUD from appearing. Needs Accessibility; until it's granted the
/// monitor retries every two seconds (trust changes post no notification).
@MainActor
final class MediaKeyMonitor {
    enum Key: Equatable {
        case volumeUp, volumeDown, mute
    }

    struct Press {
        var key: Key
        var isRepeat: Bool
        /// Option+Shift: quarter steps.
        var isFine: Bool
    }

    /// Return true to swallow the key.
    var onPress: ((Press) -> Bool)?

    private(set) var isRunning = false
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var retryTask: Task<Void, Never>?
    private var hasPrompted = false

    func start() {
        guard tap == nil else { return }
        if !Accessibility.isTrusted {
            // Prompt once per launch; the retries only check, or the system prompt would
            // reappear every 2 s until the user answers.
            if !hasPrompted {
                hasPrompted = true
                Accessibility.requestIfNeeded()
            }
            scheduleRetry()
            return
        }

        let mask = CGEventMask(1 << 14)   // NX_SYSDEFINED: media keys
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: mediaKeyTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            scheduleRetry()
            return
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        self.source = source
        CGEvent.tapEnable(tap: tap, enable: true)
        isRunning = true
    }

    private func scheduleRetry() {
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled else { return }
            self.retryTask = nil
            self.start()
        }
    }

    /// Returns true to swallow the event.
    fileprivate func shouldSwallow(type: CGEventType, event: CGEvent) -> Bool {
        // The system disables a tap that is slow or interrupted by secure input; turn it back on.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }

        guard let nsEvent = NSEvent(cgEvent: event), nsEvent.type == .systemDefined, nsEvent.subtype.rawValue == 8 else {
            return false
        }
        let data1 = nsEvent.data1
        let code = (data1 & 0xFFFF_0000) >> 16
        let isDown = ((data1 & 0xFF00) >> 8) == 0xA
        let isRepeat = (data1 & 0x1) != 0

        let key: Key
        switch code {
        case 0: key = .volumeUp     // NX_KEYTYPE_SOUND_UP
        case 1: key = .volumeDown   // NX_KEYTYPE_SOUND_DOWN
        case 7: key = .mute         // NX_KEYTYPE_MUTE
        default: return false
        }

        let flags = nsEvent.modifierFlags
        let press = Press(key: key, isRepeat: isRepeat, isFine: flags.contains(.option) && flags.contains(.shift))
        // Key-up is swallowed whenever key-down would be, so the system never sees half a press.
        return isDown ? (onPress?(press) ?? false) : (onPress != nil && wouldHandle(key))
    }

    private func wouldHandle(_ key: Key) -> Bool {
        AudioOutput.shared.device?.hasVolume == true
    }
}

/// Runs on the main run loop, where the tap's source is installed.
private func mediaKeyTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<MediaKeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
    nonisolated(unsafe) let event = event
    let swallow = MainActor.assumeIsolated { monitor.shouldSwallow(type: type, event: event) }
    return swallow ? nil : Unmanaged.passUnretained(event)
}

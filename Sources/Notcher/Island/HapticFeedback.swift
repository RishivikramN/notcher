import AppKit

/// Trackpad haptics.
///
/// `NSHapticFeedbackManager` only plays for the active app, and Notcher never becomes active,
/// so the built-in trackpad's actuator is driven directly. The public API stays as a fallback.
@MainActor
enum HapticFeedback {
    enum Strength: Int, Codable, CaseIterable, Sendable {
        case weak = 3
        case medium = 4
        case strong = 6

        var title: String {
            switch self {
            case .weak: "Weak"
            case .medium: "Medium"
            case .strong: "Strong"
            }
        }
    }

    /// Which engine plays haptics, for the Tuning window.
    static var engineDescription: String {
        TrackpadActuator.shared == nil ? "System (only while Notcher is active)" : "Trackpad actuator"
    }

    static func perform(_ strength: Strength? = nil) {
        let strength = strength ?? Tuning.shared.values.hapticStrength
        if TrackpadActuator.shared?.actuate(strength.rawValue) == true { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
    }
}

/// Private MultitouchSupport actuator. Nil when the framework or a trackpad is unavailable.
@MainActor
private final class TrackpadActuator {
    static let shared = TrackpadActuator()

    private typealias CreateDefaultDevice = @convention(c) () -> Unmanaged<AnyObject>?
    private typealias GetDeviceID = @convention(c) (AnyObject, UnsafeMutablePointer<UInt64>) -> Int32
    private typealias CreateActuator = @convention(c) (UInt64) -> Unmanaged<AnyObject>?
    private typealias OpenActuator = @convention(c) (AnyObject) -> Int32
    private typealias Actuate = @convention(c) (AnyObject, Int32, UInt32, Float, Float) -> Int32

    private let actuator: AnyObject
    private let open: OpenActuator
    private let actuateFunction: Actuate

    private init?() {
        let path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
        guard let handle = dlopen(path, RTLD_NOW),
              let createDefault = dlsym(handle, "MTDeviceCreateDefault"),
              let getID = dlsym(handle, "MTDeviceGetDeviceID"),
              let create = dlsym(handle, "MTActuatorCreateFromDeviceID"),
              let open = dlsym(handle, "MTActuatorOpen"),
              let actuate = dlsym(handle, "MTActuatorActuate")
        else { return nil }

        guard let device = unsafeBitCast(createDefault, to: CreateDefaultDevice.self)()?.takeRetainedValue()
        else { return nil }

        var deviceID: UInt64 = 0
        guard unsafeBitCast(getID, to: GetDeviceID.self)(device, &deviceID) == 0,
              let actuator = unsafeBitCast(create, to: CreateActuator.self)(deviceID)?.takeRetainedValue()
        else { return nil }

        self.actuator = actuator
        self.open = unsafeBitCast(open, to: OpenActuator.self)
        self.actuateFunction = unsafeBitCast(actuate, to: Actuate.self)

        guard self.open(actuator) == 0 else { return nil }
    }

    func actuate(_ actuationID: Int) -> Bool {
        if actuateFunction(actuator, Int32(actuationID), 0, 0, 0) == 0 { return true }
        // The actuator can close across sleep/wake; reopen once and retry.
        guard open(actuator) == 0 else { return false }
        return actuateFunction(actuator, Int32(actuationID), 0, 0, 0) == 0
    }
}

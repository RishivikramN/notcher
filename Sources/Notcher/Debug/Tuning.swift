import Foundation
import Observation
import SwiftUI

/// Live-tunable animation feel (behaviour settings live in `Settings`). Defaults are the spec values; changes persist across launches
/// so tuned values survive rebuilds. Remove once the feel is locked in.
@MainActor
@Observable
final class Tuning {
    static let shared = Tuning()

    struct Values: Codable, Equatable {
        // Hover / press scale, anchored at the top edge (spec §3.3).
        var hoverScaleX = 1.075
        var hoverScaleY = 1.15
        var pressScaleX = 0.96
        var pressScaleY = 0.90

        // spring(response:dampingFraction:) for the elevated / pressed look.
        var scaleResponse = 0.35
        var scaleDampingFraction = 1.0

        /// Shortest time the press squash is held, so tap-to-click is visible.
        var minimumPressDuration = 0.15
        var hapticStrength = HapticFeedback.Strength.weak

        // Expansion (spec §3.5).
        /// Main morph: Spring(duration: 0.45, bounce: 0.4).
        var morphDuration = 0.45
        var morphBounce = 0.4
        /// Content: spring(response: 0.4, dampingFraction: 1).
        var contentResponse = 0.4
        /// Content starts this long after the shape.
        var contentDelay = 0.05
        /// The expanded corner radius switches on this long after the shape starts.
        var cornerRadiusDelay = 0.02

        /// Multiplies every duration and delay, to study the choreography.
        var slowMotion = false

        init() {}

        // Tolerates values saved by older builds that lack newer keys.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Values()
            func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T {
                try c.decodeIfPresent(T.self, forKey: key) ?? fallback
            }
            hoverScaleX = try value(.hoverScaleX, d.hoverScaleX)
            hoverScaleY = try value(.hoverScaleY, d.hoverScaleY)
            pressScaleX = try value(.pressScaleX, d.pressScaleX)
            pressScaleY = try value(.pressScaleY, d.pressScaleY)
            scaleResponse = try value(.scaleResponse, d.scaleResponse)
            scaleDampingFraction = try value(.scaleDampingFraction, d.scaleDampingFraction)
            minimumPressDuration = try value(.minimumPressDuration, d.minimumPressDuration)
            hapticStrength = try value(.hapticStrength, d.hapticStrength)
            morphDuration = try value(.morphDuration, d.morphDuration)
            morphBounce = try value(.morphBounce, d.morphBounce)
            contentResponse = try value(.contentResponse, d.contentResponse)
            contentDelay = try value(.contentDelay, d.contentDelay)
            cornerRadiusDelay = try value(.cornerRadiusDelay, d.cornerRadiusDelay)
            slowMotion = try value(.slowMotion, d.slowMotion)
        }
    }

    private static let defaultsKey = "debug.tuning"

    var values: Values {
        didSet { save() }
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let values = try? JSONDecoder().decode(Values.self, from: data) {
            self.values = values
        } else {
            values = Values()
        }
    }

    /// Time multiplier applied to every animation (5× in slow motion).
    var timeScale: Double { values.slowMotion ? 5 : 1 }

    var scaleAnimation: Animation {
        .spring(response: values.scaleResponse * timeScale, dampingFraction: values.scaleDampingFraction)
    }

    var morphAnimation: Animation {
        .spring(duration: values.morphDuration * timeScale, bounce: values.morphBounce)
    }

    var contentAnimation: Animation {
        .spring(response: values.contentResponse * timeScale, dampingFraction: 1)
    }

    /// Shorter secondary stage used when content leaves (contentResponse × 2/3, spec §3.5).
    var contentRemovalAnimation: Animation {
        .spring(response: values.contentResponse * 2 / 3 * timeScale, dampingFraction: 1)
    }

    /// Live activity / notification presentation: Spring(duration: 0.35, bounce: 0.3).
    var presentAnimation: Animation {
        .spring(duration: 0.35 * timeScale, bounce: 0.3)
    }

    /// Dismissal sucks back into the notch without overshoot: Spring(duration: 0.35, bounce: -0.2).
    var dismissAnimation: Animation {
        .spring(duration: 0.35 * timeScale, bounce: -0.2)
    }

    func scaled(_ seconds: Double) -> Duration {
        .seconds(seconds * timeScale)
    }

    func reset() {
        values = Values()
    }

    /// Human-readable summary to paste back as feedback.
    var summary: String {
        let v = values
        return """
        hover scale: (\(v.hoverScaleX.formatted3), \(v.hoverScaleY.formatted3))
        press scale: (\(v.pressScaleX.formatted3), \(v.pressScaleY.formatted3))
        scale spring: response \(v.scaleResponse.formatted3), dampingFraction \(v.scaleDampingFraction.formatted3)
        minimum press: \(v.minimumPressDuration.formatted3) s
        haptic strength: \(v.hapticStrength.title)
        morph: Spring(duration: \(v.morphDuration.formatted3), bounce: \(v.morphBounce.formatted3))
        content: response \(v.contentResponse.formatted3), delay \(v.contentDelay.formatted3) s
        corner radius delay: \(v.cornerRadiusDelay.formatted3) s
        """
    }

    private func save() {
        if let data = try? JSONEncoder().encode(values) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}

private extension Double {
    var formatted3: String { String(format: "%.3f", self) }
}

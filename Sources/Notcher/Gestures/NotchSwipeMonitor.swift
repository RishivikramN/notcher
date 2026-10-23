import AppKit
import SwiftUI

/// Two-finger trackpad swipes on the island (spec §5.2).
///
/// Global and local scroll monitors feed one handler. A gesture belongs to the island the pointer
/// was over when it began and locks to one axis once it has moved a few points:
///
/// - horizontal: skip to the next (fingers right) or previous (left) track
/// - vertical, collapsed: pull down to open, swipe up to dismiss the live activity
/// - vertical, expanded: swipe up to close
///
/// Momentum events and wheel mice are ignored.
@MainActor
final class NotchSwipeMonitor {
    /// The island under the pointer, if any.
    var controllerUnderPointer: () -> NotchController? = { nil }

    private var monitors: [Any] = []
    private weak var controller: NotchController?
    private let settings = Settings.shared
    private let tuning = Tuning.shared

    private enum Phase {
        /// Waiting for enough movement to pick an axis.
        case undecided
        case horizontal
        case vertical(NotchController.VerticalSwipe)
        /// No action applies, or one already fired; the rest of the gesture is ignored.
        case ignored
    }

    private var phase = Phase.ignored
    private var travel = CGVector.zero
    private var scroll: CGFloat = 0
    private var hasPassedHorizontalThreshold = false

    // Spec §5.2: success / reset thresholds as normalized progress.
    private let horizontalSuccess: CGFloat = 0.9
    private let horizontalReset: CGFloat = 0.8
    private let verticalSuccess: CGFloat = 0.9

    /// Each raw scroll event is smoothed through a 0.5 s critically damped spring.
    private let trackingAnimation = Animation.spring(response: 0.5, dampingFraction: 1)

    func start() {
        guard monitors.isEmpty else { return }
        let local = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }
        let global = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        monitors = [local, global].compactMap { $0 }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }

    private func handle(_ event: NSEvent) {
        guard event.hasPreciseScrollingDeltas, event.momentumPhase.isEmpty else { return }

        if event.phase.contains(.began) {
            begin()
        } else if event.phase.contains(.changed) {
            update(with: event)
        } else if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            end()
        }
    }

    private func begin() {
        if controller != nil { end() }
        guard let candidate = controllerUnderPointer(), !candidate.isHidden else {
            phase = .ignored
            return
        }
        controller = candidate
        phase = .undecided
        travel = .zero
        scroll = 0
        hasPassedHorizontalThreshold = false
    }

    private func update(with event: NSEvent) {
        guard let controller else { return }

        // Finger movement: right and down are positive. With "natural movement" off the island
        // follows the system scroll direction, which is the reverse when natural scrolling is off.
        let followsFingers = settings.naturalMovement && !event.isDirectionInvertedFromDevice
        let sign: CGFloat = followsFingers ? -1 : 1
        let dx = event.scrollingDeltaX * sign
        let dy = event.scrollingDeltaY * sign

        switch phase {
        case .undecided:
            travel.dx += dx
            travel.dy += dy
            guard abs(travel.dx) + abs(travel.dy) >= 4 else { return }
            phase = abs(travel.dx) > abs(travel.dy)
                ? horizontalPhase(for: controller)
                : verticalPhase(for: controller, down: travel.dy > 0)
            switch phase {
            case .horizontal: updateHorizontal(travel.dx, controller)
            case .vertical(let direction): updateVertical(travel.dy, direction, controller)
            default: break
            }
        case .horizontal:
            updateHorizontal(dx, controller)
        case .vertical(let direction):
            updateVertical(dy, direction, controller)
        case .ignored:
            break
        }
    }

    private func end() {
        guard let controller else { return }
        switch phase {
        case .horizontal:
            // Past the threshold the island bounces back; short of it, it settles without overshoot.
            let animation = hasPassedHorizontalThreshold
                ? Animation.spring(duration: 0.45, bounce: 0.4)
                : Animation.spring(response: 0.25, dampingFraction: 1)
            controller.setHorizontalGesture(scroll: 0, progress: 0, animation: animation)
        case .vertical(let direction):
            controller.setVerticalGesture(direction, scroll: 0, progress: 0,
                                          animation: .spring(response: 0.25, dampingFraction: 1))
        default:
            break
        }
        phase = .ignored
        self.controller = nil
    }

    // MARK: Which action a swipe would perform

    private func horizontalPhase(for controller: NotchController) -> Phase {
        guard settings.swipeToSkip, controller.notification == nil,
              MediaManager.shared.nowPlaying?.acceptsCommands == true,
              controller.isExpanded || controller.showsCompactContent
        else { return .ignored }
        return .horizontal
    }

    private func verticalPhase(for controller: NotchController, down: Bool) -> Phase {
        if controller.isExpanded {
            return !down && settings.swipeToToggle && !controller.isExpanding ? .vertical(.up) : .ignored
        }
        if down {
            return settings.swipeToToggle ? .vertical(.down) : .ignored
        }
        return settings.swipeToDismiss && controller.canDismissActivity ? .vertical(.up) : .ignored
    }

    // MARK: Rubber-band tracking (spec §5.2)

    private func updateHorizontal(_ delta: CGFloat, _ controller: NotchController) {
        let distance: CGFloat = controller.isExpanded ? 16 : 30
        let p = min(abs(scroll) / distance, 1)
        // Resistance grows towards the limit; moving back is free.
        let towardLimit = scroll == 0 || (delta > 0) == (scroll > 0)
        scroll += (towardLimit ? delta * (1 - p) : delta) * 0.9
        scroll = min(max(scroll, -distance), distance)
        let progress = min(abs(scroll) / distance, 1)
        controller.setHorizontalGesture(scroll: scroll, progress: progress, animation: trackingAnimation)

        if progress >= horizontalSuccess, !hasPassedHorizontalThreshold {
            hasPassedHorizontalThreshold = true
            if settings.hapticFeedback { HapticFeedback.perform() }
            controller.skip(forward: scroll > 0)
        } else if progress < horizontalReset, hasPassedHorizontalThreshold {
            hasPassedHorizontalThreshold = false
        }
    }

    private func updateVertical(_ delta: CGFloat, _ direction: NotchController.VerticalSwipe, _ controller: NotchController) {
        let distance: CGFloat = controller.isExpanded ? 30 : 12
        let p = min(scroll / distance, 1)
        let along = direction == .down ? delta : -delta
        // Stiffer than horizontal, and one-directional.
        scroll += along * (1 - p) * 0.75
        scroll = min(max(scroll, 0), distance)
        let progress = min(scroll / distance, 1)
        controller.setVerticalGesture(direction, scroll: scroll, progress: progress, animation: trackingAnimation)

        guard progress >= verticalSuccess else { return }
        if settings.hapticFeedback { HapticFeedback.perform() }
        phase = .ignored
        switch (direction, controller.isExpanded) {
        case (.down, false):
            controller.setVerticalGesture(direction, scroll: 0, progress: 0, animation: tuning.morphAnimation)
            controller.expand()
        case (.up, true):
            controller.setVerticalGesture(direction, scroll: 0, progress: 0, animation: tuning.morphAnimation)
            controller.collapse()
        case (.up, false):
            controller.setVerticalGesture(direction, scroll: 0, progress: 0, animation: tuning.dismissAnimation)
            controller.dismissActivityBySwipe()
        case (.down, true):
            break
        }
    }
}

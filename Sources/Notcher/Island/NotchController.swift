import AppKit
import Observation
import SwiftUI

/// A notification that briefly takes over the sides of the notch (spec §2.4).
enum IslandNotification: Equatable {
    case volume
    case battery(BatteryMonitor.Event, BatteryMonitor.State)
    case connected(BluetoothMonitor.Device)

    /// Extra width beside the notch (spec §2.4): HUDs 184 pt, battery 168 pt, a connected device
    /// 74 pt, all −12 for the pill.
    func width(for mode: DisplayMode) -> CGFloat {
        let base: CGFloat = switch self {
        case .volume: 184
        case .battery: 168
        case .connected: 74
        }
        return mode == .pill ? base - 12 : base
    }

    func isSameKind(as other: IslandNotification?) -> Bool {
        switch (self, other) {
        case (.volume, .volume): true
        case let (.battery(a, _), .battery(b, _)): a == b
        case (.connected, .connected): true
        default: false
        }
    }
}

/// Observable state for one island. The view layer reads it; the controller mutates it
/// inside `withAnimation` (spec §1.4).
///
/// Every delayed transition captures `expandedTransitionGeneration` and checks it after each
/// `await`, so a newer transition silently invalidates older stages.
@MainActor
@Observable
final class NotchController {
    private(set) var metrics: NotchMetrics

    // Presence (spec §1.4).
    private(set) var isMouseInside = false
    /// Hovered: the island grows out of the notch.
    private(set) var isElevated = false
    private(set) var isPressed = false
    private var pressStartedAt: Date?
    private var pressReleaseTask: Task<Void, Never>?

    // Expansion (spec §1.4, §3.5).
    private(set) var isExpanded = false
    private(set) var isExpanding = false
    private(set) var isCollapsing = false
    private(set) var usesExpandedCornerRadius = false
    private var expandedTransitionGeneration = 0
    private var hoverDebounce: Task<Void, Never>?
    private var expandedCornerRadiusTask: Task<Void, Never>?
    private var expandedTransitionTask: Task<Void, Never>?

    /// Hidden (e.g. over a fullscreen app): the island shrinks 48 pt into the camera housing
    /// (spec §2.4) and ignores hover. Notifications still appear.
    private(set) var isHidden = false

    func setHidden(_ hidden: Bool) {
        guard hidden != isHidden else { return }
        if hidden { collapse() }
        withAnimation(hidden ? tuning.dismissAnimation : tuning.presentAnimation) {
            isHidden = hidden
        }
    }

    // Activities (spec §1.4).
    /// Compact content beside the notch (now playing).
    private(set) var hasLiveActivity = false
    /// Brief peek at a new track below the notch.
    private(set) var isQuickPeeking = false
    private var quickPeekGeneration = 0
    private var quickPeekDebounce: Task<Void, Never>?
    private var idleTask: Task<Void, Never>?

    // Notifications (spec §1.4).
    private(set) var notification: IslandNotification?
    /// Rubber-band width while a media key is pressed past 0 % / 100 % (spec §5.4).
    private(set) var edgeStretch: CGFloat = 0
    private var notificationCloseGeneration = 0
    private var notificationCloseTask: Task<Void, Never>?
    private var edgeStretchGeneration = 0

    // Gestures (spec §5.2). Scrolls are rubber-banded points; progress is 0…1 of the travel.
    enum VerticalSwipe { case down, up }
    private(set) var gestureHorizontalScroll: CGFloat = 0
    private(set) var gestureHorizontalProgress: CGFloat = 0
    private(set) var gestureVerticalScroll: CGFloat = 0
    private(set) var gestureVerticalProgress: CGFloat = 0
    private(set) var gestureVerticalDirection: VerticalSwipe = .down
    /// The track whose live activity was swiped away. It stays away until the track changes or
    /// playback starts again.
    private var dismissedTrack: NowPlaying?
    /// Bumped on every skip (swipe or button) to play the skip button's arrow animation.
    private(set) var nextTrackSkips = 0
    private(set) var previousTrackSkips = 0

    private let tuning = Tuning.shared
    private let settings = Settings.shared

    init(metrics: NotchMetrics) {
        self.metrics = metrics
    }

    // MARK: Geometry

    var displayMode: DisplayMode { metrics.mode }
    var notchWidth: CGFloat { metrics.notchWidth }
    var notchHeight: CGFloat { metrics.notchHeight }
    var notchExpandedWidth: CGFloat { metrics.expandedWidth }
    var notchExpandedHeight: CGFloat { metrics.expandedHeight }

    var shapeStyle: NotchShape.Style {
        // The pill takes the notch outline once it grows downward, so it can hang from the top edge.
        displayMode == .pill && !isExpanded && !isQuickPeeking ? .pill : .notch
    }

    /// Extra width for content beside the notch (spec §2.4): 74 pt, 62 pt for the pill.
    var sideContentWidth: CGFloat { displayMode == .pill ? 62 : 74 }

    /// Extra height of the quick-peek row below the notch (spec §2.4).
    let quickPeekHeight: CGFloat = 32

    /// Body size of the island right now (without the ears).
    var currentWidth: CGFloat {
        restingWidth + gestureWidth
    }

    private var restingWidth: CGFloat {
        if isExpanded { return notchExpandedWidth }
        if let notification { return notchWidth + notification.width(for: displayMode) + edgeStretch }
        if isHidden { return max(notchWidth - 48, 0) }
        return notchWidth + (hasLiveActivity || isQuickPeeking ? sideContentWidth : 0)
    }

    /// Width added by a swipe in progress (spec §2.4): pulling down widens the island, swiping a
    /// live activity up narrows it, and a horizontal swipe stretches it (× 0.9 for the pill).
    /// The open player keeps its size while skipping, as in Alcove; its skip button moves instead.
    private var gestureWidth: CGFloat {
        var width = isExpanded ? 0 : abs(gestureHorizontalScroll) * (displayMode == .pill ? 0.9 : 1)
        switch gestureVerticalDirection {
        case .down: width += gestureVerticalScroll
        case .up where isDismissingActivity: width -= gestureVerticalScroll
        case .up: break
        }
        return width
    }

    /// A collapsed live activity (or peek) is being swiped up and away.
    var isDismissingActivity: Bool {
        !isExpanded && gestureVerticalDirection == .up && gestureVerticalScroll > 0
    }

    /// The output-device button reveals an extra 32 pt volume row (spec §2.4: `hasOutput`).
    /// As in Alcove it's a toggle, closed again when the island collapses.
    private(set) var isShowingVolumeRow = false

    var showsOutputRow: Bool {
        isShowingVolumeRow && MediaManager.shared.nowPlaying != nil && AudioOutput.shared.device?.hasVolume == true
    }

    func toggleVolumeRow() {
        withAnimation(tuning.morphAnimation) {
            isShowingVolumeRow.toggle()
        }
    }

    /// Height of the expanded content, including the output row when shown.
    var expandedContentHeight: CGFloat {
        notchExpandedHeight + (showsOutputRow ? 32 : 0)
    }

    var currentHeight: CGFloat {
        let up = gestureVerticalDirection == .up ? gestureVerticalScroll : 0
        let down = gestureVerticalDirection == .down ? gestureVerticalScroll : 0
        // Swiping the open island up pulls its bottom edge along (not in the spec, which only
        // lists the collapsed cases; without it the collapse swipe has no feedback).
        if isExpanded { return expandedContentHeight - up * 0.75 }
        var height = notchHeight + down * (displayMode == .pill ? 0.65 : 0.75)
        if isQuickPeeking && notification == nil {
            // The peek row shrinks while it's swiped away.
            height += quickPeekHeight * (1 - 0.35 * (gestureVerticalDirection == .up ? gestureVerticalProgress : 0))
        }
        return height
    }

    /// Compact artwork / waveform are visible beside the notch. A notification replaces them
    /// while it's on screen.
    var showsCompactContent: Bool {
        !isExpanded && !isHidden && notification == nil && (hasLiveActivity || isQuickPeeking)
    }

    var showsNotification: Bool { !isExpanded && notification != nil }

    // Radii by state (spec §9.2).
    var topCornerRadius: CGFloat {
        if usesExpandedCornerRadius { return 17 }
        return (isQuickPeeking ? 8 : 5) + (isDismissingActivity ? 2 * gestureVerticalProgress : 0)
    }

    var bottomCornerRadius: CGFloat {
        if usesExpandedCornerRadius { return 34 }
        return (isQuickPeeking ? 19.5 : 10) + (isDismissingActivity ? 3 * gestureVerticalProgress : 0)
    }

    /// Width of each concave ear beside the body (0 for the pill).
    var earWidth: CGFloat {
        guard shapeStyle == .notch else { return 0 }
        return NotchShape.earWidth(
            topCornerRadius: topCornerRadius,
            bottomCornerRadius: bottomCornerRadius,
            height: currentHeight
        )
    }

    /// The pill sits centred in the menu bar instead of hanging from the top edge.
    var topInset: CGFloat { shapeStyle == .pill ? 2.75 : 0 }

    /// Largest island the window must fit: expanded body, widest ears, and room for the
    /// morph spring's overshoot.
    var windowEnvelope: CGSize {
        let overshoot: CGFloat = 24
        return CGSize(
            width: notchExpandedWidth + 2 * 24 + 2 * overshoot,
            height: notchExpandedHeight + 32 + overshoot
        )
    }

    func update(metrics: NotchMetrics) {
        guard metrics != self.metrics else { return }
        self.metrics = metrics
    }

    /// Scale applied to the island, anchored at the top edge (spec §3.3).
    var scale: CGSize {
        guard !isExpanded, !isQuickPeeking else { return CGSize(width: 1, height: 1) }
        let v = tuning.values
        if isPressed { return CGSize(width: v.pressScaleX, height: v.pressScaleY) }
        if isElevated { return CGSize(width: v.hoverScaleX, height: v.hoverScaleY) }
        return CGSize(width: 1, height: 1)
    }

    // MARK: Hover (spec §9.1)

    func setMouseInside(_ inside: Bool) {
        guard inside != isMouseInside else { return }
        guard !isHidden || !inside else { return }
        isMouseInside = inside
        hoverDebounce?.cancel()
        hoverDebounce = nil

        if inside {
            if settings.hapticFeedback {
                HapticFeedback.perform()
            }
            withAnimation(tuning.scaleAnimation) {
                isElevated = true
            }
            guard settings.expandOnHover, !isExpanded else { return }
            let delay = settings.hoverDuration
            hoverDebounce = Task { [weak self] in
                if delay > 0 {
                    try? await Task.sleep(for: .seconds(delay))
                }
                guard let self, !Task.isCancelled, self.isMouseInside else { return }
                self.expand()
            }
        } else {
            withAnimation(tuning.scaleAnimation) {
                isElevated = false
            }
            // Leaving an expanded island collapses it immediately, with no debounce.
            collapse()
        }
    }

    // MARK: Press and tap

    func setPressed(_ pressed: Bool) {
        if pressed {
            pressReleaseTask?.cancel()
            pressReleaseTask = nil
            guard !isPressed else { return }
            pressStartedAt = .now
            HapticFeedback.perform()
            withAnimation(tuning.scaleAnimation) {
                isPressed = true
            }
        } else {
            guard isPressed, pressReleaseTask == nil else { return }
            // A tap-to-click releases within milliseconds; hold the squash long enough to be seen.
            let held = Date.now.timeIntervalSince(pressStartedAt ?? .now)
            let remaining = tuning.values.minimumPressDuration - held
            guard remaining > 0 else {
                releasePress()
                return
            }
            pressReleaseTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(remaining))
                guard !Task.isCancelled else { return }
                self?.releasePress()
            }
        }
    }

    private func releasePress() {
        pressReleaseTask = nil
        withAnimation(tuning.scaleAnimation) {
            isPressed = false
        }
    }

    /// Click / tap toggles the expanded view.
    func handleTap() {
        hoverDebounce?.cancel()
        hoverDebounce = nil
        // A click that lands while hover is still opening the island means "open", not "toggle".
        guard !isExpanding else { return }
        // With expand-on-hover, the open panel is closed by leaving it; a click between the
        // controls shouldn't close it.
        if isExpanded, settings.expandOnHover { return }
        if isExpanded {
            collapse()
        } else {
            expand()
        }
    }

    // MARK: Expand / collapse (spec §3.5)

    func expand() {
        guard !isExpanded else { return }
        expandedTransitionGeneration += 1
        let generation = expandedTransitionGeneration
        cancelTransitionTasks()

        isCollapsing = false
        isExpanding = true
        cancelQuickPeekTask()
        withAnimation(tuning.morphAnimation) {
            isExpanded = true
            isPressed = false
            isQuickPeeking = false
        }

        // +20 ms: switch to the expanded corner radius once the shape has started growing.
        let cornerDelay = tuning.scaled(tuning.values.cornerRadiusDelay)
        expandedCornerRadiusTask = Task { [weak self] in
            try? await Task.sleep(for: cornerDelay)
            guard let self, !Task.isCancelled, generation == self.expandedTransitionGeneration else { return }
            withAnimation(self.tuning.morphAnimation) {
                self.usesExpandedCornerRadius = true
            }
            self.expandedCornerRadiusTask = nil
        }

        // +0.5 s (morph duration + 50 ms of slack): the expansion has settled.
        let settleDelay = tuning.scaled(tuning.values.morphDuration + 0.05)
        expandedTransitionTask = Task { [weak self] in
            try? await Task.sleep(for: settleDelay)
            guard let self, !Task.isCancelled, generation == self.expandedTransitionGeneration else { return }
            self.isExpanding = false
            self.expandedTransitionTask = nil
        }
    }

    func collapse() {
        guard isExpanded else { return }
        expandedTransitionGeneration += 1
        let generation = expandedTransitionGeneration
        cancelTransitionTasks()

        isExpanding = false
        isCollapsing = true
        // The corner radius returns together with the shape. Resetting it only after the
        // spring settles (as the shipped app appears to) would snap the clamped radii at the end.
        withAnimation(tuning.morphAnimation, completionCriteria: .logicallyComplete) {
            isExpanded = false
            usesExpandedCornerRadius = false
            isShowingVolumeRow = false
        } completion: { [weak self] in
            guard let self, generation == self.expandedTransitionGeneration else { return }
            self.isCollapsing = false
        }
    }

    // MARK: Live activity (spec §2.2, §3.4)

    func mediaDidChange(old: NowPlaying?, new: NowPlaying?) {
        idleTask?.cancel()
        idleTask = nil

        guard let new else {
            dismissLiveActivity()
            return
        }

        if new.isPlaying {
            // A swiped-away activity stays away while the same track keeps playing.
            if let dismissedTrack, new.isSameTrack(as: dismissedTrack), old?.isPlaying == true {
                return
            }
            dismissedTrack = nil
            presentLiveActivity()
            if settings.quickPeek, let old, !new.isSameTrack(as: old) {
                showQuickPeek()
            }
        } else if hasLiveActivity {
            // A paused track lingers beside the notch, then the island returns to idle.
            let delay = tuning.scaled(settings.idleDuration)
            idleTask = Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard let self, !Task.isCancelled else { return }
                self.dismissLiveActivity()
            }
        }
    }

    private func presentLiveActivity() {
        guard !hasLiveActivity else { return }
        withAnimation(tuning.presentAnimation) {
            hasLiveActivity = true
        }
    }

    private func dismissLiveActivity() {
        guard hasLiveActivity || isQuickPeeking else { return }
        cancelQuickPeekTask()
        withAnimation(tuning.dismissAnimation) {
            hasLiveActivity = false
            isQuickPeeking = false
        }
    }

    // MARK: Notifications (spec §2.5, §2.6)

    /// Shows `notification` beside the notch for `duration` seconds. Repeating the same kind
    /// (e.g. holding a volume key) only extends it.
    func present(_ notification: IslandNotification, duration: TimeInterval) {
        notificationCloseTask?.cancel()
        notificationCloseGeneration += 1
        let generation = notificationCloseGeneration

        if notification.isSameKind(as: self.notification) {
            self.notification = notification
        } else {
            withAnimation(tuning.presentAnimation) {
                self.notification = notification
            }
        }

        let delay = tuning.scaled(duration)
        notificationCloseTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled, generation == self.notificationCloseGeneration else { return }
            withAnimation(self.tuning.dismissAnimation) {
                self.notification = nil
                self.edgeStretch = 0
            }
            self.notificationCloseTask = nil
        }
    }

    /// Media key pressed at the limit: stretch the HUD, then spring back with
    /// Spring(0.45, bounce 0.4) (spec §5.4).
    func stretchEdge() {
        edgeStretchGeneration += 1
        let generation = edgeStretchGeneration
        withAnimation(.spring(response: 0.15, dampingFraction: 1)) {
            edgeStretch = min(edgeStretch + 8, 14)
        }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard let self, generation == self.edgeStretchGeneration else { return }
            withAnimation(.spring(duration: 0.45, bounce: 0.4)) {
                self.edgeStretch = 0
            }
        }
    }

    // MARK: Gestures (spec §5.2)

    func setHorizontalGesture(scroll: CGFloat, progress: CGFloat, animation: Animation) {
        withAnimation(animation) {
            gestureHorizontalScroll = scroll
            gestureHorizontalProgress = progress
        }
    }

    func setVerticalGesture(_ direction: VerticalSwipe, scroll: CGFloat, progress: CGFloat, animation: Animation) {
        withAnimation(animation) {
            gestureVerticalDirection = direction
            gestureVerticalScroll = scroll
            gestureVerticalProgress = progress
        }
    }

    /// Signed skip-swipe progress for the player's controls: positive towards next.
    var skipSwipeProgress: CGFloat {
        gestureHorizontalScroll < 0 ? -gestureHorizontalProgress : gestureHorizontalProgress
    }

    /// Skips a track and plays the matching button animation.
    func skip(forward: Bool) {
        if forward { nextTrackSkips += 1 } else { previousTrackSkips += 1 }
        MediaManager.shared.perform(forward ? .nextTrack : .previousTrack)
    }

    /// Swipe to dismiss: hides the live activity (and any peek) until something new plays.
    func dismissActivityBySwipe() {
        dismissedTrack = MediaManager.shared.nowPlaying
        idleTask?.cancel()
        idleTask = nil
        dismissLiveActivity()
    }

    var canDismissActivity: Bool {
        !isExpanded && !isHidden && notification == nil && (hasLiveActivity || isQuickPeeking)
    }

    /// Peeks the current track below the notch for `peekDuration` (spec §2.4, default 2 s).
    func showQuickPeek() {
        guard !isExpanded, MediaManager.shared.nowPlaying != nil else { return }
        cancelQuickPeekTask()
        let generation = quickPeekGeneration
        withAnimation(tuning.presentAnimation) {
            isQuickPeeking = true
        }
        let duration = tuning.scaled(settings.peekDuration)
        quickPeekDebounce = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard let self, !Task.isCancelled, generation == self.quickPeekGeneration else { return }
            withAnimation(self.tuning.dismissAnimation) {
                self.isQuickPeeking = false
            }
            self.quickPeekDebounce = nil
        }
    }

    /// Cancel the peek's debounce and invalidate any stage still in flight (spec §1.4).
    private func cancelQuickPeekTask() {
        quickPeekDebounce?.cancel()
        quickPeekDebounce = nil
        quickPeekGeneration += 1
    }

    private func cancelTransitionTasks() {
        expandedCornerRadiusTask?.cancel()
        expandedCornerRadiusTask = nil
        expandedTransitionTask?.cancel()
        expandedTransitionTask = nil
    }
}

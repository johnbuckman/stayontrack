import Foundation
import CoreLocation

/// Decides when a hike has been standing still long enough to auto-pause.
///
/// It lives apart from `HikeSession` for one reason: the decision has to be
/// testable without an audio engine, a route or a GPS. The bug this replaced
/// was that auto-pause was evaluated **only when a location fix arrived** — and
/// `CLLocationManager` with a `distanceFilter` delivers no fixes at all while
/// the phone lies still on a rock. So standing still, the one situation it
/// exists for, was the one situation it never ran in: the clock kept counting
/// for half an hour, and nudging the phone produced a fix that saw "stationary
/// for 30 minutes" and paused instantly.
///
/// Hence the split: `noteFix` maintains the anchor from GPS, but `shouldPause`
/// is a question about the CLOCK that can be asked at any moment, fix or no fix.
struct StationaryMonitor {
    /// Movement within this of the anchor still counts as standing still.
    let radius: CLLocationDistance
    /// How long we must stay inside `radius` before pausing.
    let after: TimeInterval

    private var anchor: CLLocationCoordinate2D?
    private var anchoredAt: Date?

    init(radius: CLLocationDistance, after: TimeInterval) {
        self.radius = radius
        self.after = after
    }

    /// Forget any stationary streak — on start, resume, or a manual pause.
    mutating func reset() {
        anchor = nil
        anchoredAt = nil
    }

    /// Feed a position. Moving clear of the anchor re-anchors here and restarts
    /// the clock; staying inside the radius leaves the clock running.
    mutating func noteFix(_ coordinate: CLLocationCoordinate2D, at time: Date) {
        guard let anchor, let anchoredAt else {
            self.anchor = coordinate
            self.anchoredAt = time
            return
        }
        let moved = CLLocation(from: anchor).distance(from: CLLocation(from: coordinate))
        if moved > radius {
            self.anchor = coordinate
            self.anchoredAt = time
        } else {
            // Staying put: keep the original anchor time, that IS the streak.
            _ = anchoredAt
        }
    }

    /// Have we been stationary long enough to pause?
    ///
    /// Safe to ask from a timer with no new fixes — that is the whole point.
    /// Note the consequence: losing GPS entirely for `after` while genuinely
    /// walking also reads as stationary. That is the right trade: a spurious
    /// pause un-pauses itself on the next fix showing real movement, whereas a
    /// missed pause silently books a long rest as hiking time.
    func shouldPause(now: Date) -> Bool {
        guard let anchoredAt else { return false }
        return now.timeIntervalSince(anchoredAt) >= after
    }

    /// How long we have been stationary, for display/diagnostics.
    func stationaryDuration(now: Date) -> TimeInterval? {
        anchoredAt.map { now.timeIntervalSince($0) }
    }
}

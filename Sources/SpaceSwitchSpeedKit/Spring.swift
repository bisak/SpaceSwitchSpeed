// Space Switch Speed — speed control for the macOS Space-switch animation.
// Copyright (C) 2026 Biser Atanasov. Licensed under AGPL-3.0-or-later.
// See LICENSE. This program comes with ABSOLUTELY NO WARRANTY.

import Foundation

/// The Space-switch animation is a leaky integrator that Dock steps once per
/// display frame, not a timed curve. Per iteration:
///
///     v   = gain * (target - position) + retention * v
///     pos = pos + dt * v
///
/// It ends when the spring settles, which is why macOS ships no duration
/// preference for it and why no `defaults write` key can change its speed.
///
public struct SpringModel: Sendable {
    /// Dock's shipped coefficients, read from `__TEXT,__const`.
    public static let stockRetention = 0.695
    public static let stockGain = 2.0

    /// Rubber-band constants applied when the position leaves [0, 1].
    public static let bandVelocityDamping = 0.85
    public static let bandStiffness = 0.8

    /// `|velocity|` below which Dock considers the animation finished.
    public static let settleEpsilon = 0.01

    /// Frame interval the gain is solved at.
    ///
    /// The coefficients depend on it only weakly — the retention not at all, and
    /// the gain by half a percent at Balanced and four and a half at Instant,
    /// measured across 60, 120 and 144 Hz — because `v = gain * error +
    /// retention * v` carries no timestep and so fixes the dynamics per frame
    /// rather than per second. It is therefore not detected.
    public static let referenceRefresh = 120.0

    /// Frame interval in seconds.
    public let dt: Double

    public init(dt: Double = 1 / SpringModel.referenceRefresh) {
        precondition(dt > 0, "frame interval must be positive")
        self.dt = dt
    }

    // MARK: - The single knob

    /// Coefficients for a speed setting.
    ///
    /// The loop's poles are the roots of `z² - (1 + a - dt·g)z + a`, real on a
    /// fast display and complex on a slow one. Running the animation `1/speed`
    /// times faster raises each pole to that power, which keeps the shape of the
    /// motion exactly as Apple's constants set it; speed 1.0 reproduces them.
    public func coefficients(speed: Double) -> (gain: Double, retention: Double) {
        let power = 1 / speed.clamped(to: Speed.range)
        let a = Self.stockRetention
        let trace = 1 + a - dt * Self.stockGain
        let discriminant = trace * trace - 4 * a

        let retention = Foundation.pow(a, power)
        let scaledTrace: Double
        if discriminant >= 0 {
            let root = discriminant.squareRoot()
            scaledTrace =
                Foundation.pow((trace + root) / 2, power) + Foundation.pow((trace - root) / 2, power)
        } else {
            let angle = Foundation.acos(trace / (2 * a.squareRoot()))
            scaledTrace = 2 * Foundation.pow(a, power / 2) * Foundation.cos(angle * power)
        }
        return ((1 + retention - scaledTrace) / dt, retention)
    }

    /// The speed setting a retention value came from; the inverse of `coefficients(speed:)`.
    public static func speed(retention: Double) -> Double {
        Foundation.log(stockRetention) / Foundation.log(retention)
    }

    // MARK: - Prediction

    public struct Response: Sendable {
        /// Seconds until the animation is within 10% of its target.
        public let arrival: Double
        /// Peak excursion past the target, as a fraction of the distance travelled.
        public let overshoot: Double
    }

    /// Replays Dock's loop, including the rubber band, to predict how a
    /// coefficient pair will feel. Mirrors the disassembly at `__text:0x150f2c`.
    public func simulate(gain g: Double, retention a: Double) -> Response {
        let start = 0.923, target = 0.0, positionTolerance = 0.001
        var pos = start, v = 0.0
        var steps = 0, arrivalStep = -1, peak = 0.0
        let distance = abs(start - target)
        let limit = Int(20.0 / dt)

        while steps < limit {
            v = g * (target - pos) + a * v
            pos += dt * v
            steps += 1

            let excursion = target - pos
            if excursion > peak { peak = excursion }
            if arrivalStep < 0 && abs(pos - target) <= 0.1 * distance { arrivalStep = steps }

            if pos < 0 {
                v = v * Self.bandVelocityDamping + (0 - pos) * Self.bandStiffness
            } else if pos > 1 {
                v = v * Self.bandVelocityDamping - (pos - 1) * Self.bandStiffness
            }
            if abs(v) < Self.settleEpsilon && abs(pos - target) < positionTolerance { break }
        }

        return Response(
            arrival: Double(arrivalStep < 0 ? steps : arrivalStep) * dt,
            overshoot: Swift.max(0, peak) / distance)
    }
}

/// The user-facing speed axis: a multiplier on the stock pace.
public enum Speed {
    public static let range = 0.2...1.0

    public static let stock = 1.0

    public struct Preset: Sendable {
        public let name: String
        public let value: Double
    }

    /// Ordered as the slider presents them: default first, fastest last.
    public static let presets: [Preset] = [
        .init(name: "Default", value: 1.00),
        .init(name: "Gentle", value: 0.75),
        .init(name: "Balanced", value: 0.50),
        .init(name: "Quick", value: 0.35),
        .init(name: "Instant", value: 0.20),
    ]
}

extension Double {
    func clamped(to r: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, r.lowerBound), r.upperBound)
    }
}

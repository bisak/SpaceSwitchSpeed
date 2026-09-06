// SpaceSwitch — speed control for the macOS Space-switch animation.
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
/// `dt` is the display's frame interval, so Apple's fixed coefficients describe
/// a *different* continuous-time system on every refresh rate. Everything here
/// is therefore expressed in refresh-independent terms — a dominant time
/// constant in seconds and a damping ratio — and converted back to coefficients
/// for the display actually in use.
public struct SpringModel: Sendable {
    /// Dock's shipped coefficients, read from `__TEXT,__const`.
    public static let stockRetention = 0.695
    public static let stockGain = 2.0

    /// Rubber-band constants applied when the position leaves [0, 1].
    public static let bandVelocityDamping = 0.85
    public static let bandStiffness = 0.8

    /// `|velocity|` below which Dock considers the animation finished.
    public static let settleEpsilon = 0.01

    /// Frame interval used to convert between the loop's per-frame arithmetic
    /// and seconds.
    ///
    /// The coefficients this produces barely depend on it — measured across 60,
    /// 120 and 144 Hz the gain moves half a percent and the retention not at
    /// all, because `v = gain * error + retention * v` carries no timestep and
    /// so fixes the dynamics per frame rather than per second. It is therefore
    /// a reporting reference, not something worth detecting: only the
    /// millisecond figures shown to the user depend on it.
    public static let referenceRefresh = 120.0

    /// Frame interval in seconds.
    public let dt: Double

    public init(dt: Double = 1 / SpringModel.referenceRefresh) {
        precondition(dt > 0, "frame interval must be positive")
        self.dt = dt
    }

    // MARK: - Continuous-time characterisation

    /// Damping ratio and dominant time constant of a discrete coefficient pair.
    ///
    /// The loop's characteristic polynomial is `z² - (1 + a - dt·g)z + a`. Its
    /// roots are real when Apple's constants meet a fast display and complex
    /// when they meet a slow one, so both cases are handled.
    public func characterise(gain g: Double, retention a: Double) -> (damping: Double, timeConstant: Double) {
        let b = -(1 + a - dt * g)
        let disc = b * b - 4 * a
        if disc >= 0 {
            let r = disc.squareRoot()
            let s1 = Foundation.log((-b + r) / 2) / dt
            let s2 = Foundation.log((-b - r) / 2) / dt
            let zeta = -(s1 + s2) / (2 * (s1 * s2).squareRoot())
            return (zeta, -1 / Swift.max(s1, s2))
        } else {
            let modulus = a.squareRoot()
            let sigma = Foundation.log(modulus) / dt
            let wd = Foundation.acos(-b / (2 * modulus)) / dt
            let wn = (sigma * sigma + wd * wd).squareRoot()
            return (-sigma / wn, -1 / sigma)
        }
    }

    /// Apple's own damping ratio on this display.
    public var stockDamping: Double {
        characterise(gain: Self.stockGain, retention: Self.stockRetention).damping
    }

    /// Apple's own dominant time constant on this display, in seconds.
    public var stockTimeConstant: Double {
        characterise(gain: Self.stockGain, retention: Self.stockRetention).timeConstant
    }

    // MARK: - Synthesis

    /// Coefficients realising a dominant time constant and damping ratio.
    public func coefficients(timeConstant tau: Double, damping zeta: Double) -> (
        gain: Double, retention: Double
    ) {
        precondition(tau > 0 && zeta > 0)
        let a: Double, trace: Double
        if zeta > 1 {
            let wn = 1 / (tau * (zeta - (zeta * zeta - 1).squareRoot()))
            let k = wn * (zeta * zeta - 1).squareRoot()
            let l1 = Foundation.exp((-zeta * wn + k) * dt)
            let l2 = Foundation.exp((-zeta * wn - k) * dt)
            a = l1 * l2
            trace = l1 + l2
        } else {
            let wn = 1 / (tau * zeta)
            let e = Foundation.exp(-zeta * wn * dt)
            let wd = wn * (1 - zeta * zeta).squareRoot()
            a = e * e
            trace = 2 * e * Foundation.cos(wd * dt)
        }
        return ((1 + a - trace) / dt, a)
    }

    // MARK: - The single knob

    /// Coefficients for a speed setting.
    ///
    /// Damping stays at whatever Apple's constants imply, so speed 1.0
    /// reproduces them exactly. Varying it with speed was measured and earned
    /// nothing: at most a frame of arrival and a tenth of a percent of
    /// overshoot, at 60 Hz and 120 Hz alike.
    public func coefficients(speed: Double) -> (gain: Double, retention: Double) {
        let speed = speed.clamped(to: Speed.range)
        return coefficients(timeConstant: stockTimeConstant * speed, damping: stockDamping)
    }

    // MARK: - Prediction

    public struct Response: Sendable {
        /// Seconds until the animation is within 10% of its target.
        public let arrival: Double
        /// Seconds until Dock's own settle test passes.
        public let settle: Double
        /// Peak excursion past the target, as a fraction of the distance travelled.
        public let overshoot: Double
    }

    /// Replays Dock's loop, including the rubber band, to predict how a
    /// coefficient pair will feel. Mirrors the disassembly at `__text:0x150f2c`.
    public func simulate(
        gain g: Double, retention a: Double,
        from start: Double = 0.923, to target: Double = 0.0,
        positionTolerance: Double = 0.001
    ) -> Response {
        var pos = start, v = 0.0
        var steps = 0, arrivalStep = -1, peak = 0.0
        let distance = abs(start - target)
        let limit = Int(20.0 / dt)

        while steps < limit {
            v = g * (target - pos) + a * v
            pos += dt * v
            steps += 1

            let excursion = (target < start) ? (target - pos) : (pos - target)
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
            settle: Double(steps) * dt,
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

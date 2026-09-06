// SpaceSwitch — speed control for the macOS Space-switch animation.
// Copyright (C) 2026 Biser Atanasov. Licensed under AGPL-3.0-or-later.
// See LICENSE. This program comes with ABSOLUTELY NO WARRANTY.

import CoreGraphics
import CoreVideo
import Foundation

/// Dock steps the animation once per display frame, so the refresh rate is what
/// turns its fixed coefficients into a particular feel. Everything the tool
/// computes is anchored to this number.
public enum Display {
    /// Dock falls back to 60 Hz when the window server reports no timing.
    public static let fallbackRefresh = 60.0

    public static func mainRefreshRate() -> Double {
        let id = CGMainDisplayID()
        if let mode = CGDisplayCopyDisplayMode(id) {
            let hz = mode.refreshRate
            if hz > 0 { return hz }
        }
        // Built-in panels routinely report 0 through CoreGraphics; the display
        // link still knows the nominal period.
        var link: CVDisplayLink?
        if CVDisplayLinkCreateWithCGDisplay(id, &link) == kCVReturnSuccess, let link {
            let period = CVDisplayLinkGetNominalOutputVideoRefreshPeriod(link)
            if period.flags & CVTimeFlags.isIndefinite.rawValue == 0, period.timeValue > 0 {
                return Double(period.timeScale) / Double(period.timeValue)
            }
        }
        return fallbackRefresh
    }
}

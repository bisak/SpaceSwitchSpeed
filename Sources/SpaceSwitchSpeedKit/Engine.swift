// Space Switch Speed — speed control for the macOS Space-switch animation.
// Copyright (C) 2026 Biser Atanasov. Licensed under AGPL-3.0-or-later.
// See LICENSE. This program comes with ABSOLUTELY NO WARRANTY.

import Foundation

public struct Status {
    public let applied: Bool
    public let gain: Double
    public let retention: Double
    public let speed: Double
    public let dockPID: pid_t
}

/// Applies and removes the Space-switch patch in the running Dock.
///
/// Nothing is written to disk and nothing outlives the Dock process: restarting
/// Dock restores stock behaviour unconditionally, which is the tool's safety net.
public final class Engine {
    private let target: DockTarget
    private let image: MachOImage
    private let model: SpringModel

    public init(pid: pid_t) throws {
        target = try DockTarget(pid: pid)
        image = try MachOImage(target: target)
        model = SpringModel()
    }

    /// Best effort across every Dock, for the paths that take Space Switch Speed
    /// off the machine.
    public static func revertAll() {
        for pid in DockTarget.findDocks() {
            if let engine = try? Engine(pid: pid) { try? engine.revert() }
        }
    }

    // MARK: - Inspection

    public func status() throws -> Status {
        let sites = try PatchLocator.locate(target: target, image: image)
        let gain: Double, retention: Double

        switch sites.state {
        case .stock:
            retention = try target.readDouble(sites.stockRetentionAddress)
            gain = SpringModel.stockGain
        case .patched:
            guard let page = sites.scratchPage else {
                throw SpaceSwitchSpeedError.verificationFailed("no scratch page")
            }
            retention = try target.readDouble(page)
            gain = try target.readDouble(page + 8)
        }

        return Status(
            applied: sites.state == .patched,
            gain: gain, retention: retention,
            speed: SpringModel.speed(retention: retention),
            dockPID: target.pid
        )
    }

    // MARK: - Apply

    @discardableResult
    public func apply(speed: Double) throws -> Status {
        let sites = try PatchLocator.locate(target: target, image: image)
        let (gain, retention) = model.coefficients(speed: speed)

        switch sites.state {
        case .patched:
            // Instructions are already in place; only the constants change.
            guard let page = sites.scratchPage else {
                throw SpaceSwitchSpeedError.verificationFailed("no scratch page")
            }
            try target.writeDouble(page, retention)
            try target.writeDouble(page + 8, gain)
        case .stock:
            let stock = try target.readDouble(sites.stockRetentionAddress)
            guard abs(stock - SpringModel.stockRetention) < 1e-9 else {
                throw SpaceSwitchSpeedError.unexpectedConstants(
                    "retention is \(stock), expected \(SpringModel.stockRetention)")
            }
            try install(sites, gain: gain, retention: retention)
        }

        let after = try status()
        guard after.applied,
            abs(after.gain - gain) < 1e-9, abs(after.retention - retention) < 1e-12
        else {
            throw SpaceSwitchSpeedError.verificationFailed("constants did not read back")
        }
        return after
    }

    private func install(_ sites: PatchSites, gain: Double, retention: Double) throws {
        let scratch = try target.allocateScratch(near: sites.adrpSite)
        do {
            try target.writeDouble(scratch, retention)
            try target.writeDouble(scratch + 8, gain)
            // Apple has shipped two encodings of the gain-zeroing `movi`; keep the
            // one actually being replaced so revert restores this build's own word.
            if let zero = sites.stockGainZeroWord { try target.writeWord(scratch + 16, zero) }

            for (address, word) in try sites.patchWords(scratch: scratch) {
                try target.writeWord(address, word)
            }
        } catch {
            target.freeScratch(scratch)
            throw error
        }
    }

    // MARK: - Revert

    public func revert() throws {
        let sites = try PatchLocator.locate(target: target, image: image)
        guard sites.state == .patched else { return }

        // Prefer the encoding this build actually used, stashed beside the
        // constants at patch time; fall back to the 128-bit form when it is not
        // there or does not decode as a zeroing of the right register, as after a
        // patch applied by an older build.
        var gainZero = sites.fallbackGainZeroWord
        if let scratch = sites.scratchPage, let stored = try? target.readWord(scratch + 16),
            ARM64.decodeMOVIzero(stored) == sites.gainReg
        {
            gainZero = stored
        }

        for (address, word) in try sites.stockWords(gainZero: gainZero) {
            try target.writeWord(address, word)
        }

        if let scratch = sites.scratchPage { target.freeScratch(scratch) }

        let after = try PatchLocator.locate(target: target, image: image)
        guard after.state == .stock else {
            throw SpaceSwitchSpeedError.verificationFailed("still patched after revert")
        }
        let retention = try target.readDouble(after.stockRetentionAddress)
        guard abs(retention - SpringModel.stockRetention) < 1e-9 else {
            throw SpaceSwitchSpeedError.verificationFailed("retention is \(retention) after revert")
        }
    }
}

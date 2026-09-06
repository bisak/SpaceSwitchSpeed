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
/// Dock restores stock behaviour unconditionally, and the helper is what puts the
/// patch back.
public final class Engine {
    private let target: DockTarget
    private let image: MachOImage
    private let model: SpringModel

    public init(pid: pid_t) throws {
        target = try DockTarget(pid: pid)
        image = try MachOImage(target: target)
        model = SpringModel()
    }

    /// Every Dock put back to stock, for the paths that take Space Switch Speed
    /// off the machine. Returns the Docks it could not put back, so the caller
    /// can say so rather than report a clean removal over a patched Dock.
    @discardableResult
    public static func revertAll() -> [(pid: pid_t, error: Error)] {
        var failures: [(pid: pid_t, error: Error)] = []
        for pid in DockTarget.findDocks() {
            do {
                try Engine(pid: pid).revert()
            } catch {
                failures.append((pid, error))
            }
        }
        return failures
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
            let page = try scratch(of: sites).page
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

    /// The scratch page is trusted only when it carries the word `install`
    /// stashed there. A build whose preamble merely resembles the patched shape
    /// has no such word, and writing into its page would corrupt Dock's own
    /// constants.
    private func scratch(of sites: PatchSites) throws -> (page: UInt64, gainZero: UInt32) {
        guard let page = sites.scratchPage else {
            throw SpaceSwitchSpeedError.verificationFailed("no scratch page")
        }
        let stored = try target.readWord(page + 16)
        guard ARM64.decodeMOVIzero(stored) == sites.gainReg else {
            throw SpaceSwitchSpeedError.verificationFailed(
                "the scratch page does not carry the patch's stash")
        }
        return (page, stored)
    }

    // MARK: - Apply

    @discardableResult
    public func apply(speed: Double) throws -> Status {
        let sites = try PatchLocator.locate(target: target, image: image)
        let (gain, retention) = model.coefficients(speed: speed)

        switch sites.state {
        case .patched:
            // Instructions are already in place; only the constants change.
            let page = try scratch(of: sites).page
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
        guard let gainZero = sites.stockGainZeroWord else {
            throw SpaceSwitchSpeedError.verificationFailed("no gain-zeroing instruction to stash")
        }
        let scratch = try target.allocateScratch(near: sites.adrpSite)
        do {
            try target.writeDouble(scratch, retention)
            try target.writeDouble(scratch + 8, gain)
            // Apple has shipped two encodings of the gain-zeroing `movi`; keep the
            // one actually being replaced so revert restores this build's own word.
            try target.writeWord(scratch + 16, gainZero)
            try target.writeWords(sites.patchWords(scratch: scratch))
        } catch {
            target.freeScratch(scratch)
            throw error
        }
    }

    // MARK: - Revert

    public func revert() throws {
        let sites = try PatchLocator.locate(target: target, image: image)
        guard sites.state == .patched else { return }
        let (page, gainZero) = try scratch(of: sites)

        try target.writeWords(sites.stockWords(gainZero: gainZero))
        target.freeScratch(page)

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

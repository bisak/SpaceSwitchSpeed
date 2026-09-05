// SpaceSwitch — speed control for the macOS Space-switch animation.
// Copyright (C) 2026 Biser Atanasov. Licensed under AGPL-3.0-or-later.
// See LICENSE. This program comes with ABSOLUTELY NO WARRANTY.

import Foundation

public struct Status {
    public let applied: Bool
    public let gain: Double
    public let retention: Double
    public let refreshHz: Double
    public let speed: Double
    public let damping: Double
    public let response: SpringModel.Response
    public let stockResponse: SpringModel.Response
    public let dockPID: pid_t
}

/// Applies and removes the Space-switch patch in the running Dock.
///
/// Nothing is written to disk and nothing outlives the Dock process: restarting
/// Dock restores stock behaviour unconditionally, which is the tool's safety net.
public final class Engine {
    private let target: DockTarget
    private let image: MachOImage
    public let model: SpringModel

    public init(refreshHz: Double? = nil) throws {
        target = try DockTarget()
        image = try MachOImage(target: target)
        model = SpringModel(dt: 1.0 / (refreshHz ?? Display.mainRefreshRate()))
    }

    public var refreshHz: Double { 1.0 / model.dt }

    // MARK: - Inspection

    public func status() throws -> Status {
        let sites = try PatchLocator.locate(target: target, image: image)
        let gain: Double, retention: Double

        switch sites.state {
        case .stock:
            retention = try target.readDouble(sites.stockRetentionAddress)
            gain = SpringModel.stockGain
        case .patched:
            guard let page = sites.scratchPage else { throw SpaceSwitchError.verificationFailed("no scratch page") }
            retention = try target.readDouble(page)
            gain = try target.readDouble(page + 8)
        }

        let (zeta, tau) = model.characterise(gain: gain, retention: retention)
        return Status(
            applied: sites.state == .patched,
            gain: gain, retention: retention,
            refreshHz: refreshHz,
            speed: tau / model.stockTimeConstant,
            damping: zeta,
            response: model.simulate(gain: gain, retention: retention),
            stockResponse: model.simulate(gain: SpringModel.stockGain, retention: SpringModel.stockRetention),
            dockPID: target.pid
        )
    }

    // MARK: - Apply

    @discardableResult
    public func apply(speed: Double, damping: Double? = nil) throws -> Status {
        let sites = try PatchLocator.locate(target: target, image: image)
        let (gain, retention) = model.coefficients(speed: speed, damping: damping)

        switch sites.state {
        case .patched:
            // Instructions are already in place; only the constants change.
            guard let page = sites.scratchPage else { throw SpaceSwitchError.verificationFailed("no scratch page") }
            try target.writeDouble(page, retention)
            try target.writeDouble(page + 8, gain)
        case .stock:
            let stock = try target.readDouble(sites.stockRetentionAddress)
            guard abs(stock - SpringModel.stockRetention) < 1e-9 else {
                throw SpaceSwitchError.unexpectedConstants(
                    "retention is \(stock), expected \(SpringModel.stockRetention)")
            }
            try install(sites, gain: gain, retention: retention)
        }

        let after = try status()
        guard after.applied,
              abs(after.gain - gain) < 1e-9, abs(after.retention - retention) < 1e-12 else {
            throw SpaceSwitchError.verificationFailed("constants did not read back")
        }
        return after
    }

    private func install(_ sites: PatchSites, gain: Double, retention: Double) throws {
        let scratch = try target.allocateScratch(near: sites.adrpSite)
        do {
            try target.writeDouble(scratch, retention)
            try target.writeDouble(scratch + 8, gain)

            guard let adrp = ARM64.adrp(d: sites.baseReg, page: scratch, at: sites.adrpSite) else {
                throw SpaceSwitchError.noReachableScratch
            }
            guard let loadA = ARM64.ldrd(t: sites.retentionReg, n: sites.baseReg, offset: 0),
                  let loadG = ARM64.ldrd(t: sites.gainReg, n: sites.baseReg, offset: 8) else {
                throw SpaceSwitchError.encodingFailed("constant loads")
            }

            // Order matters: the loads are rewritten before the base register is
            // repointed, so no intermediate state reads a wrong address.
            try target.writeWord(sites.retentionLoadSite, loadA)
            try target.writeWord(sites.gainLoadSite, loadG)
            try target.writeWord(sites.gainSite,
                                 ARM64.fmul(d: sites.errorReg, n: sites.errorReg, m: sites.gainReg))
            try target.writeWord(sites.bandSite,
                                 ARM64.fneg(d: sites.bandDestReg, n: sites.positionReg))
            try target.writeWord(sites.adrpSite, adrp)
        } catch {
            target.freeScratch(scratch)
            throw error
        }
    }

    // MARK: - Revert

    public func revert() throws {
        let sites = try PatchLocator.locate(target: target, image: image)
        guard sites.state == .patched else { return }

        guard let adrp = ARM64.adrp(d: sites.baseReg, page: sites.stockConstPage, at: sites.adrpSite),
              let loadA = ARM64.ldrd(t: sites.retentionReg, n: sites.baseReg, offset: sites.stockRetentionOffset) else {
            throw SpaceSwitchError.encodingFailed("stock preamble")
        }

        try target.writeWord(sites.adrpSite, adrp)
        try target.writeWord(sites.retentionLoadSite, loadA)
        try target.writeWord(sites.gainLoadSite, 0x6F00_E400 | sites.gainReg)   // movi vK.2d, #0
        try target.writeWord(sites.gainSite,
                             ARM64.fadd(d: sites.errorReg, n: sites.errorReg, m: sites.errorReg))
        try target.writeWord(sites.bandSite,
                             ARM64.fsub(d: sites.bandDestReg, n: sites.gainReg, m: sites.positionReg))

        if let scratch = sites.scratchPage { target.freeScratch(scratch) }

        let after = try PatchLocator.locate(target: target, image: image)
        guard after.state == .stock else { throw SpaceSwitchError.verificationFailed("still patched after revert") }
        let retention = try target.readDouble(after.stockRetentionAddress)
        guard abs(retention - SpringModel.stockRetention) < 1e-9 else {
            throw SpaceSwitchError.verificationFailed("retention is \(retention) after revert")
        }
    }
}

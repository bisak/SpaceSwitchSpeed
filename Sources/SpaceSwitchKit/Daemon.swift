// SpaceSwitch — speed control for the macOS Space-switch animation.
// Copyright (C) 2026 Biser Atanasov. Licensed under AGPL-3.0-or-later.
// See LICENSE. This program comes with ABSOLUTELY NO WARRANTY.

import Darwin
import Dispatch
import Foundation

/// Keeps Dock matching the saved settings.
///
/// The patch lives in Dock's memory and dies with the process, so something has
/// to notice Dock restarting — at login, after a crash, after `killall Dock` —
/// and put it back. That is this.
///
/// It polls rather than watching for events. Settings are written atomically,
/// which replaces the file's inode and leaves an inode watch permanently deaf;
/// a half-second poll of a seventy-byte file costs nothing and cannot go deaf.
public final class Daemon {
    private let queue = DispatchQueue(label: "com.bisak.spaceswitch.daemon")
    private var timer: DispatchSourceTimer?
    private var lastApplied: Configuration?
    private var lastDockPID: pid_t = 0

    public init() {}

    public func run() -> Never {
        try? Configuration.prepareDirectory()
        queue.async { self.reconcile() }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in self?.reconcile() }
        timer.resume()
        self.timer = timer

        dispatchMain()
    }

    private func reconcile() {
        let config = Configuration.load()
        let dock = DockTarget.findDock() ?? 0
        guard config != lastApplied || dock != lastDockPID else { return }
        guard dock != 0 else { return }

        do {
            let engine = try Engine(refreshHz: config.lastKnownRefreshHz)
            let status: Status
            if config.enabled {
                status = try engine.apply(speed: config.speed, damping: config.damping)
            } else {
                try engine.revert()
                status = try engine.status()
            }
            lastApplied = config
            lastDockPID = status.dockPID
            publish(status, error: nil)
        } catch {
            // Leave lastApplied untouched so the next tick retries.
            lastDockPID = 0
            publish(nil, error: (error as? SpaceSwitchError)?.description ?? "\(error)")
        }
    }

    private func publish(_ status: Status?, error: String?) {
        HelperStatus(
            applied: status?.applied ?? false,
            speed: status?.speed ?? Speed.stock,
            damping: status?.damping ?? 0,
            gain: status?.gain ?? 0,
            retention: status?.retention ?? 0,
            refreshHz: status?.refreshHz ?? 0,
            dockPID: status?.dockPID ?? 0,
            updatedAt: Date(),
            error: error
        ).save()
    }
}

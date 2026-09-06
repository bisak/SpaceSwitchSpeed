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
/// It waits for events rather than polling. Locating Dock means walking every
/// process in the system, which is far too expensive to repeat on a timer, so
/// it is done once and then only when the process it found actually exits.
/// Every stored property is read and written only on `queue`, which is what
/// makes the unchecked conformance sound: `run()` hands off to the queue before
/// touching anything, and every event source delivers onto it.
public final class Daemon: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.bisak.spaceswitch.daemon", qos: .utility)
    private var dockWatch: DispatchSourceProcess?
    private var settingsWatch: DispatchSourceFileSystemObject?
    private var heartbeat: DispatchSourceTimer?

    private var lastApplied: Configuration?
    private var dockPID: pid_t = 0

    /// The app bundle that installed this helper, when there is one. Dragging
    /// an app to the Trash notifies nobody, so a helper that outlived its app
    /// would keep patching Dock forever with nothing left to control it.
    private let owner: URL?
    private var consecutiveOrphanChecks = 0

    public init(owner: URL? = nil) {
        self.owner = owner
    }

    public func run() -> Never {
        try? Configuration.prepareDirectory()
        queue.async {
            self.reconcile(because: "startup")
            self.watchSettings()
            self.startHeartbeat()
        }
        dispatchMain()
    }

    // MARK: - Applying

    private func reconcile(because reason: String) {
        let config = Configuration.load()
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
            dockPID = status.dockPID
            publish(status, error: nil)
            watchDock(status.dockPID)
        } catch SpaceSwitchError.dockNotRunning {
            // Dock is mid-restart; it will be back in a moment.
            queue.asyncAfter(deadline: .now() + 1) { self.reconcile(because: reason) }
        } catch {
            dockPID = 0
            publish(nil, error: (error as? SpaceSwitchError)?.description ?? "\(error)")
            queue.asyncAfter(deadline: .now() + 5) { self.reconcile(because: "retry") }
        }
    }

    private func publish(_ status: Status?, error: String?) {
        HelperStatus(
            speed: status?.speed ?? Speed.stock,
            dockPID: status?.dockPID ?? 0,
            updatedAt: Date(),
            error: error
        ).save()
    }

    // MARK: - Waiting

    /// Costs nothing while Dock is alive; the kernel wakes us when it exits.
    private func watchDock(_ pid: pid_t) {
        dockWatch?.cancel()
        guard pid > 0 else { return }
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.dockPID = 0
            self.queue.asyncAfter(deadline: .now() + 0.5) { self.reconcile(because: "Dock restarted") }
        }
        source.resume()
        dockWatch = source
    }

    /// Watches the settings *directory*, not the file. Settings are written
    /// atomically, which replaces the file's inode and would leave a watch on
    /// the file permanently deaf after the first change. A directory's inode is
    /// stable, so this is armed once and never needs rebuilding.
    private func watchSettings() {
        let descriptor = open(Configuration.directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write], queue: queue)
        source.setEventHandler { [weak self] in self?.applyIfSettingsChanged() }
        // Sole owner of the descriptor, so it cannot be closed twice.
        source.setCancelHandler { close(descriptor) }
        source.resume()
        settingsWatch = source
    }

    /// The daemon writes its own status into the watched directory, so every
    /// event has to be compared rather than acted on blindly.
    private func applyIfSettingsChanged() {
        guard Configuration.load() != lastApplied else { return }
        reconcile(because: "settings changed")
    }

    /// Backstop for anything the event sources miss. It checks liveness with a
    /// single signal-less `kill`, and carries generous leeway so the kernel can
    /// coalesce it with other timers rather than waking the CPU on its own.
    private func startHeartbeat() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 60, repeating: 60, leeway: .seconds(30))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if self.isOrphaned() { return self.removeSelf() }
            if self.dockPID == 0 || kill(self.dockPID, 0) != 0 {
                self.reconcile(because: "heartbeat")
            }
        }
        timer.resume()
        heartbeat = timer
    }

    // MARK: - Outliving the app

    /// Requires several consecutive misses so that moving the app, or replacing
    /// it during an update, does not look like a deletion.
    private func isOrphaned() -> Bool {
        guard let owner else { return false }
        let stillThere =
            FileManager.default.fileExists(atPath: owner.path)
            || FileManager.default.fileExists(atPath: "/Applications/SpaceSwitch.app")
        consecutiveOrphanChecks = stillThere ? 0 : consecutiveOrphanChecks + 1
        return consecutiveOrphanChecks >= 3
    }

    /// Reverts Dock and takes the helper off the system, so dragging the app to
    /// the Trash really is enough to be rid of SpaceSwitch.
    private func removeSelf() {
        if let engine = try? Engine() { try? engine.revert() }
        try? HelperInstall.uninstall(purge: true)
        exit(0)
    }
}

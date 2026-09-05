// SpaceSwitch — speed control for the macOS Space-switch animation.
// Copyright (C) 2026 Biser Atanasov. Licensed under AGPL-3.0-or-later.
// See LICENSE. This program comes with ABSOLUTELY NO WARRANTY.

import Darwin
import Dispatch
import Foundation
import SpaceSwitchKit

/// Root helper. The patch lives in Dock's memory and dies with the process, so
/// something has to notice Dock restarting — at login, after a crash, or after
/// the user runs `killall Dock` — and put it back.
final class Helper {
    private let queue = DispatchQueue(label: "com.bisak.spaceswitch.helper")
    private var dockWatch: DispatchSourceProcess?
    private var directoryWatch: DispatchSourceFileSystemObject?
    private var heartbeat: DispatchSourceTimer?

    private var lastApplied: Configuration?
    private var lastDockPID: pid_t = 0

    func run() {
        log("started")
        try? Configuration.prepareDirectory()
        queue.async { self.reapply(because: "startup") }
        watchSettings()
        startHeartbeat()
        dispatchMain()
    }

    // MARK: - Applying

    private func reapply(because reason: String) {
        let config = Configuration.load()
        do {
            let engine = try Engine(refreshHz: config.lastKnownRefreshHz)
            let status: Status
            if config.enabled {
                status = try engine.apply(speed: config.speed, damping: config.damping)
                log(String(format: "%@: speed %.2f damping %.3f at %.0f Hz (Dock %d)",
                           reason, status.speed, status.damping, status.refreshHz, status.dockPID))
            } else {
                try engine.revert()
                status = try engine.status()
                log("\(reason): disabled, Dock left at stock")
            }
            lastApplied = config
            lastDockPID = status.dockPID
            publish(status, error: nil)
            watchDock(pid: status.dockPID)
        } catch SpaceSwitchError.dockNotRunning {
            // Dock is mid-restart. Poll briefly rather than giving up.
            queue.asyncAfter(deadline: .now() + 1) { self.reapply(because: reason) }
        } catch {
            let message = (error as? SpaceSwitchError)?.description ?? "\(error)"
            log("\(reason) failed: \(message)")
            publish(nil, error: message)
            queue.asyncAfter(deadline: .now() + 5) { self.reapply(because: "retry") }
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

    private func watchDock(pid: pid_t) {
        dockWatch?.cancel()
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        source.setEventHandler { [weak self] in
            self?.log("Dock exited; waiting for its replacement")
            self?.queue.asyncAfter(deadline: .now() + 1) { self?.reapply(because: "Dock restarted") }
        }
        source.resume()
        dockWatch = source
    }

    // MARK: - Settings

    /// Watches the settings *directory*, not the file. Settings are written
    /// atomically, which replaces the file's inode and would leave a watch on
    /// the file permanently deaf after the first change.
    private func watchSettings() {
        let descriptor = open(Configuration.directory.path, O_EVTONLY)
        guard descriptor >= 0 else {
            log("cannot watch \(Configuration.directory.path); relying on the heartbeat")
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write], queue: queue)
        source.setEventHandler { [weak self] in self?.applyIfSettingsChanged() }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        directoryWatch = source
    }

    /// The helper writes its own status into the watched directory, so every
    /// change has to be compared rather than acted on blindly.
    private func applyIfSettingsChanged() {
        let config = Configuration.load()
        guard config != lastApplied else { return }
        reapply(because: "settings changed")
    }

    /// Catches anything the event sources miss: a dropped kqueue notification,
    /// or a Dock that was replaced without the exit source firing.
    private func startHeartbeat() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 15, repeating: 15)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if Configuration.load() != self.lastApplied {
                self.reapply(because: "settings changed")
            } else if let pid = DockTarget.findDock(), pid != self.lastDockPID {
                self.reapply(because: "Dock replaced")
            }
        }
        timer.resume()
        heartbeat = timer
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(Data("spaceswitchd: \(message)\n".utf8))
    }
}

Helper().run()

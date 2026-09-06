// Space Switch Speed — speed control for the macOS Space-switch animation.
// Copyright (C) 2026 Biser Atanasov. Licensed under AGPL-3.0-or-later.
// See LICENSE. This program comes with ABSOLUTELY NO WARRANTY.

import Darwin
import Dispatch
import Foundation
import SystemConfiguration
import os

/// Keeps every running Dock matching the saved settings.
///
/// The patch lives in Dock's memory and dies with the process, so something has
/// to notice Dock restarting — at login, after a crash, after `killall Dock` —
/// and put it back. That is this.
///
/// It waits for events rather than polling: a Dock exiting, the settings
/// changing, the console user changing. Whatever cannot be done yet is retried
/// with a backoff that settles at every 15 seconds, and a status that has not
/// changed is not rewritten, so a helper that cannot do its job — after SIP's
/// debugging restrictions were turned back on, say — costs nothing to keep around.
///
/// Every stored property is read and written only on `queue`, which is what
/// makes the unchecked conformance sound: `run()` hands off to the queue before
/// touching anything, and every event source delivers onto it.
public final class Daemon: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.bisak.spaceswitchspeed.daemon", qos: .utility)
    private let log = Logger(subsystem: "com.bisak.spaceswitchspeed", category: "helper")
    private var dockWatches: [pid_t: DispatchSourceProcess] = [:]
    private var signalWatches: [DispatchSourceSignal] = []
    private var settingsWatch: DispatchSourceFileSystemObject?
    private var consoleWatch: SCDynamicStore?
    private var heartbeat: DispatchSourceTimer?
    private var pending: DispatchWorkItem?
    private var retryDelay: TimeInterval = 1

    private var lastSeen: Configuration?
    private var lastPublished: HelperStatus?

    private let owner: OwningApp?
    private var ownerPath: String?
    private var consecutiveOrphanChecks = 0

    /// `owner` is the app bundle that installed this helper, when there is one.
    public init(owner: String? = nil) {
        self.owner = owner.map { OwningApp(recorded: $0) }
        ownerPath = owner
    }

    public func run() -> Never {
        try? Configuration.prepareDirectory()
        queue.async {
            self.log.notice("Started; app at \(self.ownerPath ?? "no recorded path", privacy: .public)")
            self.watchSignals()
            self.watchSettings()
            self.watchConsoleUser()
            self.reconcile()
            self.startHeartbeat()
        }
        dispatchMain()
    }

    // MARK: - Applying

    private func reconcile() {
        pending?.cancel()
        pending = nil

        let config = Configuration.load()
        lastSeen = config
        let docks = DockTarget.findDocks()
        for pid in dockWatches.keys.filter({ !docks.contains($0) }) {
            dockWatches.removeValue(forKey: pid)?.cancel()
        }
        guard !docks.isEmpty else { return retryLater() }

        var statuses: [Status] = []
        var failure: String?
        for pid in docks {
            watchDock(pid)
            do {
                let engine = try Engine(pid: pid)
                if config.isEnabled {
                    statuses.append(try engine.apply(speed: config.speed))
                } else {
                    try engine.revert()
                    statuses.append(try engine.status())
                }
            } catch {
                failure = failure ?? (error as? SpaceSwitchSpeedError)?.description ?? "\(error)"
            }
        }
        publish(statuses, error: failure)
        if failure == nil { retryDelay = 1 } else { retryLater() }
    }

    private func publish(_ statuses: [Status], error: String?) {
        let status = HelperStatus(
            speed: statuses.first?.speed ?? Speed.stock,
            dockPIDs: statuses.map(\.dockPID),
            updatedAt: Date(),
            error: error)
        guard !status.describesSameState(as: lastPublished) else { return }
        lastPublished = status
        status.save()
        if let error {
            log.error("\(error, privacy: .public)")
        } else {
            log.notice(
                "Speed \(status.speed, format: .fixed(precision: 2)) on Dock \(status.dockPIDs.description, privacy: .public)"
            )
        }
    }

    // MARK: - Scheduling

    /// An event means the world changed, so the backoff starts over.
    private func reconcileSoon(after delay: TimeInterval) {
        retryDelay = 1
        schedule(after: delay)
    }

    private func retryLater() {
        log.debug("Retrying in \(self.retryDelay, format: .fixed(precision: 0)) s")
        schedule(after: retryDelay)
        retryDelay = min(retryDelay * 2, 15)
    }

    /// At most one reconcile is ever pending; a new reason replaces the old timer.
    private func schedule(after delay: TimeInterval) {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.reconcile() }
        pending = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    // MARK: - Waiting

    /// Costs nothing while Dock is alive; the kernel wakes us when it exits.
    private func watchDock(_ pid: pid_t) {
        guard dockWatches[pid] == nil else { return }
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.dockWatches.removeValue(forKey: pid)?.cancel()
            self.reconcileSoon(after: 0.5)
        }
        source.resume()
        dockWatches[pid] = source
    }

    /// The switch under Login Items, a bootout and system shutdown all end in
    /// SIGTERM. Dock goes back first, so that off means off.
    private func watchSignals() {
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler { [weak self] in self?.stop() }
            source.resume()
            signalWatches.append(source)
        }
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
    /// event has to be compared with the settings last *read*. Comparing with
    /// the settings last applied would make every failed attempt trigger the
    /// next, with nothing in between.
    private func applyIfSettingsChanged() {
        guard Configuration.load() != lastSeen else { return }
        retryDelay = 1
        reconcile()
    }

    /// Login, logout and fast user switching each start or stop a Dock without
    /// any Dock exiting first, so the console user is the event to wait on. The
    /// new session's Dock takes a moment to appear.
    private func watchConsoleUser() {
        var context = SCDynamicStoreContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        let callback: SCDynamicStoreCallBack = { _, _, info in
            guard let info else { return }
            Unmanaged<Daemon>.fromOpaque(info).takeUnretainedValue().reconcileSoon(after: 3)
        }
        let keys = [SCDynamicStoreKeyCreateConsoleUser(nil)] as CFArray
        guard let store = SCDynamicStoreCreate(nil, HelperInstall.label as CFString, callback, &context),
            SCDynamicStoreSetNotificationKeys(store, keys, nil),
            SCDynamicStoreSetDispatchQueue(store, queue)
        else {
            log.error("Could not watch the console user; logins will be caught by retries instead")
            return
        }
        consoleWatch = store
    }

    /// Backstop for anything the event sources miss, and the orphan check. Its
    /// generous leeway lets the kernel coalesce it with other timers rather
    /// than waking the CPU on its own.
    private func startHeartbeat() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 60, repeating: 60, leeway: .seconds(30))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if self.isOrphaned() { self.removeSelf() }
            if self.consoleWatch == nil { self.watchConsoleUser() }
            if self.pending == nil, Set(DockTarget.findDocks()) != Set(self.dockWatches.keys) {
                self.reconcile()
            }
        }
        timer.resume()
        heartbeat = timer
    }

    // MARK: - Stopping

    /// Several consecutive misses, so an app being replaced during an update
    /// does not look like a deletion. A move is followed, and recorded so the
    /// helper still knows its app after the next boot.
    private func isOrphaned() -> Bool {
        guard let owner else { return false }
        guard let path = owner.locate() else {
            consecutiveOrphanChecks += 1
            log.notice("App not found (\(self.consecutiveOrphanChecks) of 3)")
            return consecutiveOrphanChecks >= 3
        }
        consecutiveOrphanChecks = 0
        if path != ownerPath {
            ownerPath = path
            log.notice("App moved to \(path, privacy: .public)")
            try? HelperInstall.recordOwner(path)
        }
        return false
    }

    /// Reverts every Dock and takes the helper off the system, so dragging the
    /// app to the Trash really is enough to be rid of Space Switch Speed.
    private func removeSelf() -> Never {
        log.notice("App is gone; reverting Dock and removing the helper")
        Engine.revertAll()
        try? HelperInstall.uninstall()
        exit(0)
    }

    private func stop() -> Never {
        log.notice("Stopping; reverting Dock")
        Engine.revertAll()
        exit(0)
    }
}

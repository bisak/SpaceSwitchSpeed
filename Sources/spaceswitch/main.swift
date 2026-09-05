// SpaceSwitch — speed control for the macOS Space-switch animation.
// Copyright (C) 2026 Biser Atanasov. Licensed under AGPL-3.0-or-later.
// See LICENSE. This program comes with ABSOLUTELY NO WARRANTY.

import Darwin
import Foundation
import SpaceSwitchKit

let usage = """
SpaceSwitch — speed control for the macOS Space-switch animation

USAGE
  spaceswitch [<speed>] [options]
  spaceswitch status | revert | presets | install | uninstall

ARGUMENTS
  <speed>              0.2 – 1.0, a multiplier on your display's stock pace.
                       1.0 is exactly what macOS ships; lower is faster.
                       Accepts a preset name as well: \(Speed.presets.map { $0.name.lowercased() }.joined(separator: ", "))

OPTIONS
  --damping <ratio>    Override the damping ratio. Below 1.0 overshoots and
                       bounces; 1.0 is critical; above 1.0 eases in. Default
                       follows your display's stock value, easing toward
                       critical as speed increases.
  --refresh <hz>       Assume this refresh rate instead of detecting it.
  --dry-run            Print what would change without touching Dock.
  --json               Machine-readable output.
  --help               This text.

COMMANDS
  status               Show what Dock is currently running.
  config               Show the saved settings and what the helper reports.
  revert               Restore Apple's constants. `killall Dock` also works.
  presets              List the presets and their predicted timings.
  install              Install the helper so the setting survives restarts.
  uninstall            Remove the helper and revert.

Writing to Dock needs System Integrity Protection disabled and root privileges.
See the README for what that means and how to weigh it.
"""

// MARK: - Argument parsing

var speedArg: Double?
var dampingArg: Double?
var refreshArg: Double?
var command = "apply"
var json = false
var dryRun = false

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("spaceswitch: \(message)\n".utf8))
    exit(1)
}

func preset(named name: String) -> Double? {
    Speed.presets.first { $0.name.lowercased() == name.lowercased() }?.value
}

var args = Array(CommandLine.arguments.dropFirst())
var index = 0
while index < args.count {
    let arg = args[index]
    switch arg {
    case "--help", "-h": print(usage); exit(0)
    case "--json": json = true
    case "--dry-run": dryRun = true
    case "--damping":
        index += 1
        guard index < args.count, let v = Double(args[index]) else { fail("--damping needs a number") }
        dampingArg = v
    case "--refresh":
        index += 1
        guard index < args.count, let v = Double(args[index]), v > 0 else { fail("--refresh needs a positive number") }
        refreshArg = v
    case "--speed":
        index += 1
        guard index < args.count, let v = Double(args[index]) else { fail("--speed needs a number") }
        speedArg = v
    case "status", "revert", "presets", "install", "uninstall", "config", "daemon": command = arg
    default:
        if let v = Double(arg) { speedArg = v }
        else if let v = preset(named: arg) { speedArg = v }
        else { fail("unrecognised argument '\(arg)'. Try --help.") }
    }
    index += 1
}

// MARK: - Reporting

func format(_ status: Status) -> String {
    let r = status.response, s = status.stockResponse
    let ratio = r.arrival / s.arrival
    var lines = [String]()
    lines.append(status.applied
        ? "SpaceSwitch is active on Dock (pid \(status.dockPID))."
        : "Dock is running Apple's stock animation (pid \(status.dockPID)).")
    lines.append("")
    lines.append(String(format: "  display        %.0f Hz  (frame interval %.4f s)", status.refreshHz, 1 / status.refreshHz))
    lines.append(String(format: "  speed          %.2f  of stock", status.speed))
    lines.append(String(format: "  damping        %.3f  (%@)", status.damping,
                        status.damping > 1.001 ? "eases in" : status.damping < 0.999 ? "overshoots" : "critical"))
    lines.append("")
    lines.append(String(format: "  arrives in     %.0f ms   (stock %.0f ms, %.2fx)", r.arrival * 1000, s.arrival * 1000, ratio))
    lines.append(String(format: "  settles in     %.0f ms   (stock %.0f ms)", r.settle * 1000, s.settle * 1000))
    lines.append(String(format: "  overshoot      %.1f%%", r.overshoot * 100))
    lines.append("")
    lines.append(String(format: "  gain %.6f   retention %.6f", status.gain, status.retention))
    return lines.joined(separator: "\n")
}

func emit(_ status: Status, json: Bool) {
    if json {
        let payload: [String: Any] = [
            "applied": status.applied, "speed": status.speed, "damping": status.damping,
            "gain": status.gain, "retention": status.retention, "refreshHz": status.refreshHz,
            "arrivalMs": status.response.arrival * 1000, "settleMs": status.response.settle * 1000,
            "overshoot": status.response.overshoot, "stockArrivalMs": status.stockResponse.arrival * 1000,
            "dockPID": Int(status.dockPID),
        ]
        let data = try! JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    } else {
        print(format(status))
    }
}

// MARK: - Commands

do {
    switch command {
    case "presets":
        let model = SpringModel(dt: 1 / (refreshArg ?? Display.mainRefreshRate()))
        let stock = model.simulate(gain: SpringModel.stockGain, retention: SpringModel.stockRetention)
        print(String(format: "Predicted for a %.0f Hz display:\n", 1 / model.dt))
        print("  preset      speed   damping   arrives   settles   vs stock")
        for p in Speed.presets {
            let (g, a) = model.coefficients(speed: p.value)
            let r = model.simulate(gain: g, retention: a)
            print(String(format: "  %-10s  %.2f    %.3f     %4.0f ms   %4.0f ms   %.2fx",
                         (p.name as NSString).utf8String!, p.value, model.damping(forSpeed: p.value),
                         r.arrival * 1000, r.settle * 1000, r.arrival / stock.arrival))
        }

    case "daemon":
        Daemon().run()

    case "config":
        let config = Configuration.load()
        print("settings   \(Configuration.url.path)")
        print("  exists   \(FileManager.default.fileExists(atPath: Configuration.url.path))")
        print("  readable \(FileManager.default.isReadableFile(atPath: Configuration.url.path))")
        print("  enabled  \(config.enabled)")
        print(String(format: "  speed    %.4f", config.speed))
        print("  damping  \(config.damping.map { String(format: "%.4f", $0) } ?? "automatic")")
        print("  refresh  \(config.lastKnownRefreshHz.map { String(format: "%.0f Hz", $0) } ?? "unrecorded")")
        print("")
        print("helper     \(HelperInstall.plistURL.path)")
        print("  installed \(HelperInstall.isInstalled)")
        if let live = HelperStatus.load() {
            print(String(format: "  reported  speed %.4f damping %.4f on Dock %d",
                         live.speed, live.damping, live.dockPID))
            print("  updated   \(live.updatedAt)")
            if let error = live.error { print("  error     \(error)") }
        } else {
            print("  reported  nothing yet")
        }

    case "status":
        emit(try Engine(refreshHz: refreshArg).status(), json: json)

    case "revert":
        let engine = try Engine(refreshHz: refreshArg)
        try engine.revert()
        var config = Configuration.load()
        config.enabled = false
        try? config.save()
        print("Reverted. Dock is running Apple's stock animation again.")

    case "install":
        try HelperInstall.install()
        var config = Configuration.load()
        config.enabled = true
        if let speed = speedArg { config.speed = speed }
        config.damping = dampingArg
        config.lastKnownRefreshHz = refreshArg ?? Display.mainRefreshRate()
        try config.save()
        print("""
            Helper installed. It reapplies your setting whenever Dock restarts, \
            including at login.

              settings   \(Configuration.url.path)
              helper     \(HelperInstall.executableURL.path)
              job        \(HelperInstall.plistURL.path)

            Remove it with `sudo spaceswitch uninstall`.
            """)

    case "uninstall":
        var config = Configuration.load()
        config.enabled = false
        try? config.save()
        if let engine = try? Engine(refreshHz: refreshArg) { try? engine.revert() }
        try HelperInstall.uninstall()
        print("Helper removed and Dock restored to stock.")

    default:
        guard let speed = speedArg else {
            emit(try Engine(refreshHz: refreshArg).status(), json: json)
            exit(0)
        }
        guard Speed.range.contains(speed) else {
            fail(String(format: "speed must be between %.1f and %.1f", Speed.range.lowerBound, Speed.range.upperBound))
        }
        if dryRun {
            let model = SpringModel(dt: 1 / (refreshArg ?? Display.mainRefreshRate()))
            let (g, a) = model.coefficients(speed: speed, damping: dampingArg)
            let r = model.simulate(gain: g, retention: a)
            let s = model.simulate(gain: SpringModel.stockGain, retention: SpringModel.stockRetention)
            print(String(format: "speed %.2f  damping %.3f  ->  gain %.6f  retention %.6f",
                         speed, dampingArg ?? model.damping(forSpeed: speed), g, a))
            print(String(format: "arrives in %.0f ms (stock %.0f ms, %.2fx), settles %.0f ms, overshoot %.1f%%",
                         r.arrival * 1000, s.arrival * 1000, r.arrival / s.arrival, r.settle * 1000, r.overshoot * 100))
            exit(0)
        }
        let engine = try Engine(refreshHz: refreshArg)
        let status = try engine.apply(speed: speed, damping: dampingArg)
        var config = Configuration.load()
        config.enabled = true
        config.speed = speed
        config.damping = dampingArg
        config.lastKnownRefreshHz = status.refreshHz
        try? config.save()
        emit(status, json: json)
    }
} catch let error as SpaceSwitchError {
    fail(error.description)
} catch {
    fail("\(error)")
}

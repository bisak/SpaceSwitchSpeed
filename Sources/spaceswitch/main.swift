// SpaceSwitch — speed control for the macOS Space-switch animation.
// Copyright (C) 2026 Biser Atanasov. Licensed under AGPL-3.0-or-later.
// See LICENSE. This program comes with ABSOLUTELY NO WARRANTY.

import Darwin
import Foundation
import SpaceSwitchKit

let usage = """
    SpaceSwitch — speed control for the macOS Space-switch animation

    USAGE
      spaceswitch <speed>
      spaceswitch status | presets | revert | install | uninstall

    ARGUMENTS
      <speed>       0.2 – 1.0, a multiplier on the stock pace. 1.0 is exactly
                    what macOS ships; lower is faster. Takes a preset name too:
                    \(Speed.presets.map { $0.name.lowercased() }.joined(separator: ", "))

    COMMANDS
      status        Show the saved setting, and with sudo what Dock is running.
      presets       List the presets and how long each takes.
      revert        Restore Apple's constants. `killall Dock` also works.
      install       Install the helper, so the setting survives restarts.
      uninstall     Remove the helper and everything it wrote, and revert.

    Writing to Dock needs System Integrity Protection disabled and root
    privileges. See the README for what that means and how to weigh it.
    """

// MARK: - Arguments

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("spaceswitch: \(message)\n".utf8))
    exit(1)
}

var speedArg: Double?
var ownerPath: String?
var command = "apply"

var arguments = Array(CommandLine.arguments.dropFirst())
var index = 0
while index < arguments.count {
    let argument = arguments[index]
    switch argument {
    case "--help", "-h":
        print(usage)
        exit(0)
    case "status", "presets", "revert", "install", "uninstall", "daemon":
        command = argument
    // Recorded by `install` so the helper can tell when its app has gone.
    case "--owner":
        index += 1
        guard index < arguments.count else { fail("--owner needs a path") }
        ownerPath = arguments[index]
    default:
        if let value = Double(argument) {
            speedArg = value
        } else if let value = Speed.presets.first(where: {
            $0.name.lowercased() == argument.lowercased()
        })?.value {
            speedArg = value
        } else {
            fail("unrecognised argument '\(argument)'. Try --help.")
        }
    }
    index += 1
}

// MARK: - Reporting

func describe(_ status: Status) -> String {
    let response = status.response, stock = status.stockResponse
    return """
        \(status.applied
            ? "SpaceSwitch is active on Dock (pid \(status.dockPID))."
            : "Dock is running Apple's stock animation (pid \(status.dockPID)).")

          speed        \(String(format: "%.2f", status.speed)) of stock
          arrives in   \(String(format: "%.0f ms", response.arrival * 1000)) \
        (stock \(String(format: "%.0f ms", stock.arrival * 1000)))
          settles in   \(String(format: "%.0f ms", response.settle * 1000))
          gain \(String(format: "%.6f", status.gain))  \
        retention \(String(format: "%.6f", status.retention))
        """
}

// MARK: - Commands

do {
    switch command {
    case "daemon":
        Daemon(owner: ownerPath.map { URL(fileURLWithPath: $0) }).run()

    case "presets":
        let model = SpringModel()
        let stock = model.simulate(gain: SpringModel.stockGain, retention: SpringModel.stockRetention)
        print("  preset      speed   arrives   settles   vs stock")
        for preset in Speed.presets {
            let (gain, retention) = model.coefficients(speed: preset.value)
            let response = model.simulate(gain: gain, retention: retention)
            // %-10@ does not pad in Foundation; pad the string itself.
            print(
                String(
                    format: "  %@  %.2f   %4.0f ms   %4.0f ms   %.2fx",
                    preset.name.padding(toLength: 9, withPad: " ", startingAt: 0), preset.value,
                    response.arrival * 1000, response.settle * 1000,
                    response.arrival / stock.arrival))
        }

    case "status":
        let saved = Configuration.load()
        print("settings   \(Configuration.url.path)")
        print("  speed    \(String(format: "%.2f", saved.speed))\(saved.enabled ? "" : "  (off)")")
        print("  restarts \(HelperInstall.isInstalled ? "reapplied automatically" : "not reapplied")")
        if let live = HelperStatus.load() {
            print(
                "  helper   \(live.error ?? "applied \(String(format: "%.2f", live.speed)) to Dock \(live.dockPID)")"
            )
        }
        print("")
        if let engine = try? Engine() {
            print(describe(try engine.status()))
        } else {
            print("Run with sudo to read Dock directly.")
        }

    case "revert":
        try Engine().revert()
        var config = Configuration.load()
        config.enabled = false
        try? config.save()
        print("Reverted. Dock is running Apple's stock animation again.")

    case "install":
        try HelperInstall.install()
        var config = Configuration.load()
        config.enabled = true
        if let speed = speedArg { config.speed = speed }
        try config.save()
        print("Installed. Your setting is reapplied whenever Dock restarts.")

    case "uninstall":
        var config = Configuration.load()
        config.enabled = false
        try? config.save()
        if let engine = try? Engine() { try? engine.revert() }
        try HelperInstall.uninstall()
        print("Removed. Dock is back to stock and nothing is left in /Library.")

    default:
        guard let speed = speedArg else {
            print(usage)
            exit(0)
        }
        guard Speed.range.contains(speed) else {
            fail(
                String(
                    format: "speed must be between %.1f and %.1f",
                    Speed.range.lowerBound, Speed.range.upperBound))
        }
        let status = try Engine().apply(speed: speed)
        var config = Configuration.load()
        config.enabled = true
        config.speed = speed
        try? config.save()
        print(describe(status))
    }
} catch let error as SpaceSwitchError {
    fail(error.description)
} catch {
    fail("\(error)")
}

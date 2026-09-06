// Space Switch Speed — speed control for the macOS Space-switch animation.
// Copyright (C) 2026 Biser Atanasov. Licensed under AGPL-3.0-or-later.
// See LICENSE. This program comes with ABSOLUTELY NO WARRANTY.

// The app's privileged helper: the app runs it with administrator privileges to
// install or remove the LaunchDaemon, or to save a setting on behalf of a
// standard account, and launchd runs it as that daemon.

import Darwin
import Foundation
import SpaceSwitchSpeedKit

let usage = "usage: spaceswitchspeed install <speed> | set <speed> | uninstall | daemon [--owner <app>]"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("spaceswitchspeed: \(message)\n".utf8))
    exit(1)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    print(usage)
    exit(0)
}

do {
    switch command {
    case "daemon":
        let rest = arguments.dropFirst()
        guard rest.isEmpty || (rest.count == 2 && rest.first == "--owner") else { fail(usage) }
        Daemon(owner: rest.last).run()

    case "install", "set":
        guard arguments.count == 2, let speed = Double(arguments[1]) else { fail(usage) }
        guard Speed.range.contains(speed) else {
            fail(
                String(
                    format: "speed must be between %.1f and %.1f",
                    Speed.range.lowerBound, Speed.range.upperBound))
        }
        if command == "install" { try HelperInstall.install() }
        try Configuration(speed: speed).save()

    case "uninstall":
        guard arguments.count == 1 else { fail(usage) }
        Engine.revertAll()
        try HelperInstall.uninstall()

    default:
        fail(usage)
    }
} catch let error as SpaceSwitchSpeedError {
    fail(error.description)
} catch {
    fail("\(error)")
}

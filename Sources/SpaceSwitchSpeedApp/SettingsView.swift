// SpaceSwitchSpeed — speed control for the macOS Space-switch animation.
// Copyright (C) 2026 Biser Atanasov. Licensed under AGPL-3.0-or-later.
// See LICENSE. This program comes with ABSOLUTELY NO WARRANTY.

import SpaceSwitchSpeedKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var controller: Controller

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Switching speed")
                Spacer()
                Text(controller.preset.name)
                    .foregroundStyle(.secondary)
            }

            Slider(
                value: $controller.stop,
                in: 0...Double(Speed.presets.count - 1),
                step: 1
            ) {
                Text("Switching speed")
            } minimumValueLabel: {
                Image(systemName: "tortoise.fill").foregroundStyle(.secondary)
            } maximumValueLabel: {
                Image(systemName: "hare.fill").foregroundStyle(.secondary)
            } onEditingChanged: { editing in
                if !editing { controller.commit() }
            }
            .labelsHidden()
            .disabled(!controller.isEditable)

            if let note = controller.note {
                NoteView(note: note, openLoginItems: controller.openLoginItems)
            }
        }
        .padding(20)
        .confirmationDialog(
            "Remove SpaceSwitchSpeed?", isPresented: $controller.confirmingRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) { controller.removeEverything() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Space switching goes back to normal and nothing is left behind. SpaceSwitchSpeed will quit, and you can move it to the Trash."
            )
        }
    }
}

/// The window says nothing at all unless something needs the user's attention.
private struct NoteView: View {
    static let sipHelp = URL(
        string: "https://github.com/bisak/spaceswitchspeed#disabling-system-integrity-protection")!

    let note: Controller.Note
    let openLoginItems: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .imageScale(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(message)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if case .needsSIPDisabled = note {
                    Link("Learn More…", destination: NoteView.sipHelp)
                }
                if case .switchedOff = note {
                    Button("Open Login Items…", action: openLoginItems).buttonStyle(.link)
                }
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(.top, 2)
    }

    private var message: String {
        switch note {
        case .needsSIPDisabled: return "Requires System Integrity Protection to be turned off."
        case .switchedOff: return "SpaceSwitchSpeed is switched off under Login Items."
        case .failed(let text), .helperFailed(let text): return text
        }
    }
}

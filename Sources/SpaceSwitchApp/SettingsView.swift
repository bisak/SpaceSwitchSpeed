// SpaceSwitch — speed control for the macOS Space-switch animation.
// Copyright (C) 2026 Biser Atanasov. Licensed under AGPL-3.0-or-later.
// See LICENSE. This program comes with ABSOLUTELY NO WARRANTY.

import SwiftUI
import SpaceSwitchKit

struct SettingsView: View {
    @ObservedObject var controller: Controller

    var body: some View {
        Form {
            Section {
                LabeledContent("Switching speed") {
                    VStack(alignment: .leading, spacing: 4) {
                        Slider(value: $controller.stop,
                               in: 0 ... Double(Speed.presets.count - 1),
                               step: 1) { editing in
                            if !editing { controller.commit() }
                        }
                        HStack {
                            Text(Speed.presets.first?.name ?? "")
                            Spacer()
                            Text(Speed.presets.last?.name ?? "")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .frame(width: 260)
                    .disabled(!controller.isEditable)
                    .padding(.vertical, 8)
                }
            } footer: {
                if let note = controller.note { NoteView(note: note) }
            }
        }
        .formStyle(.grouped)
    }
}

/// The window says nothing at all unless something needs the user's attention.
private struct NoteView: View {
    let note: Controller.Note

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .imageScale(.small)
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
            if case .needsSIPDisabled = note {
                Link("Learn More…", destination: URL(string: "https://github.com/bisak/spaceswitch#disabling-system-integrity-protection")!)
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.top, 2)
    }

    private var message: String {
        switch note {
        case .needsSIPDisabled: return "Requires System Integrity Protection to be turned off."
        case .failed(let text): return text
        }
    }
}

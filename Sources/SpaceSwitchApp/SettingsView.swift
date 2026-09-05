// SpaceSwitch — speed control for the macOS Space-switch animation.
// Copyright (C) 2026 Biser Atanasov. Licensed under AGPL-3.0-or-later.
// See LICENSE. This program comes with ABSOLUTELY NO WARRANTY.

import SwiftUI
import SpaceSwitchKit

struct SettingsView: View {
    @ObservedObject var controller: Controller
    @State private var showingOptions = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Switching speed") {
                    HStack(spacing: 10) {
                        // Tinting the whole row would override the slider's
                        // accent fill, so the glyphs are styled on their own.
                        Image(systemName: "tortoise.fill")
                            .foregroundStyle(.secondary)
                        SteppedSlider(value: $controller.stop,
                                      stops: Speed.presets.count) { controller.commit() }
                        Image(systemName: "hare.fill")
                            .foregroundStyle(.secondary)
                    }
                    .imageScale(.large)
                    .frame(width: 270)
                    .padding(.vertical, 4)
                    .disabled(!controller.isEditable)
                }
            } footer: {
                VStack(alignment: .leading, spacing: 10) {
                    if let note = controller.note { NoteView(note: note) }
                    HStack {
                        Spacer()
                        Button("Options…") { showingOptions = true }
                            .disabled(!controller.isEditable)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showingOptions) { OptionsSheet(controller: controller) }
    }
}

/// Damping, kept behind a button because changing it is a matter of taste and
/// the automatic value is right for almost everyone.
private struct OptionsSheet: View {
    @ObservedObject var controller: Controller
    @Environment(\.dismiss) private var dismiss

    @State private var automatic: Bool
    @State private var damping: Double

    init(controller: Controller) {
        self.controller = controller
        _automatic = State(initialValue: controller.damping == nil)
        _damping = State(initialValue: controller.effectiveDamping)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Toggle("Set damping automatically", isOn: $automatic)
                    LabeledContent("Damping") {
                        VStack(alignment: .leading, spacing: 4) {
                            Slider(value: $damping, in: 0.6 ... 1.6)
                            HStack {
                                Text("Springy")
                                Spacer()
                                Text("Smooth")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .frame(width: 240)
                        .disabled(automatic)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("OK") {
                    controller.setDamping(automatic ? nil : damping)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: automatic) { isAutomatic in
            if isAutomatic { damping = controller.model.damping(forSpeed: Speed.presets[Int(controller.stop)].value) }
        }
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

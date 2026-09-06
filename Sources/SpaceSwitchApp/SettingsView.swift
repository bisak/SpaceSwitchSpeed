// SpaceSwitch — speed control for the macOS Space-switch animation.
// Copyright (C) 2026 Biser Atanasov. Licensed under AGPL-3.0-or-later.
// See LICENSE. This program comes with ABSOLUTELY NO WARRANTY.

import SpaceSwitchKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var controller: Controller
    @State private var showingOptions = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Switching speed") {
                    // The value labels belong to the slider rather than to a
                    // stack around it, so the framework aligns them with the
                    // track instead of with the tick marks below it.
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
    @State private var runsAtLogin: Bool

    init(controller: Controller) {
        self.controller = controller
        _automatic = State(initialValue: controller.damping == nil)
        _damping = State(initialValue: controller.effectiveDamping)
        _runsAtLogin = State(initialValue: controller.runsAtLogin)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Toggle("Apply after restarting", isOn: $runsAtLogin)
                    Toggle("Set damping automatically", isOn: $automatic.animation(.default))
                    // Revealed rather than greyed out: a control the user
                    // cannot touch is worse than one that is not there.
                    if !automatic {
                        LabeledContent("Damping") {
                            VStack(alignment: .leading, spacing: 4) {
                                Slider(value: $damping, in: 0.6...1.6)
                                HStack {
                                    Text("Springy")
                                    Spacer()
                                    Text("Smooth")
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                            .frame(width: 240)
                        }
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
                    // Everything here commits together, so Cancel really cancels.
                    controller.setRunsAtLogin(runsAtLogin)
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
            if isAutomatic {
                damping = controller.model.damping(forSpeed: Speed.presets[Int(controller.stop)].value)
            }
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
                Link(
                    "Learn More…",
                    destination: URL(
                        string: "https://github.com/bisak/spaceswitch#disabling-system-integrity-protection")!
                )
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

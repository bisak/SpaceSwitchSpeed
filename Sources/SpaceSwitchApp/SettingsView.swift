// SpaceSwitch — speed control for the macOS Space-switch animation.
// Copyright (C) 2026 Biser Atanasov. Licensed under AGPL-3.0-or-later.
// See LICENSE. This program comes with ABSOLUTELY NO WARRANTY.

import SwiftUI
import SpaceSwitchKit

struct SettingsView: View {
    @ObservedObject var controller: Controller
    @State private var playToken = 0

    var body: some View {
        Form {
            Section { StatusBanner(controller: controller) }

            Section {
                LabeledContent("Speed") {
                    HStack(spacing: 10) {
                        Image(systemName: "tortoise.fill")
                            .foregroundStyle(.secondary)
                            .imageScale(.medium)
                        Slider(value: $controller.speed,
                               in: Speed.range.lowerBound ... Speed.range.upperBound) { editing in
                            if !editing { playToken += 1 }
                        }
                        .frame(minWidth: 190)
                        Image(systemName: "hare.fill")
                            .foregroundStyle(.secondary)
                            .imageScale(.medium)
                        Text(String(format: "%.2f×", controller.speed))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                Picker("Preset", selection: presetBinding) {
                    ForEach(Speed.presets, id: \.name) { Text($0.name).tag($0.name) }
                    Text("Custom").tag("Custom")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            } header: {
                Text("Space Switching")
            } footer: {
                footer(footerText)
            }

            Section("Preview") {
                SwitchPreview(trajectory: trajectory, dt: 1 / controller.refreshHz, playToken: $playToken)
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                HStack {
                    Button("Play Again") { playToken += 1 }
                    Spacer()
                    Text(timingSummary)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Toggle("Customise damping", isOn: $controller.usesCustomDamping)
                if controller.usesCustomDamping {
                    LabeledContent("Damping") {
                        HStack(spacing: 10) {
                            Slider(value: $controller.damping, in: 0.6 ... 1.6) { editing in
                                if !editing { playToken += 1 }
                            }
                            .frame(minWidth: 220)
                            Text(String(format: "%.2f", controller.damping))
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 40, alignment: .trailing)
                        }
                    }
                }
            } header: {
                Text("Advanced")
            } footer: {
                footer(controller.usesCustomDamping
                    ? "Below 1.00 the animation overshoots and springs back. 1.00 is the fastest arrival that cannot overshoot. Above 1.00 it eases into place."
                    : "Damping follows your display automatically: it starts at whatever macOS ships for \(Int(controller.refreshHz)) Hz and eases toward a crisper stop as you raise the speed.")
            }

            Section {
                Toggle("Apply automatically", isOn: $controller.enabled)
                helperRow
            } header: {
                Text("Startup")
            } footer: {
                footer("The setting lives in Dock's memory, so it is cleared whenever Dock restarts. The helper puts it back at login and after any restart.")
            }
        }
        .formStyle(.grouped)
        .onAppear { playToken += 1; controller.refresh() }
    }

    // MARK: - Pieces

    private func footer(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var helperRow: some View {
        LabeledContent("Helper") {
            HStack(spacing: 8) {
                if controller.busy {
                    ProgressView().controlSize(.small)
                    Text("Working…").foregroundStyle(.secondary)
                } else if controller.helperInstalled {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Installed")
                } else {
                    Text("Not installed").foregroundStyle(.secondary)
                }
                Spacer()
                if controller.helperInstalled {
                    Button("Remove…", role: .destructive) { controller.removeHelper() }
                        .disabled(controller.busy)
                } else {
                    Button("Install…") { controller.installHelper() }
                        .disabled(controller.busy || !controller.sipDisabled)
                }
            }
        }
    }

    // MARK: - Derived

    private var presetBinding: Binding<String> {
        Binding(
            get: { controller.presetName ?? "Custom" },
            set: { name in
                guard let preset = Speed.presets.first(where: { $0.name == name }) else { return }
                controller.speed = preset.value
                playToken += 1
            }
        )
    }

    private var trajectory: [Double] {
        let c = controller.coefficients
        return controller.model.trajectory(gain: c.gain, retention: c.retention)
    }

    private var footerText: String {
        let name = controller.presetName.map { "\($0) — " } ?? ""
        if abs(controller.speed - Speed.stock) < 0.005 {
            return "\(name)exactly what macOS ships on this \(Int(controller.refreshHz)) Hz display."
        }
        let factor = controller.stockResponse.arrival / controller.response.arrival
        return String(format: "%@about %.1f× faster than macOS ships on this %d Hz display.",
                      name, factor, Int(controller.refreshHz))
    }

    private var timingSummary: String {
        let r = controller.response
        return String(format: "arrives %.0f ms · settles %.0f ms · overshoot %.1f%%",
                      r.arrival * 1000, r.settle * 1000, r.overshoot * 100)
    }
}

/// Says plainly whether the settings below are actually on the machine. Without
/// this the window looks identical whether or not anything is being applied.
private struct StatusBanner: View {
    @ObservedObject var controller: Controller

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if action != nil {
                Button(actionTitle) { action?() }
                    .disabled(controller.busy)
            }
        }
        .padding(.vertical, 2)
    }

    private var icon: String {
        if !controller.sipDisabled { return "lock.shield" }
        if !controller.helperInstalled { return "exclamationmark.triangle.fill" }
        if controller.problem != nil || controller.live?.error != nil { return "xmark.octagon.fill" }
        if controller.isLive { return "checkmark.circle.fill" }
        return "arrow.triangle.2.circlepath"
    }

    private var tint: Color {
        if !controller.sipDisabled { return .orange }
        if !controller.helperInstalled { return .orange }
        if controller.problem != nil || controller.live?.error != nil { return .red }
        return controller.isLive ? .green : .secondary
    }

    private var title: String {
        if !controller.sipDisabled { return "System Integrity Protection is on" }
        if !controller.helperInstalled { return "Nothing is being applied yet" }
        if let error = controller.problem { return error }
        if controller.live?.error != nil { return "The helper could not apply your setting" }
        if !controller.enabled { return "Turned off — Dock is running Apple's animation" }
        if controller.isLive, let live = controller.live {
            return "Active on Dock (pid \(live.dockPID))"
        }
        return "Applying…"
    }

    private var detail: String {
        if !controller.sipDisabled {
            return "macOS will not let anything modify Dock while SIP is on, so SpaceSwitch cannot take effect. Turning it off is done from Recovery and is reversible — the README explains exactly what it costs."
        }
        if !controller.helperInstalled {
            return "The sliders below preview the animation, but changing Dock needs a privileged helper. Installing it asks for your password once."
        }
        if let error = controller.live?.error { return error }
        if !controller.enabled { return "Turn on Apply automatically to use your setting again." }
        if controller.isLive, let live = controller.live {
            return String(format: "Running at %.2f× with damping %.2f on a %.0f Hz display.",
                          live.speed, live.damping, live.refreshHz)
        }
        return "Waiting for the helper to pick up the change."
    }

    private var actionTitle: String { controller.helperInstalled ? "Recheck" : "Install…" }

    private var action: (() -> Void)? {
        if !controller.sipDisabled { return nil }
        if !controller.helperInstalled { return { controller.installHelper() } }
        return { controller.refresh() }
    }
}

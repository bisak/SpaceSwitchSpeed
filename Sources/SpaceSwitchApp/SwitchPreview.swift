// SpaceSwitch — speed control for the macOS Space-switch animation.
// Copyright (C) 2026 Biser Atanasov. Licensed under AGPL-3.0-or-later.
// See LICENSE. This program comes with ABSOLUTELY NO WARRANTY.

import SwiftUI
import SpaceSwitchKit

/// Replays the chosen spring so the setting can be judged by eye before it is
/// applied to the whole machine. Same integrator Dock runs, same timestep.
struct SwitchPreview: View {
    let trajectory: [Double]
    let dt: Double
    @Binding var playToken: Int

    @State private var startedAt = Date.distantPast
    @State private var isPlaying = false

    private var duration: Double { Double(trajectory.count) * dt }

    var body: some View {
        TimelineView(.animation(minimumInterval: dt, paused: !isPlaying)) { context in
            let step = Int(context.date.timeIntervalSince(startedAt) / dt)
            let position = trajectory.indices.contains(step) ? trajectory[step] : (trajectory.last ?? 0)

            GeometryReader { geometry in
                let w = geometry.size.width
                ZStack(alignment: .topLeading) {
                    panel(index: 0, label: "Desktop 1")
                        .frame(width: w)
                        .offset(x: -position * w)
                    panel(index: 1, label: "Desktop 2")
                        .frame(width: w)
                        .offset(x: (1 - position) * w)
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(.quaternary, lineWidth: 1)
                )
            }
        }
        .frame(height: 120)
        .onChange(of: playToken) { _ in play() }
        .onAppear { play() }
    }

    /// Runs the timeline only while there is motion to draw.
    private func play() {
        startedAt = Date()
        isPlaying = true
        let token = playToken
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.1) {
            if token == playToken { isPlaying = false }
        }
    }

    private func panel(index: Int, label: String) -> some View {
        let palette: [[Color]] = [
            [Color(red: 0.16, green: 0.24, blue: 0.42), Color(red: 0.31, green: 0.44, blue: 0.62)],
            [Color(red: 0.36, green: 0.22, blue: 0.36), Color(red: 0.60, green: 0.36, blue: 0.42)],
        ]
        return LinearGradient(colors: palette[index], startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay(alignment: .center) {
                Text(label)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
            }
            .overlay(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.white.opacity(0.18))
                    .frame(width: 96, height: 12)
                    .padding(.bottom, 10)
            }
    }
}

// SpaceSwitch — speed control for the macOS Space-switch animation.
// Copyright (C) 2026 Biser Atanasov. Licensed under AGPL-3.0-or-later.
// See LICENSE. This program comes with ABSOLUTELY NO WARRANTY.

import AppKit
import SwiftUI

/// A slider that snaps to a fixed number of stops and marks them underneath.
///
/// Neither stock control does this. SwiftUI's `Slider(step:)` and `NSSlider`
/// with `numberOfTickMarks` both select the tick-mark appearance: a rectangular
/// knob and a hairline track with the marks drawn across it. System Settings
/// uses a plain slider with its own marks below, so this does the same —
/// snapping in the action so the knob moves stop to stop while dragging, rather
/// than only on release as a rounded SwiftUI binding would.
@MainActor
final class SteppedSliderView: NSView {
    let slider: NSSlider
    private let stops: Int

    init(stops: Int, target: AnyObject, action: Selector) {
        self.stops = stops
        slider = NSSlider(value: 0, minValue: 0, maxValue: Double(stops - 1),
                          target: target, action: action)
        slider.isContinuous = true
        slider.controlSize = .regular
        super.init(frame: .zero)

        addSubview(slider)
        slider.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            slider.leadingAnchor.constraint(equalTo: leadingAnchor),
            slider.trailingAnchor.constraint(equalTo: trailingAnchor),
            slider.topAnchor.constraint(equalTo: topAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private var markSpacing: CGFloat { 5 }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric,
               height: slider.intrinsicContentSize.height + markSpacing)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard stops > 1 else { return }

        // The knob's centre never reaches the track ends; it stops half a knob
        // in. Marks have to follow that, not the view's full width.
        let inset = max(slider.knobThickness, 8) / 2
        let span = bounds.width - inset * 2
        let y = slider.intrinsicContentSize.height + markSpacing - 4
        let diameter: CGFloat = 3

        (isEnabled ? NSColor.tertiaryLabelColor : NSColor.quaternaryLabelColor).setFill()
        for index in 0 ..< stops {
            let x = inset + span * CGFloat(index) / CGFloat(stops - 1)
            NSBezierPath(ovalIn: NSRect(x: x - diameter / 2, y: y,
                                        width: diameter, height: diameter)).fill()
        }
    }

    var isEnabled: Bool {
        get { slider.isEnabled }
        set {
            guard slider.isEnabled != newValue else { return }
            slider.isEnabled = newValue
            needsDisplay = true
        }
    }
}

struct SteppedSlider: NSViewRepresentable {
    @Binding var value: Double
    let stops: Int
    var onCommit: () -> Void = {}

    func makeNSView(context: Context) -> SteppedSliderView {
        let view = SteppedSliderView(stops: stops,
                                     target: context.coordinator,
                                     action: #selector(Coordinator.changed(_:)))
        view.slider.doubleValue = value
        return view
    }

    func updateNSView(_ view: SteppedSliderView, context: Context) {
        context.coordinator.parent = self
        if view.slider.doubleValue != value { view.slider.doubleValue = value }
        view.isEnabled = context.environment.isEnabled
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    /// AppKit delivers control actions on the main thread. Saying so explicitly
    /// keeps this compiling under toolchains that do not infer it.
    @MainActor
    final class Coordinator: NSObject {
        var parent: SteppedSlider

        init(_ parent: SteppedSlider) { self.parent = parent }

        @objc func changed(_ sender: NSSlider) {
            let snapped = sender.doubleValue.rounded()
            // Writing it back is what makes the knob jump to the stop mid-drag.
            if sender.doubleValue != snapped { sender.doubleValue = snapped }
            if parent.value != snapped { parent.value = snapped }
            if NSApp.currentEvent?.type == .leftMouseUp { parent.onCommit() }
        }
    }
}

//
//  WaveformWindowView.swift
//  EEGView
//
//  Created by PJM on 3/19/26.
//  Heavily influenced by Codex on 3/19/26
//

import SwiftUI

struct WaveformWindowView: View {
    @Environment(WaveformSession.self) private var waveformSession

    @State private var amplitudeScale: Double = 100
    @State private var timeScale: Double = 1
    @State private var horizontalOffset: CGFloat = 0
    @State private var horizontalViewportWidth: CGFloat = 1
    @State private var horizontalScrollPosition = ScrollPosition(idType: Int.self, x: 0)
    @State private var horizontalJumpValue: Double = 0
    @State private var isSyncingSliderFromScroll = false

    private let sampleStride = 5
    private let channelRowHeight: CGFloat = 70
    private let eventTrackHeight: CGFloat = 64
    private let rowSpacing: CGFloat = 12
    private let labelColumnWidth: CGFloat = 120

    var body: some View {
        VStack(spacing: 0) {
            controls

            Divider()

            if let signal = waveformSession.signal {
                let plotWidth = plotWidth(for: signal)

                VStack(spacing: 0) {
                    HStack(alignment: .top, spacing: 12) {
                        eventLabelRow(for: signal)
                            .frame(width: labelColumnWidth, height: eventTrackHeight, alignment: .topLeading)

                        EventTrackView(
                            events: signal.events,
                            samplingRate: signal.samplingRate,
                            timeScale: timeScale,
                            sampleStride: sampleStride,
                            visibleRange: visibleHorizontalRange,
                            viewportWidth: horizontalViewportWidth
                        )
                        .frame(maxWidth: .infinity, minHeight: eventTrackHeight, maxHeight: eventTrackHeight)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
                    .padding(.bottom, 12)

                    ScrollView(.vertical) {
                        HStack(alignment: .top, spacing: 12) {
                            LazyVStack(alignment: .leading, spacing: rowSpacing) {
                                ForEach(Array(signal.data.enumerated()), id: \.offset) { index, _ in
                                    channelLabelRow(index: index)
                                }
                            }
                            .frame(width: labelColumnWidth, alignment: .topLeading)

                            ScrollView(.horizontal, showsIndicators: true) {
                                LazyVStack(alignment: .leading, spacing: rowSpacing) {
                                    ForEach(Array(signal.data.enumerated()), id: \.offset) { index, channel in
                                        WaveformPlot(
                                            samples: channel,
                                            amplitudeScale: amplitudeScale,
                                            timeScale: timeScale,
                                            sampleStride: sampleStride,
                                            visibleRange: visibleHorizontalRange
                                        )
                                        .frame(width: plotWidth, height: channelRowHeight)
                                        .background {
                                            RoundedRectangle(cornerRadius: 8)
                                                .fill(Color(nsColor: .controlBackgroundColor))
                                        }
                                        .overlay {
                                            RoundedRectangle(cornerRadius: 8)
                                                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
                                        }
                                        .accessibilityLabel("Channel \(index + 1)")
                                    }
                                }
                                .padding(.trailing, 20)
                            }
                            .scrollPosition($horizontalScrollPosition)
                            .scrollIndicators(.visible, axes: .horizontal)
                            .onScrollGeometryChange(
                                for: HorizontalViewport.self,
                                of: { geometry in
                                    HorizontalViewport(
                                        offsetX: geometry.contentOffset.x,
                                        width: geometry.containerSize.width
                                    )
                                },
                                action: { _, newValue in
                                    horizontalOffset = max(newValue.offsetX, 0)
                                    horizontalViewportWidth = max(newValue.width, 1)
                                    let maxOffset = max(plotWidth - horizontalViewportWidth, 0)
                                    isSyncingSliderFromScroll = true
                                    horizontalJumpValue = maxOffset > 0 ? Double(horizontalOffset / maxOffset) : 0
                                    isSyncingSliderFromScroll = false
                                }
                            )
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 16)
                    }

                    Divider()

                    HStack(spacing: 16) {
                        Text("Jump")
                            .font(.caption.weight(.semibold))
                            .frame(width: labelColumnWidth, alignment: .leading)

                        Slider(value: $horizontalJumpValue, in: 0...1)
                            .onChange(of: horizontalJumpValue) { _, newValue in
                                guard !isSyncingSliderFromScroll else {
                                    return
                                }

                                let maxOffset = max(plotWidth - horizontalViewportWidth, 0)
                                horizontalScrollPosition.scrollTo(x: CGFloat(newValue) * maxOffset)
                            }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(Color(nsColor: .windowBackgroundColor))
                }
                .background(Color(nsColor: .textBackgroundColor))
            } else {
                ContentUnavailableView(
                    "No Signal Loaded",
                    systemImage: "waveform",
                    description: Text("Load a signal file from the main window to open waveforms here.")
                )
            }
        }
        .navigationTitle("Waveforms")
    }

    private var controls: some View {
        HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Amplitude")
                    .font(.caption.weight(.semibold))
                HStack {
                    Slider(value: $amplitudeScale, in: 10...1000, step: 10)
                    Text("\(Int(amplitudeScale)) µV")
                        .monospacedDigit()
                        .frame(width: 80, alignment: .trailing)
                }
                .frame(width: 300)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Time Scale")
                    .font(.caption.weight(.semibold))
                HStack {
                    Slider(value: $timeScale, in: 0.2...8, step: 0.1)
                    Text(String(format: "%.1fx", timeScale))
                        .monospacedDigit()
                        .frame(width: 60, alignment: .trailing)
                }
                .frame(width: 260)
            }

            Text("Point Skip 1:5")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func eventLabelRow(for signal: MFFSignalData) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Events")
                .font(.system(.headline, design: .monospaced))

            if let recordingStartTime = signal.recordingStartTime {
                Text(recordingStartTime.formatted(date: .abbreviated, time: .standard))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("\(signal.events.count) markers")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func channelLabelRow(index: Int) -> some View {
        Text("Ch \(index + 1)")
            .font(.system(.body, design: .monospaced))
            .frame(maxWidth: .infinity, minHeight: channelRowHeight, alignment: .leading)
    }

    private func plotWidth(for signal: MFFSignalData) -> CGFloat {
        let sampleCount = signal.data.first?.count ?? 0
        let displayedPoints = max(sampleCount / sampleStride, 1)
        return max(CGFloat(displayedPoints) * CGFloat(timeScale), 600)
    }

    private var visibleHorizontalRange: ClosedRange<CGFloat> {
        let buffer = horizontalViewportWidth * 0.15
        let lower = max(horizontalOffset - buffer, 0)
        let upper = horizontalOffset + horizontalViewportWidth + buffer
        return lower...upper
    }
}

private struct EventTrackView: View {
    let events: [MFFEvent]
    let samplingRate: Double
    let timeScale: Double
    let sampleStride: Int
    let visibleRange: ClosedRange<CGFloat>
    let viewportWidth: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))

            Canvas { context, size in
                guard samplingRate > 0 else {
                    return
                }

                let baselineY = size.height - 16
                var baseline = Path()
                baseline.move(to: CGPoint(x: 0, y: baselineY))
                baseline.addLine(to: CGPoint(x: size.width, y: baselineY))
                context.stroke(baseline, with: .color(.secondary.opacity(0.3)), lineWidth: 1)

                for event in visibleEvents {
                    let x = localXPosition(for: event)
                    let style = style(for: event)
                    var marker = Path()
                    marker.move(to: CGPoint(x: x, y: style.stemTopY))
                    marker.addLine(to: CGPoint(x: x, y: baselineY))
                    context.stroke(marker, with: .color(style.color), lineWidth: 1)
                }
            }

            ForEach(visibleEvents) { event in
                let x = localXPosition(for: event)
                let style = style(for: event)
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.code)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(style.color.opacity(0.15), in: Capsule())

                    Text(String(format: "%.3fs", event.beginTimeSeconds))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(style.color)
                .offset(x: min(max(x + 4, 0), max(viewportWidth - 70, 0)), y: 4)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
        }
    }

    private var visibleEvents: [MFFEvent] {
        events.filter {
            let x = globalXPosition(for: $0)
            return visibleRange.contains(x)
        }
    }

    private func globalXPosition(for event: MFFEvent) -> CGFloat {
        guard samplingRate > 0 else {
            return 0
        }

        let sampleIndex = event.beginTimeSeconds * samplingRate
        let plottedIndex = sampleIndex / Double(sampleStride)
        return CGFloat(plottedIndex) * CGFloat(timeScale)
    }

    private func localXPosition(for event: MFFEvent) -> CGFloat {
        globalXPosition(for: event) - visibleRange.lowerBound
    }

    private func style(for event: MFFEvent) -> EventMarkerStyle {
        let sources = Array(Set(events.map(\.sourceFile))).sorted()
        let sourceIndex = sources.firstIndex(of: event.sourceFile) ?? 0
        let palette: [Color] = [
            .orange, .blue, .green, .red, .pink, .teal, .indigo, .brown
        ]

        return EventMarkerStyle(
            color: palette[sourceIndex % palette.count],
            stemTopY: 18 + CGFloat(sourceIndex % 3) * 10
        )
    }
}

private struct WaveformPlot: View {
    let samples: [Float]
    let amplitudeScale: Double
    let timeScale: Double
    let sampleStride: Int
    let visibleRange: ClosedRange<CGFloat>

    var body: some View {
        Canvas { context, size in
            guard samples.count > sampleStride else {
                return
            }

            let xScale = CGFloat(timeScale)
            let lowerVisibleIndex = max(Int(floor(visibleRange.lowerBound / max(xScale, 0.001))) - 2, 0)
            let upperVisibleIndex = Int(ceil(visibleRange.upperBound / max(xScale, 0.001))) + 2

            let firstSampleIndex = min(lowerVisibleIndex * sampleStride, samples.count - 1)
            let lastSampleIndex = min(max(upperVisibleIndex * sampleStride, firstSampleIndex + sampleStride), samples.count - 1)
            guard lastSampleIndex > firstSampleIndex else {
                return
            }

            let midY = size.height / 2
            let pointsPerMicrovolt = (size.height / 2) / max(amplitudeScale, 1)

            var path = Path()
            let firstPlottedIndex = firstSampleIndex / sampleStride
            path.move(
                to: CGPoint(
                    x: CGFloat(firstPlottedIndex) * xScale,
                    y: midY - CGFloat(samples[firstSampleIndex]) * pointsPerMicrovolt
                )
            )

            for sampleIndex in stride(from: firstSampleIndex + sampleStride, through: lastSampleIndex, by: sampleStride) {
                let plottedIndex = sampleIndex / sampleStride
                let point = CGPoint(
                    x: CGFloat(plottedIndex) * xScale,
                    y: midY - CGFloat(samples[sampleIndex]) * pointsPerMicrovolt
                )
                path.addLine(to: point)
            }

            var baseline = Path()
            baseline.move(to: CGPoint(x: visibleRange.lowerBound, y: midY))
            baseline.addLine(to: CGPoint(x: visibleRange.upperBound, y: midY))

            context.stroke(baseline, with: .color(.secondary.opacity(0.3)), lineWidth: 0.75)
            context.stroke(path, with: .color(.accentColor), lineWidth: 1)
        }
    }
}

private struct HorizontalViewport: Equatable {
    let offsetX: CGFloat
    let width: CGFloat
}

private struct EventMarkerStyle {
    let color: Color
    let stemTopY: CGFloat
}

#Preview {
    WaveformWindowView()
        .environment(WaveformSession())
}

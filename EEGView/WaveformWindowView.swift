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
    @State private var showsFilterPopover = false
    @State private var filterLowCutoff = 0.1
    @State private var filterHighCutoff = 30.0
    @State private var notch60HzEnabled = false
    @State private var horizontalOffset: CGFloat = 0
    @State private var horizontalViewportWidth: CGFloat = 1
    @State private var horizontalScrollPosition = ScrollPosition(idType: Int.self, x: 0)
    @State private var horizontalJumpValue: Double = 0
    @State private var isSyncingSliderFromScroll = false
    @State private var filteredSignal: MFFSignalData?
    @State private var isFiltering = false
    @State private var filterStatusMessage: String?
    @State private var showsEventsPanel = false
    @State private var selectedEventID: MFFEvent.ID?
    @State private var selectedEventCodes = Set<String>()
    @State private var showsECGDetectorPopover = false
    @State private var selectedECGMethods: Set<ECGDetectionMethod> = [.ica]
    @State private var icaPCAComponentCount = 10
    @State private var detectedECGEvents: [MFFEvent] = []
    @State private var isDetectingECG = false
    @State private var ecgDetectionStatusMessage: String?
    @State private var icaReview: ECGICAReview?
    @State private var selectedICAComponentIndex: Int?
    @State private var pendingDetectedECGEvents: [MFFEvent] = []

    private let sampleStride = 5
    private let channelRowHeight: CGFloat = 70
    private let channelOverflowHeight: CGFloat = 28
    private let eventTrackHeight: CGFloat = 64
    private let rowSpacing: CGFloat = 12
    private let labelColumnWidth: CGFloat = 120
    private let eventsPanelWidth: CGFloat = 300

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                controls

                Divider()

                if let signal = displayedSignal {
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
                                        channelLabelRow(index: index, for: signal)
                                    }
                                }
                                .frame(width: labelColumnWidth, alignment: .topLeading)

                                ScrollView(.horizontal, showsIndicators: true) {
                                    LazyVStack(alignment: .leading, spacing: rowSpacing) {
                                        ForEach(Array(signal.data.enumerated()), id: \.offset) { index, channel in
                                            waveformRow(
                                                index: index,
                                                channel: channel,
                                                plotWidth: plotWidth,
                                                signal: signal
                                            )
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

            if showsEventsPanel, let signal = displayedSignal {
                Divider()
                eventsPanel(for: signal)
                    .frame(width: eventsPanelWidth)
                    .background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .navigationTitle("Waveforms")
        .onChange(of: waveformSession.signal?.signalURL) { _, _ in
            filteredSignal = nil
            isFiltering = false
            filterStatusMessage = nil
            selectedEventID = nil
            selectedEventCodes = []
            detectedECGEvents = []
            isDetectingECG = false
            ecgDetectionStatusMessage = nil
            icaReview = nil
            selectedICAComponentIndex = nil
            pendingDetectedECGEvents = []
        }
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

            if let signal = waveformSession.signal {
                Button(filteredSignal == nil ? "Filter" : "Show Unfiltered") {
                    if filteredSignal == nil {
                        showsFilterPopover.toggle()
                    } else {
                        clearBandpassFilter()
                    }
                }
                .popover(isPresented: $showsFilterPopover, arrowEdge: .bottom) {
                    filterPopover(for: signal)
                }
                .disabled(isFiltering)

                if isFiltering {
                    ProgressView()
                        .controlSize(.small)
                    Text("Filtering…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if filteredSignal != nil {
                    Text("Butterworth \(filterLowCutoff, specifier: "%.1f")-\(filterHighCutoff, specifier: "%.1f") Hz\(notch60HzEnabled ? " + 60 Hz notch" : "")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button(detectedECGEvents.isEmpty ? "Detect ECG" : "Redetect ECG") {
                    showsECGDetectorPopover.toggle()
                }
                .popover(isPresented: $showsECGDetectorPopover, arrowEdge: .bottom) {
                    ecgDetectionPopover(for: signal)
                }
                .disabled(isDetectingECG || icaReview != nil)

                if isDetectingECG {
                    ProgressView()
                        .controlSize(.small)
                    Text("Detecting ECG…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if !detectedECGEvents.isEmpty {
                    Text("\(detectedECGEvents.count) ECG markers")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let icaReview {
                    Text("ICA review: \(icaReview.components.count) components")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button("Confirm ICA Component") {
                        confirmICASelection()
                    }
                    .disabled(selectedICAComponentIndex == nil)

                    Button("Cancel ICA Review") {
                        cancelICAReview()
                    }
                }

                Button(showsEventsPanel ? "Hide Events" : "Show Events") {
                    showsEventsPanel.toggle()
                }
                .disabled(displayedSignal?.events.isEmpty ?? true)
            }

            if let filterStatusMessage {
                Text(filterStatusMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }

            if let ecgDetectionStatusMessage {
                Text(ecgDetectionStatusMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }

            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var displayedSignal: MFFSignalData? {
        if let icaReview {
            return icaReview.signal
        }

        let baseSignal = filteredSignal ?? waveformSession.signal
        guard let baseSignal else {
            return nil
        }

        guard !detectedECGEvents.isEmpty else {
            return baseSignal
        }

        return MFFSignalData(
            signalURL: baseSignal.signalURL,
            signalType: baseSignal.signalType,
            numberOfChannels: baseSignal.numberOfChannels,
            samplingRate: baseSignal.samplingRate,
            duration: baseSignal.duration,
            recordingStartTime: baseSignal.recordingStartTime,
            events: (baseSignal.events + detectedECGEvents)
                .sorted { $0.beginTimeSeconds < $1.beginTimeSeconds },
            data: baseSignal.data
        )
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

    private func ecgDetectionPopover(for signal: MFFSignalData) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("ECG Detection")
                .font(.headline)

            ForEach(ECGDetectionMethod.allCases) { method in
                Toggle(isOn: Binding(
                    get: { selectedECGMethods.contains(method) },
                    set: { isSelected in
                        if isSelected {
                            selectedECGMethods.insert(method)
                        } else {
                            selectedECGMethods.remove(method)
                        }
                    }
                )) {
                    Text(method.title)
                }
                .toggleStyle(.checkbox)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("ICA PCA Components")
                    .font(.caption.weight(.semibold))
                Stepper(value: $icaPCAComponentCount, in: 2...32) {
                    Text("\(icaPCAComponentCount) components")
                        .foregroundStyle(selectedECGMethods.contains(.ica) ? .primary : .secondary)
                }
                .disabled(!selectedECGMethods.contains(.ica))
            }

            HStack {
                Button("Clear ECG") {
                    detectedECGEvents = []
                    pendingDetectedECGEvents = []
                    icaReview = nil
                    selectedICAComponentIndex = nil
                    ecgDetectionStatusMessage = nil
                    showsECGDetectorPopover = false
                }
                .disabled(detectedECGEvents.isEmpty && pendingDetectedECGEvents.isEmpty && icaReview == nil && ecgDetectionStatusMessage == nil)

                Spacer()

                Button("Run Detection") {
                    detectECG(in: signal)
                    showsECGDetectorPopover = false
                }
                .disabled(selectedECGMethods.isEmpty || isDetectingECG)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 280)
    }

    private func filterPopover(for signal: MFFSignalData) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Band-pass Filter")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                Text("Low Cutoff (Hz)")
                    .font(.caption.weight(.semibold))
                HStack {
                    TextField("Low", value: $filterLowCutoff, format: .number.precision(.fractionLength(1)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                    Stepper("", value: $filterLowCutoff, in: 0.1...100, step: 0.1)
                        .labelsHidden()
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("High Cutoff (Hz)")
                    .font(.caption.weight(.semibold))
                HStack {
                    TextField("High", value: $filterHighCutoff, format: .number.precision(.fractionLength(1)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                    Stepper("", value: $filterHighCutoff, in: 0.5...200, step: 0.5)
                        .labelsHidden()
                }
            }

            Toggle("Apply 60 Hz IIR notch", isOn: $notch60HzEnabled)

            HStack {
                Button("Reset 0.1-30 Hz") {
                    filterLowCutoff = 0.1
                    filterHighCutoff = 30
                    notch60HzEnabled = false
                }

                Spacer()

                Button("Apply Filter") {
                    applyBandpassFilter(to: signal)
                    showsFilterPopover = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    private func channelLabelRow(index: Int, for signal: MFFSignalData) -> some View {
        Text(channelTitle(for: index, signal: signal))
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

    @ViewBuilder
    private func eventsPanel(for signal: MFFSignalData) -> some View {
        let eventSummaries = groupedEventSummaries(for: signal)
        let visibleEvents = filteredEvents(for: signal)

        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Events")
                        .font(.headline)
                    Text("\(visibleEvents.count) of \(signal.events.count) markers")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 10)

            if !eventSummaries.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Button {
                            selectedEventCodes.removeAll()
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("All Events")
                                    .font(.caption.weight(.semibold))
                                Text("\(signal.events.count)")
                                    .font(.caption2)
                            }
                            .foregroundStyle(selectedEventCodes.isEmpty ? Color.accentColor : .primary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(
                                Capsule()
                                    .fill(selectedEventCodes.isEmpty ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08))
                            )
                        }
                        .buttonStyle(.plain)

                        ForEach(eventSummaries) { summary in
                            let isSelected = selectedEventCodes.contains(summary.code)

                            Button {
                                toggleEventCode(summary.code)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(summary.code)
                                        .font(.caption.weight(.semibold))
                                        .lineLimit(1)
                                    Text("\(summary.count)")
                                        .font(.caption2)
                                }
                                .foregroundStyle(isSelected ? Color.accentColor : .primary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(
                                    Capsule()
                                        .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08))
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                }
            }

            Divider()

            if signal.events.isEmpty {
                ContentUnavailableView(
                    "No Events",
                    systemImage: "list.bullet.rectangle",
                    description: Text("This signal does not include any event markers.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(visibleEvents) { event in
                    Button {
                        jumpToEvent(event, in: signal)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(event.code)
                                .font(.system(.body, design: .monospaced).weight(.semibold))
                                .foregroundStyle(.primary)
                            Text(formattedEventTime(event.beginTimeSeconds))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(event.sourceFile)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(
                        selectedEventID == event.id
                            ? Color.accentColor.opacity(0.14)
                            : Color.clear
                    )
                }
                .listStyle(.sidebar)
            }
        }
    }

    private func applyBandpassFilter(to signal: MFFSignalData) {
        isFiltering = true
        filterStatusMessage = nil

        let signalURL = signal.signalURL
        let signalType = signal.signalType
        let numberOfChannels = signal.numberOfChannels
        let samplingRate = signal.samplingRate
        let duration = signal.duration
        let recordingStartTime = signal.recordingStartTime
        let events = signal.events
        let sourceData = signal.data
        let lowCutoff = filterLowCutoff
        let highCutoff = filterHighCutoff
        let notch60HzEnabled = notch60HzEnabled

        Task {
            do {
                let filteredData = try await Task.detached(priority: .userInitiated) {
                    try await EEGSignalFilter.bandPass(
                        channels: sourceData,
                        samplingRate: samplingRate,
                        lowCutoff: lowCutoff,
                        highCutoff: highCutoff,
                        notch60HzEnabled: notch60HzEnabled
                    )
                }.value

                guard waveformSession.signal?.signalURL == signalURL else {
                    return
                }

                filteredSignal = MFFSignalData(
                    signalURL: signalURL,
                    signalType: signalType,
                    numberOfChannels: numberOfChannels,
                    samplingRate: samplingRate,
                    duration: duration,
                    recordingStartTime: recordingStartTime,
                    events: events,
                    data: filteredData
                )
            } catch {
                filterStatusMessage = error.localizedDescription
            }

            isFiltering = false
        }
    }

    private func clearBandpassFilter() {
        filteredSignal = nil
        filterStatusMessage = nil
    }

    private func detectECG(in signal: MFFSignalData) {
        isDetectingECG = true
        ecgDetectionStatusMessage = nil

        let signalURL = signal.signalURL
        let selectedMethods = selectedECGMethods

        Task {
            do {
                ecgDetectionStatusMessage = "Starting ECG detection…"
                let result = try await ECGDetect.runDetection(
                    in: signal,
                    methods: selectedMethods,
                    icaPCAComponentCount: icaPCAComponentCount,
                    statusUpdate: { message in
                        await MainActor.run {
                            ecgDetectionStatusMessage = message
                        }
                    }
                )

                guard displayedSignal?.signalURL == signalURL || waveformSession.signal?.signalURL == signalURL else {
                    return
                }

                pendingDetectedECGEvents = result.directEvents

                if let icaReview = result.icaReview {
                    self.icaReview = icaReview
                    selectedICAComponentIndex = icaReview.suggestedComponentIndex
                    detectedECGEvents = []
                } else {
                    detectedECGEvents = result.directEvents
                    pendingDetectedECGEvents = []
                }

                if result.directEvents.isEmpty && result.icaReview == nil {
                    ecgDetectionStatusMessage = "No ECG peaks were detected with the selected methods."
                } else {
                    ecgDetectionStatusMessage = result.icaReview == nil ? "ECG detection complete." : "ICA review ready. Select a component and confirm."
                }
            } catch {
                detectedECGEvents = []
                pendingDetectedECGEvents = []
                icaReview = nil
                selectedICAComponentIndex = nil
                ecgDetectionStatusMessage = error.localizedDescription
            }

            isDetectingECG = false
        }
    }

    private func confirmICASelection() {
        guard let icaReview, let selectedICAComponentIndex else {
            return
        }

        let icaEvents = icaReview.components[selectedICAComponentIndex].detectedEvents
        detectedECGEvents = (pendingDetectedECGEvents + icaEvents)
            .sorted { $0.beginTimeSeconds < $1.beginTimeSeconds }
        pendingDetectedECGEvents = []
        self.icaReview = nil
        self.selectedICAComponentIndex = nil
        ecgDetectionStatusMessage = detectedECGEvents.isEmpty
            ? "No ECG peaks were detected from the selected ICA component."
            : nil
    }

    private func cancelICAReview() {
        icaReview = nil
        selectedICAComponentIndex = nil
        pendingDetectedECGEvents = []
        ecgDetectionStatusMessage = nil
    }

    @ViewBuilder
    private func waveformRow(
        index: Int,
        channel: [Float],
        plotWidth: CGFloat,
        signal: MFFSignalData
    ) -> some View {
        let isSelectedICAComponent = icaReview != nil && selectedICAComponentIndex == index

        WaveformPlot(
            samples: channel,
            amplitudeScale: amplitudeScale,
            timeScale: timeScale,
            sampleStride: sampleStride,
            visibleRange: visibleHorizontalRange,
            nominalHeight: channelRowHeight
        )
        .frame(width: plotWidth, height: channelRowHeight + (channelOverflowHeight * 2))
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
                .frame(width: plotWidth, height: channelRowHeight)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(
                    isSelectedICAComponent ? Color.accentColor : Color.secondary.opacity(0.15),
                    lineWidth: isSelectedICAComponent ? 2 : 1
                )
                .frame(width: plotWidth, height: channelRowHeight)
        }
        .frame(width: plotWidth, height: channelRowHeight)
        .contentShape(Rectangle())
        .onTapGesture {
            guard icaReview != nil else {
                return
            }
            selectedICAComponentIndex = index
        }
        .accessibilityLabel(channelTitle(for: index, signal: signal))
        .zIndex(1)
    }

    private func channelTitle(for index: Int, signal: MFFSignalData) -> String {
        if icaReview != nil || signal.signalType == "ICA" {
            return "IC \(index + 1)"
        }

        return "Ch \(index + 1)"
    }

    private func jumpToEvent(_ event: MFFEvent, in signal: MFFSignalData) {
        selectedEventID = event.id

        let plotWidth = plotWidth(for: signal)
        let plottedIndex = event.beginTimeSeconds * signal.samplingRate / Double(sampleStride)
        let targetX = CGFloat(plottedIndex) * CGFloat(timeScale)
        let viewportCenter = max(horizontalViewportWidth / 2, 1)
        let maxOffset = max(plotWidth - horizontalViewportWidth, 0)
        let clampedOffset = min(max(targetX - viewportCenter, 0), maxOffset)

        isSyncingSliderFromScroll = true
        horizontalJumpValue = maxOffset > 0 ? Double(clampedOffset / maxOffset) : 0
        isSyncingSliderFromScroll = false
        horizontalScrollPosition.scrollTo(x: clampedOffset)
    }

    private func formattedEventTime(_ seconds: Double) -> String {
        if seconds >= 60 {
            let minutes = Int(seconds) / 60
            let remainingSeconds = seconds.truncatingRemainder(dividingBy: 60)
            return String(format: "%d:%06.3f", minutes, remainingSeconds)
        }

        return String(format: "%.3fs", seconds)
    }

    private func groupedEventSummaries(for signal: MFFSignalData) -> [EventSummary] {
        Dictionary(grouping: signal.events, by: \.code)
            .map { code, events in
                EventSummary(code: code, count: events.count)
            }
            .sorted { lhs, rhs in
                if lhs.count == rhs.count {
                    return lhs.code.localizedStandardCompare(rhs.code) == .orderedAscending
                }
                return lhs.count > rhs.count
            }
    }

    private func filteredEvents(for signal: MFFSignalData) -> [MFFEvent] {
        guard !selectedEventCodes.isEmpty else {
            return signal.events
        }

        return signal.events.filter { selectedEventCodes.contains($0.code) }
    }

    private func toggleEventCode(_ code: String) {
        if selectedEventCodes.contains(code) {
            selectedEventCodes.remove(code)
        } else {
            selectedEventCodes.insert(code)
        }
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
    let nominalHeight: CGFloat

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
            let pointsPerMicrovolt = (nominalHeight / 2) / max(amplitudeScale, 1)

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

private struct EventSummary: Identifiable {
    let code: String
    let count: Int

    var id: String { code }
}

#Preview {
    WaveformWindowView()
        .environment(WaveformSession())
}

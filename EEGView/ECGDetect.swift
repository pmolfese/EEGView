//
//  ECGDetect.swift
//  EEGView
//
//  Created by Codex on 3/19/26.
//

import Foundation

enum ECGDetectionMethod: String, CaseIterable, Hashable, Identifiable {
    case crossChannelCorrelation
    case ecgPeakDetection
    case ica

    var id: String { rawValue }

    nonisolated var title: String {
        switch self {
        case .crossChannelCorrelation:
            return "Cross-channel correlation"
        case .ecgPeakDetection:
            return "ECG Peak Detection"
        case .ica:
            return "ICA"
        }
    }

    nonisolated var sourceLabel: String {
        switch self {
        case .crossChannelCorrelation:
            return "ECGDetect-CrossChannel"
        case .ecgPeakDetection:
            return "ECGDetect-Peak"
        case .ica:
            return "ECGDetect-ICA"
        }
    }
}

enum ECGDetectError: LocalizedError {
    case noMethodsSelected
    case insufficientSamplingRate
    case emptySignal
    case decompositionFailed

    var errorDescription: String? {
        switch self {
        case .noMethodsSelected:
            return "Select at least one ECG detection method."
        case .insufficientSamplingRate:
            return "The sampling rate is too low for ECG detection."
        case .emptySignal:
            return "The signal does not contain enough samples for ECG detection."
        case .decompositionFailed:
            return "ICA decomposition could not be completed for this signal."
        }
    }
}

struct ECGDetect {
    static func runDetection(
        in signal: MFFSignalData,
        methods: Set<ECGDetectionMethod>,
        icaPCAComponentCount: Int = 10,
        statusUpdate: @escaping @Sendable (String) async -> Void = { _ in }
    ) async throws -> ECGDetectionRunResult {
        try await Task.detached(priority: .userInitiated) {
            guard !methods.isEmpty else {
                throw ECGDetectError.noMethodsSelected
            }
            guard signal.samplingRate >= 25 else {
                throw ECGDetectError.insufficientSamplingRate
            }
            guard let sampleCount = signal.data.first?.count, sampleCount > 8 else {
                throw ECGDetectError.emptySignal
            }

            await statusUpdate("Preparing ECG detection…")

            let directMethods = methods.subtracting([.ica])
            async let directEvents = detectEvents(
                in: signal,
                methods: directMethods
            )
            async let icaReview = methods.contains(.ica)
                ? detectICAReview(
                    in: signal,
                    pcaComponentCount: icaPCAComponentCount,
                    statusUpdate: statusUpdate
                )
                : nil

            let result = try await ECGDetectionRunResult(
                directEvents: directEvents,
                icaReview: icaReview
            )

            await statusUpdate("Finalizing ECG detection…")
            return result
        }.value
    }

    static func detectEvents(
        in signal: MFFSignalData,
        methods: Set<ECGDetectionMethod>
    ) async throws -> [MFFEvent] {
        guard !methods.isEmpty else {
            return []
        }

        let detections = try await withThrowingTaskGroup(of: [ECGDetection].self) { group in
            for method in methods {
                group.addTask {
                    switch method {
                    case .crossChannelCorrelation:
                        return try await detectCrossChannelCorrelation(in: signal)
                    case .ecgPeakDetection:
                        return try await detectPeakBased(in: signal)
                    case .ica:
                        return []
                    }
                }
            }

            var combined: [ECGDetection] = []
            for try await partial in group {
                combined.append(contentsOf: partial)
            }
            return combined
        }

        return mergeDetections(detections, samplingRate: signal.samplingRate)
    }

    private static func detectICAReview(
        in signal: MFFSignalData,
        pcaComponentCount: Int,
        statusUpdate: @escaping @Sendable (String) async -> Void
    ) async throws -> ECGICAReview {
        await statusUpdate("Downsampling for ICA…")
        let preparedSignal = downsampleForICA(signal, targetSamplingRate: 250)
        await statusUpdate("Filtering channels for ICA…")
        let filteredChannels = try await EEGSignalFilter.bandPass(
            channels: preparedSignal.data,
            samplingRate: preparedSignal.samplingRate,
            lowCutoff: 1,
            highCutoff: min(40, (preparedSignal.samplingRate / 2) - 1)
        )

        let centered = center(filteredChannels)
        guard !centered.isEmpty else {
            throw ECGDetectError.decompositionFailed
        }

        await statusUpdate("Computing PCA basis…")
        let covariance = covarianceMatrix(for: centered)
        let decomposition = jacobiEigenDecomposition(of: covariance)
        let clampedPCAComponentCount = max(2, pcaComponentCount)
        let validEigenPairs = Array(
            decomposition
            .filter { $0.value > 1e-5 }
            .sorted { $0.value > $1.value }
            .prefix(clampedPCAComponentCount)
        )

        guard !validEigenPairs.isEmpty else {
            throw ECGDetectError.decompositionFailed
        }

        await statusUpdate("Running ICA on \(validEigenPairs.count) PCA components…")
        let whitening = whiteningMatrix(from: validEigenPairs)
        let whitened = apply(matrix: whitening, toChannels: centered)
        let components = fastICA(whitened)
        guard !components.isEmpty else {
            throw ECGDetectError.decompositionFailed
        }

        await statusUpdate("Scoring ICA components for ECG-like activity…")
        let componentReviews = try await withThrowingTaskGroup(of: ECGICAComponentReview.self) { group in
            for (index, component) in components.enumerated() {
                group.addTask {
                    let normalized = normalize(component)
                    let derivative = firstDifference(normalized)
                    let squared = derivative.map { $0 * $0 }
                    let integrated = movingAverage(
                        squared,
                        windowLength: max(Int(preparedSignal.samplingRate * 0.12), 1)
                    )
                    let peaks = detectPeaks(
                        in: integrated,
                        samplingRate: preparedSignal.samplingRate,
                        thresholdScale: 1.1,
                        refractorySeconds: 0.32
                    )
                    let events = peaks.enumerated().map { peakIndex, sampleIndex in
                        let onset = Double(sampleIndex) / preparedSignal.samplingRate
                        return MFFEvent(
                            id: "ECG|ICA|\(index)|\(peakIndex)|\(sampleIndex)",
                            code: "ECG",
                            beginTimeSeconds: onset,
                            rawBeginTime: String(format: "%.6f", onset),
                            sourceFile: ECGDetectionMethod.ica.sourceLabel
                        )
                    }

                    return ECGICAComponentReview(
                        index: index,
                        samples: component,
                        detectedEvents: events,
                        score: ecgScore(for: normalized, peaks: peaks)
                    )
                }
            }

            var reviews: [ECGICAComponentReview] = []
            for try await review in group {
                reviews.append(review)
            }
            return reviews
        }
        .sorted { lhs, rhs in
            if lhs.score == rhs.score {
                return lhs.index < rhs.index
            }
            return lhs.score > rhs.score
        }

        let reorderedComponents = componentReviews.map { $0.samples }
        let reorderedReviews = componentReviews.enumerated().map { orderIndex, review in
            ECGICAComponentReview(
                index: orderIndex,
                samples: review.samples,
                detectedEvents: review.detectedEvents.map { event in
                    MFFEvent(
                        id: event.id.replacingOccurrences(of: "|\(review.index)|", with: "|\(orderIndex)|"),
                        code: event.code,
                        beginTimeSeconds: event.beginTimeSeconds,
                        rawBeginTime: event.rawBeginTime,
                        sourceFile: event.sourceFile
                    )
                },
                score: review.score
            )
        }

        return ECGICAReview(
            signal: MFFSignalData(
                signalURL: preparedSignal.signalURL,
                signalType: "ICA",
                numberOfChannels: reorderedComponents.count,
                samplingRate: preparedSignal.samplingRate,
                duration: preparedSignal.duration,
                recordingStartTime: preparedSignal.recordingStartTime,
                events: preparedSignal.events,
                data: reorderedComponents
            ),
            components: reorderedReviews,
            suggestedComponentIndex: reorderedReviews.indices.max { lhs, rhs in
                reorderedReviews[lhs].score < reorderedReviews[rhs].score
            }
        )
    }

    private static func detectPeakBased(in signal: MFFSignalData) async throws -> [ECGDetection] {
        let filteredChannels = try await EEGSignalFilter.bandPass(
            channels: signal.data,
            samplingRate: signal.samplingRate,
            lowCutoff: 5,
            highCutoff: 18
        )

        guard let channel = bestPeakChannel(from: filteredChannels) else {
            return []
        }

        let derivative = firstDifference(channel)
        let squared = derivative.map { $0 * $0 }
        let windowLength = max(Int(signal.samplingRate * 0.12), 1)
        let integrated = movingAverage(squared, windowLength: windowLength)
        let peaks = detectPeaks(
            in: integrated,
            samplingRate: signal.samplingRate,
            thresholdScale: 1.2,
            refractorySeconds: 0.32
        )

        return peaks.map {
            ECGDetection(sampleIndex: $0, method: .ecgPeakDetection)
        }
    }

    private static func detectCrossChannelCorrelation(in signal: MFFSignalData) async throws -> [ECGDetection] {
        let filteredChannels = try await EEGSignalFilter.bandPass(
            channels: signal.data,
            samplingRate: signal.samplingRate,
            lowCutoff: 8,
            highCutoff: 20
        )

        let normalized = filteredChannels.map(normalize)
        guard !normalized.isEmpty, let sampleCount = normalized.first?.count, sampleCount > 8 else {
            return []
        }

        var consensus = Array(repeating: Float(0), count: sampleCount)
        for index in 0..<sampleCount {
            let slice = normalized.map { $0[index] }
            let mean = slice.reduce(0, +) / Float(slice.count)
            let energy = slice.reduce(0) { partial, value in
                partial + abs(value - mean)
            } / Float(slice.count)
            consensus[index] = abs(mean) / max(energy, 0.25)
        }

        let smoothed = movingAverage(consensus, windowLength: max(Int(signal.samplingRate * 0.04), 1))
        let peaks = detectPeaks(
            in: smoothed,
            samplingRate: signal.samplingRate,
            thresholdScale: 1.0,
            refractorySeconds: 0.3
        )

        return peaks.map {
            ECGDetection(sampleIndex: $0, method: .crossChannelCorrelation)
        }
    }

    private static func mergeDetections(_ detections: [ECGDetection], samplingRate: Double) -> [MFFEvent] {
        guard !detections.isEmpty else {
            return []
        }

        let sorted = detections.sorted { $0.sampleIndex < $1.sampleIndex }
        let mergeDistance = max(Int(samplingRate * 0.2), 1)

        var merged: [[ECGDetection]] = []
        for detection in sorted {
            if let lastIndex = merged.indices.last,
               let lastSampleIndex = merged[lastIndex].last?.sampleIndex,
               detection.sampleIndex - lastSampleIndex <= mergeDistance {
                merged[lastIndex].append(detection)
            } else {
                merged.append([detection])
            }
        }

        return merged.enumerated().map { clusterIndex, cluster in
            let sampleIndex = cluster.map(\.sampleIndex).reduce(0, +) / max(cluster.count, 1)
            let onset = Double(sampleIndex) / samplingRate
            let methods = Array(Set(cluster.map(\.method.sourceLabel))).sorted().joined(separator: "+")

            return MFFEvent(
                id: "ECG|\(sampleIndex)|\(methods)|\(clusterIndex)",
                code: "ECG",
                beginTimeSeconds: onset,
                rawBeginTime: String(format: "%.6f", onset),
                sourceFile: methods
            )
        }
    }

    private static func bestPeakChannel(from channels: [[Float]]) -> [Float]? {
        channels.max { lhs, rhs in
            channelProminence(lhs) < channelProminence(rhs)
        }
    }

    private static func channelProminence(_ channel: [Float]) -> Float {
        guard !channel.isEmpty else {
            return 0
        }

        let normalized = normalize(channel)
        let peak = normalized.map(abs).max() ?? 0
        let meanAbsolute = normalized.reduce(0) { $0 + abs($1) } / Float(normalized.count)
        return peak - meanAbsolute
    }

    private nonisolated static func normalize(_ samples: [Float]) -> [Float] {
        guard !samples.isEmpty else {
            return samples
        }

        let mean = samples.reduce(0, +) / Float(samples.count)
        let variance = samples.reduce(0) { partial, value in
            let centered = value - mean
            return partial + (centered * centered)
        } / Float(samples.count)
        let std = sqrt(max(variance, 1e-6))

        return samples.map { ($0 - mean) / std }
    }

    private nonisolated static func firstDifference(_ samples: [Float]) -> [Float] {
        guard samples.count > 1 else {
            return samples
        }

        var result = Array(repeating: Float(0), count: samples.count)
        for index in 1..<samples.count {
            result[index] = samples[index] - samples[index - 1]
        }
        return result
    }

    private nonisolated static func movingAverage(_ samples: [Float], windowLength: Int) -> [Float] {
        guard !samples.isEmpty, windowLength > 1 else {
            return samples
        }

        var result = Array(repeating: Float(0), count: samples.count)
        var runningSum: Float = 0

        for index in samples.indices {
            runningSum += samples[index]
            if index >= windowLength {
                runningSum -= samples[index - windowLength]
            }

            let currentLength = min(index + 1, windowLength)
            result[index] = runningSum / Float(currentLength)
        }

        return result
    }

    private nonisolated static func detectPeaks(
        in samples: [Float],
        samplingRate: Double,
        thresholdScale: Float,
        refractorySeconds: Double
    ) -> [Int] {
        guard samples.count > 2 else {
            return []
        }

        let mean = samples.reduce(0, +) / Float(samples.count)
        let variance = samples.reduce(0) { partial, value in
            let centered = value - mean
            return partial + (centered * centered)
        } / Float(samples.count)
        let threshold = mean + sqrt(max(variance, 1e-6)) * thresholdScale
        let refractorySamples = max(Int(refractorySeconds * samplingRate), 1)

        var peaks: [Int] = []
        var lastAcceptedPeak = -refractorySamples

        for index in 1..<(samples.count - 1) {
            let current = samples[index]
            guard current >= threshold,
                  current >= samples[index - 1],
                  current > samples[index + 1] else {
                continue
            }

            if index - lastAcceptedPeak < refractorySamples {
                if let lastPeakIndex = peaks.indices.last, current > samples[peaks[lastPeakIndex]] {
                    peaks[lastPeakIndex] = index
                    lastAcceptedPeak = index
                }
            } else {
                peaks.append(index)
                lastAcceptedPeak = index
            }
        }

        return peaks
    }

    private static func center(_ channels: [[Float]]) -> [[Float]] {
        channels.map { channel in
            guard !channel.isEmpty else {
                return channel
            }
            let mean = channel.reduce(0, +) / Float(channel.count)
            return channel.map { $0 - mean }
        }
    }

    private static func covarianceMatrix(for channels: [[Float]]) -> [[Float]] {
        let componentCount = channels.count
        let sampleCount = max(channels.first?.count ?? 1, 1)
        var covariance = Array(
            repeating: Array(repeating: Float(0), count: componentCount),
            count: componentCount
        )

        for row in 0..<componentCount {
            for column in row..<componentCount {
                var sum: Float = 0
                for sampleIndex in 0..<sampleCount {
                    sum += channels[row][sampleIndex] * channels[column][sampleIndex]
                }
                let value = sum / Float(sampleCount)
                covariance[row][column] = value
                covariance[column][row] = value
            }
        }

        return covariance
    }

    private static func jacobiEigenDecomposition(of matrix: [[Float]]) -> [(value: Float, vector: [Float])] {
        let size = matrix.count
        guard size > 0 else {
            return []
        }

        var a = matrix
        var v = identityMatrix(size: size)
        let maxIterations = size * size * 8

        for _ in 0..<maxIterations {
            var p = 0
            var q = 1
            var maxValue = abs(a[p][q])

            for row in 0..<size {
                for column in (row + 1)..<size {
                    let value = abs(a[row][column])
                    if value > maxValue {
                        maxValue = value
                        p = row
                        q = column
                    }
                }
            }

            if maxValue < 1e-5 {
                break
            }

            let theta = 0.5 * atan2(2 * a[p][q], a[q][q] - a[p][p])
            let cosine = cos(theta)
            let sine = sin(theta)

            let app = a[p][p]
            let aqq = a[q][q]
            let apq = a[p][q]
            a[p][p] = (cosine * cosine * app) - (2 * sine * cosine * apq) + (sine * sine * aqq)
            a[q][q] = (sine * sine * app) + (2 * sine * cosine * apq) + (cosine * cosine * aqq)
            a[p][q] = 0
            a[q][p] = 0

            for index in 0..<size where index != p && index != q {
                let aip = a[index][p]
                let aiq = a[index][q]
                a[index][p] = (cosine * aip) - (sine * aiq)
                a[p][index] = a[index][p]
                a[index][q] = (sine * aip) + (cosine * aiq)
                a[q][index] = a[index][q]
            }

            for index in 0..<size {
                let vip = v[index][p]
                let viq = v[index][q]
                v[index][p] = (cosine * vip) - (sine * viq)
                v[index][q] = (sine * vip) + (cosine * viq)
            }
        }

        return (0..<size).map { index in
            let vector = (0..<size).map { v[$0][index] }
            return (a[index][index], vector)
        }
    }

    private static func whiteningMatrix(from eigenPairs: [(value: Float, vector: [Float])]) -> [[Float]] {
        eigenPairs.map { eigenPair in
            let scale = 1 / sqrt(max(eigenPair.value, 1e-6))
            return eigenPair.vector.map { $0 * scale }
        }
    }

    private static func apply(matrix: [[Float]], toChannels channels: [[Float]]) -> [[Float]] {
        guard let sampleCount = channels.first?.count else {
            return []
        }

        return matrix.map { row in
            var output = Array(repeating: Float(0), count: sampleCount)
            for sampleIndex in 0..<sampleCount {
                var sum: Float = 0
                for channelIndex in channels.indices {
                    sum += row[channelIndex] * channels[channelIndex][sampleIndex]
                }
                output[sampleIndex] = sum
            }
            return output
        }
    }

    private static func fastICA(_ whitened: [[Float]]) -> [[Float]] {
        let componentCount = whitened.count
        guard let sampleCount = whitened.first?.count, componentCount > 0, sampleCount > 0 else {
            return []
        }

        var unmixing: [[Float]] = []
        for componentIndex in 0..<componentCount {
            var weight = Array(repeating: Float(0), count: componentCount)
            weight[componentIndex] = 1
            weight = normalizeVector(weight)

            for _ in 0..<80 {
                let projection = project(whitened, with: weight)
                let g = projection.map(tanh)
                let gPrimeMean = g.reduce(0) { partial, value in
                    partial + (1 - (value * value))
                } / Float(sampleCount)

                var updated = Array(repeating: Float(0), count: componentCount)
                for row in 0..<componentCount {
                    var sum: Float = 0
                    for sampleIndex in 0..<sampleCount {
                        sum += whitened[row][sampleIndex] * g[sampleIndex]
                    }
                    updated[row] = (sum / Float(sampleCount)) - (gPrimeMean * weight[row])
                }

                for previous in unmixing {
                    let projectionValue = dot(updated, previous)
                    for index in updated.indices {
                        updated[index] -= projectionValue * previous[index]
                    }
                }

                updated = normalizeVector(updated)
                let similarity = abs(dot(updated, weight))
                weight = updated

                if 1 - similarity < 1e-4 {
                    break
                }
            }

            unmixing.append(weight)
        }

        return unmixing.map { project(whitened, with: $0) }
    }

    private static func project(_ channels: [[Float]], with weights: [Float]) -> [Float] {
        guard let sampleCount = channels.first?.count else {
            return []
        }

        var result = Array(repeating: Float(0), count: sampleCount)
        for sampleIndex in 0..<sampleCount {
            var sum: Float = 0
            for channelIndex in channels.indices {
                sum += weights[channelIndex] * channels[channelIndex][sampleIndex]
            }
            result[sampleIndex] = sum
        }
        return result
    }

    private static func normalizeVector(_ vector: [Float]) -> [Float] {
        let norm = sqrt(max(vector.reduce(0) { $0 + ($1 * $1) }, 1e-6))
        return vector.map { $0 / norm }
    }

    private static func dot(_ lhs: [Float], _ rhs: [Float]) -> Float {
        zip(lhs, rhs).reduce(0) { $0 + ($1.0 * $1.1) }
    }

    private static func identityMatrix(size: Int) -> [[Float]] {
        (0..<size).map { row in
            (0..<size).map { column in
                row == column ? 1 : 0
            }
        }
    }

    private nonisolated static func ecgScore(for samples: [Float], peaks: [Int]) -> Float {
        guard !samples.isEmpty else {
            return 0
        }

        let peakProminence = peaks.map { abs(samples[$0]) }.reduce(0, +) / Float(max(peaks.count, 1))
        let sparsity = peakProminence / max(samples.map(abs).reduce(0, +) / Float(samples.count), 1e-3)
        let beatDensityPenalty = abs(Float(peaks.count) - Float(samples.count) / 250) * 0.001
        return sparsity - beatDensityPenalty
    }

    private static func downsampleForICA(_ signal: MFFSignalData, targetSamplingRate: Double) -> MFFSignalData {
        guard signal.samplingRate > targetSamplingRate else {
            return signal
        }

        var factor = max(Int(floor(signal.samplingRate / targetSamplingRate)), 1)
        while factor > 1, signal.samplingRate / Double(factor) < 200 {
            factor -= 1
        }

        guard factor > 1 else {
            return signal
        }

        let downsampledData = signal.data.map { channel in
            stride(from: 0, to: channel.count, by: factor).map { channel[$0] }
        }
        let downsampledRate = signal.samplingRate / Double(factor)

        return MFFSignalData(
            signalURL: signal.signalURL,
            signalType: signal.signalType,
            numberOfChannels: signal.numberOfChannels,
            samplingRate: downsampledRate,
            duration: signal.duration,
            recordingStartTime: signal.recordingStartTime,
            events: signal.events,
            data: downsampledData
        )
    }
}

struct ECGDetectionRunResult {
    let directEvents: [MFFEvent]
    let icaReview: ECGICAReview?
}

struct ECGICAReview {
    let signal: MFFSignalData
    let components: [ECGICAComponentReview]
    let suggestedComponentIndex: Int?
}

struct ECGICAComponentReview: Identifiable {
    let index: Int
    let samples: [Float]
    let detectedEvents: [MFFEvent]
    let score: Float

    var id: Int { index }
}

private struct ECGDetection {
    let sampleIndex: Int
    let method: ECGDetectionMethod
}

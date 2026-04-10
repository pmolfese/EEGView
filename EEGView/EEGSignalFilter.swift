//
//  EEGSignalFilter.swift
//  EEGView
//
//  Created by Codex on 3/19/26.
//

import Foundation

enum EEGSignalFilterError: LocalizedError {
    case invalidSamplingRate
    case invalidBandpassRange

    var errorDescription: String? {
        switch self {
        case .invalidSamplingRate:
            return "The signal sampling rate is invalid for filtering."
        case .invalidBandpassRange:
            return "The 0.1-30 Hz filter range is not valid for this signal."
        }
    }
}

struct EEGSignalFilter {
    private nonisolated static let butterworthQ: Float = 1.0 / Float(sqrt(2.0))

    nonisolated static func bandPass(
        channels: [[Float]],
        samplingRate: Double,
        lowCutoff: Double,
        highCutoff: Double,
        notch60HzEnabled: Bool = false
    ) async throws -> [[Float]] {
        guard samplingRate > 0 else {
            throw EEGSignalFilterError.invalidSamplingRate
        }

        let nyquist = samplingRate / 2
        guard lowCutoff > 0, highCutoff > lowCutoff, highCutoff < nyquist else {
            throw EEGSignalFilterError.invalidBandpassRange
        }

        return try await withThrowingTaskGroup(of: (Int, [Float]).self) { group in
            let highPass = BiquadCoefficients.highPass(
                cutoff: Float(lowCutoff),
                samplingRate: Float(samplingRate),
                q: butterworthQ
            )
            let lowPass = BiquadCoefficients.lowPass(
                cutoff: Float(highCutoff),
                samplingRate: Float(samplingRate),
                q: butterworthQ
            )
            let notchFilter = BiquadCoefficients.notch(
                centerFrequency: 60,
                samplingRate: Float(samplingRate),
                q: 30
            )

            for (index, channel) in channels.enumerated() {
                group.addTask {
                    let highPassed = zeroPhaseFilter(channel, coefficients: highPass)
                    let bandPassed = zeroPhaseFilter(highPassed, coefficients: lowPass)
                    let finalSamples: [Float]

                    if notch60HzEnabled, 60 < (samplingRate / 2) {
                        finalSamples = zeroPhaseFilter(bandPassed, coefficients: notchFilter)
                    } else {
                        finalSamples = bandPassed
                    }

                    return (index, finalSamples)
                }
            }

            var filteredChannels = Array(repeating: [Float](), count: channels.count)
            for try await (index, filteredChannel) in group {
                filteredChannels[index] = filteredChannel
            }

            return filteredChannels
        }
    }

    private nonisolated static func zeroPhaseFilter(_ samples: [Float], coefficients: BiquadCoefficients) -> [Float] {
        guard samples.count > 6 else {
            return samples
        }

        let paddingCount = min(24, samples.count - 1)
        let paddedSamples = reflectedPadding(for: samples, count: paddingCount)
        let forward = applyBiquad(to: paddedSamples, coefficients: coefficients)
        let backward = applyBiquad(to: Array(forward.reversed()), coefficients: coefficients)
        let restored = Array(backward.reversed())

        guard paddingCount > 0, restored.count > paddingCount * 2 else {
            return restored
        }

        return Array(restored[paddingCount..<(restored.count - paddingCount)])
    }

    private nonisolated static func reflectedPadding(for samples: [Float], count: Int) -> [Float] {
        guard count > 0, samples.count > 1 else {
            return samples
        }

        let prefix = Array(samples[1...count].reversed())
        let suffixStart = samples.count - count - 1
        let suffix = Array(samples[suffixStart..<(samples.count - 1)].reversed())
        return prefix + samples + suffix
    }

    private nonisolated static func applyBiquad(to samples: [Float], coefficients: BiquadCoefficients) -> [Float] {
        var filtered: [Float] = []
        filtered.reserveCapacity(samples.count)

        var x1: Float = 0
        var x2: Float = 0
        var y1: Float = 0
        var y2: Float = 0

        for x0 in samples {
            let y0 = coefficients.b0 * x0
                + coefficients.b1 * x1
                + coefficients.b2 * x2
                - coefficients.a1 * y1
                - coefficients.a2 * y2
            filtered.append(y0)
            x2 = x1
            x1 = x0
            y2 = y1
            y1 = y0
        }

        return filtered
    }
}

private struct BiquadCoefficients {
    let b0: Float
    let b1: Float
    let b2: Float
    let a1: Float
    let a2: Float

    nonisolated static func lowPass(cutoff: Float, samplingRate: Float, q: Float) -> Self {
        let omega = 2 * Float.pi * cutoff / samplingRate
        let cosine = cos(omega)
        let alpha = sin(omega) / (2 * q)

        let b0 = (1 - cosine) / 2
        let b1 = 1 - cosine
        let b2 = (1 - cosine) / 2
        let a0 = 1 + alpha
        let a1 = -2 * cosine
        let a2 = 1 - alpha

        return normalize(b0: b0, b1: b1, b2: b2, a0: a0, a1: a1, a2: a2)
    }

    nonisolated static func highPass(cutoff: Float, samplingRate: Float, q: Float) -> Self {
        let omega = 2 * Float.pi * cutoff / samplingRate
        let cosine = cos(omega)
        let alpha = sin(omega) / (2 * q)

        let b0 = (1 + cosine) / 2
        let b1 = -(1 + cosine)
        let b2 = (1 + cosine) / 2
        let a0 = 1 + alpha
        let a1 = -2 * cosine
        let a2 = 1 - alpha

        return normalize(b0: b0, b1: b1, b2: b2, a0: a0, a1: a1, a2: a2)
    }

    nonisolated static func notch(centerFrequency: Float, samplingRate: Float, q: Float) -> Self {
        let omega = 2 * Float.pi * centerFrequency / samplingRate
        let cosine = cos(omega)
        let alpha = sin(omega) / (2 * q)

        let b0: Float = 1
        let b1 = -2 * cosine
        let b2: Float = 1
        let a0 = 1 + alpha
        let a1 = -2 * cosine
        let a2 = 1 - alpha

        return normalize(b0: b0, b1: b1, b2: b2, a0: a0, a1: a1, a2: a2)
    }

    private nonisolated static func normalize(
        b0: Float,
        b1: Float,
        b2: Float,
        a0: Float,
        a1: Float,
        a2: Float
    ) -> Self {
        Self(
            b0: b0 / a0,
            b1: b1 / a0,
            b2: b2 / a0,
            a1: a1 / a0,
            a2: a2 / a0
        )
    }
}

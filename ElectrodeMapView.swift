//
//  ElectrodeMapView.swift
//  EEGView
//
//  Created by Claude on 4/10/26.
//

import SwiftUI

struct ElectrodeLocation {
    let label: String
    let x: Double
    let y: Double
    let z: Double
}

struct ElectrodeMapView: View {
    let signal: MFFSignalData
    let sampleIndex: Int
    var onSelectChannel: ((Int) -> Void)?

    @State private var electrodes: [ElectrodeLocation] = []
    @State private var hoveredElectrode: String?

    private let headPadding: CGFloat = 24
    private let electrodeRadius: CGFloat = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if electrodes.isEmpty {
                ContentUnavailableView(
                    "No Layout",
                    systemImage: "brain.head.profile",
                    description: Text("No electrode layout found for \(signal.numberOfChannels) channels.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { geometry in
                    let size = min(geometry.size.width - headPadding * 2, geometry.size.height - headPadding * 2 - 40)
                    let mapSize = max(size, 100)
                    VStack(spacing: 0) {
                        topoMap(size: mapSize)
                            .frame(width: mapSize, height: mapSize)
                        voltageList
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
        }
        .onAppear { loadElectrodes() }
        .onChange(of: signal.numberOfChannels) { _, _ in loadElectrodes() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Topography")
                .font(.headline)
            let timeSeconds = Double(sampleIndex) / signal.samplingRate
            Text(String(format: "Sample %d (%.3fs)", sampleIndex, timeSeconds))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("\(signal.numberOfChannels) channels")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func topoMap(size: CGFloat) -> some View {
        Canvas { context, canvasSize in
            let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
            let radius = size / 2 - 8

            // Draw head outline
            let headCircle = Path(ellipseIn: CGRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2
            ))
            context.stroke(headCircle, with: .color(.secondary.opacity(0.4)), lineWidth: 1.5)

            // Draw nose indicator
            var nose = Path()
            nose.move(to: CGPoint(x: center.x - 8, y: center.y - radius))
            nose.addLine(to: CGPoint(x: center.x, y: center.y - radius - 10))
            nose.addLine(to: CGPoint(x: center.x + 8, y: center.y - radius))
            context.stroke(nose, with: .color(.secondary.opacity(0.4)), lineWidth: 1.5)

            // Draw electrodes
            let positions = projectedPositions(radius: radius, center: center)
            let voltages = voltagesAtSample()

            for (i, pos) in positions.enumerated() {
                let voltage = i < voltages.count ? voltages[i] : 0
                let color = colorForVoltage(voltage)

                let rect = CGRect(
                    x: pos.x - electrodeRadius,
                    y: pos.y - electrodeRadius,
                    width: electrodeRadius * 2,
                    height: electrodeRadius * 2
                )
                context.fill(Path(ellipseIn: rect), with: .color(color))
                context.stroke(Path(ellipseIn: rect), with: .color(.primary.opacity(0.3)), lineWidth: 0.5)
            }
        }
        .padding(headPadding)
    }

    private var voltageList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                let voltages = voltagesAtSample()
                ForEach(Array(electrodes.enumerated()), id: \.offset) { index, electrode in
                    let voltage = index < voltages.count ? voltages[index] : 0
                    Button {
                        onSelectChannel?(index)
                    } label: {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(colorForVoltage(voltage))
                                .frame(width: 8, height: 8)
                            Text(electrode.label)
                                .font(.system(.caption, design: .monospaced))
                                .frame(width: 40, alignment: .leading)
                            Text(String(format: "%.2f µV", voltage))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 8)
        }
    }

    private func voltagesAtSample() -> [Float] {
        guard sampleIndex >= 0 else { return [] }
        return signal.data.map { channel in
            sampleIndex < channel.count ? channel[sampleIndex] : 0
        }
    }

    private func projectedPositions(radius: CGFloat, center: CGPoint) -> [CGPoint] {
        // Project 3D electrode positions to 2D using azimuthal equidistant projection
        // x = left/right, y = anterior/posterior, z = superior/inferior
        guard !electrodes.isEmpty else { return [] }

        // Compute polar angles for all electrodes
        let thetas: [Double] = electrodes.map { electrode in
            let r3d = sqrt(electrode.x * electrode.x + electrode.y * electrode.y + electrode.z * electrode.z)
            guard r3d > 0 else { return 0 }
            return acos(max(min(electrode.z / r3d, 1), -1))
        }

        // Normalize by the maximum theta so outermost electrodes reach the circle edge
        let maxTheta = thetas.max() ?? .pi
        let normalizer = maxTheta > 0 ? maxTheta : .pi

        return electrodes.enumerated().map { i, electrode in
            let r3d = sqrt(electrode.x * electrode.x + electrode.y * electrode.y + electrode.z * electrode.z)
            guard r3d > 0 else { return center }

            let theta = thetas[i]
            let phi = atan2(-electrode.x, electrode.y) // azimuthal angle (negate x so left is left)

            // Scale so the outermost electrode sits at the circle edge (with small inset for the dot)
            let projRadius = (theta / normalizer) * (radius - electrodeRadius)

            let px = center.x + CGFloat(projRadius * sin(phi))
            let py = center.y - CGFloat(projRadius * cos(phi))
            return CGPoint(x: px, y: py)
        }
    }

    private func colorForVoltage(_ voltage: Float) -> Color {
        // Blue (negative) -> White (zero) -> Red (positive)
        let maxAbs: Float = 100
        let normalized = max(min(voltage / maxAbs, 1), -1)

        if normalized >= 0 {
            return Color(red: 1.0, green: Double(1.0 - normalized), blue: Double(1.0 - normalized))
        } else {
            let abs = -normalized
            return Color(red: Double(1.0 - abs), green: Double(1.0 - abs), blue: 1.0)
        }
    }

    private func loadElectrodes() {
        let channelCount = signal.numberOfChannels
        let filename: String
        if channelCount >= 257 {
            filename = "GSN-HydroCel-257"
        } else if channelCount >= 129 {
            filename = "GSN-HydroCel-129"
        } else {
            electrodes = []
            return
        }

        guard let url = Bundle.main.url(forResource: filename, withExtension: "sfp") else {
            electrodes = []
            return
        }

        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            electrodes = []
            return
        }

        var parsed: [ElectrodeLocation] = []
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            // Split by whitespace or tab
            let parts = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            guard parts.count >= 4 else { continue }

            let label = parts[0]
            // Skip fiducials
            if label.hasPrefix("Fid") { continue }

            guard let x = Double(parts[1]),
                  let y = Double(parts[2]),
                  let z = Double(parts[3]) else { continue }

            parsed.append(ElectrodeLocation(label: label, x: x, y: y, z: z))
        }

        // Only keep as many electrodes as we have channels
        electrodes = Array(parsed.prefix(channelCount))
    }
}

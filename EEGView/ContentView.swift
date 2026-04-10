//
//  ContentView.swift
//  EEGView
//
//  Created by PJM on 3/19/26.
//

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(WaveformSession.self) private var waveformSession
    @Environment(\.openWindow) private var openWindow

    @State private var package: MFFPackage?
    @State private var signal: MFFSignalData?
    @State private var selectedXMLFile = ""
    @State private var selectedSignalFile = ""
    @State private var errorMessage: String?
    @State private var isLoadingSignal = false
    @State private var isDropTargeted = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("MFF Reader")
                            .font(.largeTitle.weight(.semibold))
                        Text("Open an MFF package, inspect XML files first, then load signal data on demand. You can also drag a `.mff` package into this window.")
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button("Open MFF") {
                        waveformSession.choosePackage()
                    }
                }

                if let package {
                    packageSummary(package)
                } else {
                    ContentUnavailableView(
                        "No MFF Loaded",
                        systemImage: "waveform.path.ecg",
                        description: Text("Choose an `.mff` package to inspect its internal XML and signal files.")
                    )
                }

                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .font(.callout)
                        .textSelection(.enabled)
                }
            }
            .padding(24)
            .frame(minWidth: 720, minHeight: 560, alignment: .topLeading)
            .background(dropTargetOverlay)
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted, perform: handleDrop(providers:))
        .onChange(of: waveformSession.selectedPackageURL) { _, newValue in
            guard let newValue else {
                return
            }
            inspectPackage(at: newValue, selectedXMLFile: nil)
        }
    }

    @ViewBuilder
    private func packageSummary(_ package: MFFPackage) -> some View {
        List {
            Section("Package") {
                LabeledContent("Source", value: package.sourceURL.lastPathComponent)
                LabeledContent("XML Files", value: "\(package.xmlFiles.count)")
                LabeledContent("Signal Files", value: "\(package.binFiles.count)")
            }

            Section("XML Files") {
                Picker("XML File", selection: $selectedXMLFile) {
                    ForEach(package.xmlFiles, id: \.self) { fileName in
                        Text(fileName).tag(fileName)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: selectedXMLFile) { _, newValue in
                    guard !newValue.isEmpty, newValue != package.selectedXMLFile else {
                        return
                    }
                    inspectPackage(at: package.sourceURL, selectedXMLFile: newValue)
                }

                ForEach(package.xmlFiles, id: \.self) { fileName in
                    Text(fileName)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(fileName == package.selectedXMLFile ? .primary : .secondary)
                }
            }

            if !package.metrics.isEmpty {
                Section("Parsed XML Metrics") {
                    ForEach(package.metrics.keys.sorted(), id: \.self) { key in
                        LabeledContent(key, value: package.metrics[key] ?? "")
                    }
                }
            }

            Section("Signal Files") {
                Picker("Signal File", selection: $selectedSignalFile) {
                    ForEach(package.binFiles, id: \.self) { fileName in
                        Text(fileName).tag(fileName)
                    }
                }
                .pickerStyle(.menu)

                ForEach(package.binFiles, id: \.self) { fileName in
                    Text(fileName)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(fileName == selectedSignalFile ? .primary : .secondary)
                }

                Button(isLoadingSignal ? "Loading Signal..." : "Load Signal Data") {
                    loadSignal(from: package.sourceURL, signalFileName: selectedSignalFile)
                }
                .disabled(isLoadingSignal || selectedSignalFile.isEmpty)
            }

            if let signal {
                Section("Signal Summary") {
                    LabeledContent("Signal File", value: signal.signalURL.lastPathComponent)
                    LabeledContent("Signal Type", value: signal.signalType)
                    LabeledContent("Channels", value: "\(signal.numberOfChannels)")
                    LabeledContent("Sampling Rate", value: String(format: "%.2f Hz", signal.samplingRate))
                    LabeledContent("Duration", value: formattedDuration(signal.duration))
                    LabeledContent("Matrix Shape", value: "\(signal.data.count) x \(signal.data.first?.count ?? 0)")
                }

                Section("Preview") {
                    let previewSamples = signal.data.prefix(3).enumerated().map { index, channel in
                        "Ch \(index + 1): " + channel.prefix(8).map { String(format: "%.3f", $0) }.joined(separator: ", ")
                    }

                    ForEach(previewSamples, id: \.self) { line in
                        Text(line)
                            .font(.system(.body, design: .monospaced))
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    private func inspectPackage(at url: URL, selectedXMLFile: String?) {
        guard url.pathExtension.lowercased() == "mff" else {
            package = nil
            signal = nil
            errorMessage = "Select an `.mff` package."
            return
        }

        let didAccessSecurityScopedResource = url.startAccessingSecurityScopedResource()
        defer {
            if didAccessSecurityScopedResource {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let package = try MFFReader().inspectPackage(at: url, selectedXMLFile: selectedXMLFile)
            self.package = package
            self.selectedXMLFile = package.selectedXMLFile
            self.selectedSignalFile = package.binFiles.first ?? ""
            self.signal = nil
            self.errorMessage = nil
        } catch {
            self.package = nil
            self.signal = nil
            self.errorMessage = error.localizedDescription
        }
    }

    private func loadSignal(from url: URL, signalFileName: String) {
        guard !signalFileName.isEmpty else {
            errorMessage = "Select a signal file first."
            return
        }

        isLoadingSignal = true

        Task {
            let didAccessSecurityScopedResource = url.startAccessingSecurityScopedResource()
            defer {
                if didAccessSecurityScopedResource {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            do {
                let loadedSignal = try MFFReader().loadSignal(from: url, signalFileName: signalFileName)
                await MainActor.run {
                    signal = loadedSignal
                    waveformSession.signal = loadedSignal
                    errorMessage = nil
                    isLoadingSignal = false
                    openWindow(id: "waveforms")
                }
            } catch {
                await MainActor.run {
                    signal = nil
                    waveformSession.signal = nil
                    errorMessage = error.localizedDescription
                    isLoadingSignal = false
                }
            }
        }
    }

    private func formattedDuration(_ duration: TimeInterval) -> String {
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        let seconds = duration.truncatingRemainder(dividingBy: 60)

        if hours > 0 {
            return String(format: "%d:%02d:%05.2f", hours, minutes, seconds)
        }

        return String(format: "%d:%05.2f", minutes, seconds)
    }

    @ViewBuilder
    private var dropTargetOverlay: some View {
        if isDropTargeted {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 8]))
                .fill(Color.accentColor.opacity(0.08))
                .overlay {
                    VStack(spacing: 10) {
                        Image(systemName: "square.and.arrow.down.on.square")
                            .font(.system(size: 30, weight: .semibold))
                        Text("Drop an MFF package to open it")
                            .font(.headline)
                    }
                    .foregroundStyle(Color.accentColor)
                    .padding(24)
                }
                .padding(12)
                .allowsHitTesting(false)
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else {
            return false
        }

        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            let url: URL?

            switch item {
            case let data as Data:
                url = URL(dataRepresentation: data, relativeTo: nil)
            case let urlValue as URL:
                url = urlValue
            default:
                url = nil
            }

            guard let url else {
                return
            }

            Task { @MainActor in
                waveformSession.openPackage(at: url)
            }
        }

        return true
    }
}

#Preview {
    ContentView()
}

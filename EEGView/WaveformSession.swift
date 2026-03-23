//
//  WaveformSession.swift
//  EEGView
//
//  Created by PJM on 3/19/26.
//

import AppKit
import Observation

@Observable
final class WaveformSession {
    var selectedPackageURL: URL?
    var signal: MFFSignalData?

    func choosePackage() {
        let panel = NSOpenPanel()
        panel.title = "Open MFF Package"
        panel.prompt = "Open"
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = []

        if panel.runModal() == .OK {
            selectedPackageURL = panel.url
            signal = nil
            NSApp.windows
                .first(where: { $0.title != "Waveforms" })?
                .makeKeyAndOrderFront(nil)
        }
    }
}

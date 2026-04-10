//
//  EEGViewApp.swift
//  EEGView
//
//  Created by PJM on 3/19/26.
//

import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct EEGViewApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var waveformSession = WaveformSession()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(waveformSession)
        }
        .defaultSize(width: 980, height: 760)
        .windowResizability(.contentMinSize)

        Window("Waveforms", id: "waveforms") {
            WaveformWindowView()
                .environment(waveformSession)
        }
        .defaultSize(width: 1280, height: 840)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Open MFF...") {
                    NSApp.activate(ignoringOtherApps: true)
                    waveformSession.choosePackage()
                }
                .keyboardShortcut("o")
            }
        }
    }
}

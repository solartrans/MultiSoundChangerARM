//
//  Runner.swift
//  MultiSoundChanger
//
//  Created by Dmitry Medyuho on 22.04.21.
//  Copyright © 2021 Dmitry Medyuho. All rights reserved.
//

import Cocoa

enum Runner {
    @discardableResult
    static func shell(_ command: String) -> String? {
        let task = Process()
        let pipe = Pipe()

        task.standardOutput = pipe
        task.standardError = pipe
        task.arguments = ["-c", command]
        task.launchPath = "/bin/sh"
        task.launch()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()

        guard let output = String(data: data, encoding: .utf8) else {
            return nil
        }

        return output
    }

    static func launchApplication(bundleIdentifier: String) {
        // Modern replacement for `NSWorkspace.launchApplication(withBundleIdentifier:options:...)`,
        // which was deprecated in macOS 11. Resolve bundle ID → app URL, then open with a
        // default `NSWorkspaceOpenConfiguration`. Silently no-ops if the app isn't installed.
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }
}

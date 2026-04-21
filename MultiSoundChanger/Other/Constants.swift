//
//  Constants.swift
//  MultiSoundChanger
//
//  Created by Dmitry Medyuho on 16.11.2020.
//  Copyright © 2020 Dmitry Medyuho. All rights reserved.
//

import Foundation

enum Constants {
    static let chicletsCount = 16
    static let optionMaxLength = 25
    static let muteVolumeLowerbound: Float = 0.001
    static let logFilename = "app.log"

    enum AppBundleIdentifier {
        static let audioDevices = "com.apple.audio.AudioMIDISetup"
    }

    // x-apple.systempreferences: URL used to jump straight to the Sound pane in System Settings
    // (modern macOS) or System Preferences (pre-Ventura). Replaces the previous shell-out via
    // `open -b com.apple.systempreferences /System/Library/PreferencePanes/Sound.prefPane`.
    enum SystemSettingsURL {
        static let sound = "x-apple.systempreferences:com.apple.preference.sound"
    }

    enum Notifications {
        static let accessibility = "com.apple.accessibility.api"
    }

    enum Keys: String {
        case empty = ""
        case q
    }

    enum InnerMessages {
        static let accessEnabled = "Access enabled"
        static let accessDenied = "Access denied"
        static let getDisplayError = "Error getting display under cursor"
        static let outputDevices = "Output devices"
        static let bundleIdentifierError = "Can't get bundle identifier"
        static let controllerIdentifierError = "Wrong controller identifier"

        static func debugDevice(deviceID: String, deviceName: String) -> String {
            return "id: \(deviceID) | name: \(deviceName)"
        }

        static func selectDevice(deviceID: String) -> String {
            return "Select device id: \(deviceID)"
        }

        static func selectedDeviceVolume(volume: String) -> String {
            return "Selected device volume: \(volume)"
        }
    }
}

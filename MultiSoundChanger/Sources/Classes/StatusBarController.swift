//
//  StatusBarController.swift
//  MultiSoundChanger
//
//  Created by Dmitry Medyuho on 15.11.2020.
//  Copyright © 2020 Dmitry Medyuho. All rights reserved.
//

import AudioToolbox
import Cocoa

// MARK: - Protocols

protocol StatusBarController: AnyObject {
    func createMenu()
    func changeStatusItemImage(value: Float)
    func updateVolume(value: Float)
    func refreshDeviceList()
    func syncDefaultOutputDevice()
}

// MARK: - Extensions

extension StatusBarControllerImpl {
    enum MenuItem {
        case volume
        case slider
        case output
        case separator
        case soundPreferences
        case audioSetup
        case quit
    }
}

// MARK: - Implementation

final class StatusBarControllerImpl: NSObject, StatusBarController {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let volumeController: VolumeViewController
    private let audioManager: AudioManager
    private var deviceMenuItems: [NSMenuItem] = []
    private var outputSectionAnchor: NSMenuItem?
    private var isMenuOpen = false
    private var pendingRefresh = false

    init(audioManager: AudioManager) {
        self.audioManager = audioManager

        self.volumeController = Stories.volume.controller(VolumeViewController.self)
        super.init()
        self.volumeController.audioManager = audioManager
        self.volumeController.statusBarController = self
    }

    func createMenu() {
        if let button = statusItem.button {
            button.image = Images.volumeImage1
            button.setAccessibilityLabel(Strings.volume)
        }

        // Defensive: if createMenu is ever invoked twice, the prior device-item array and anchor
        // would otherwise leak references to the stale menu's NSMenuItems.
        deviceMenuItems.removeAll()
        outputSectionAnchor = nil

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self

        let volumeItem = getMenuItem(by: .volume)
        let sliderItem = getMenuItem(by: .slider)
        let outputItem = getMenuItem(by: .output)
        let firstSeparatorItem = getMenuItem(by: .separator)
        let soundPreferencesItem = getMenuItem(by: .soundPreferences)
        let audioSetupItem = getMenuItem(by: .audioSetup)
        let secondSeparatorItem = getMenuItem(by: .separator)
        let quitItem = getMenuItem(by: .quit)

        outputSectionAnchor = outputItem

        menu.addItem(volumeItem)
        menu.addItem(sliderItem)
        menu.addItem(outputItem)
        populateDeviceList(in: menu)
        menu.addItem(firstSeparatorItem)
        menu.addItem(soundPreferencesItem)
        menu.addItem(audioSetupItem)
        menu.addItem(secondSeparatorItem)
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    func changeStatusItemImage(value: Float) {
        if value <= 1 {
            statusItem.button?.image = Images.volumeImage1
        } else if value <= 100 / 3 {
            statusItem.button?.image = Images.volumeImage2
        } else if value <= 100 / 3 * 2 {
            statusItem.button?.image = Images.volumeImage3
        } else {
            statusItem.button?.image = Images.volumeImage4
        }
    }

    func updateVolume(value: Float) {
        volumeController.updateSliderVolume(volume: value)
        changeStatusItemImage(value: value)
    }

    func refreshDeviceList() {
        guard let menu = statusItem.menu else {
            return
        }
        // NSMenu mutation while the user has the menu open can crash AppKit's tracking machinery.
        // Defer the refresh until menuDidClose fires.
        if isMenuOpen {
            pendingRefresh = true
            return
        }
        for item in deviceMenuItems {
            menu.removeItem(item)
        }
        deviceMenuItems.removeAll()
        populateDeviceList(in: menu)
    }

    func syncDefaultOutputDevice() {
        let defaultDevice = audioManager.getDefaultOutputDevice()
        guard defaultDevice != kAudioDeviceUnknown else {
            return
        }
        let intTag = Int(defaultDevice)
        for item in deviceMenuItems {
            item.state = (item.tag == intTag) ? .on : .off
        }
        // Track the system default without round-tripping through setOutputDevice — that would
        // refire the default-output listener and could recurse.
        audioManager.followSelectedDevice(deviceID: defaultDevice)
        if let volume = audioManager.getSelectedDeviceVolume() {
            let correctedVolume = audioManager.isMuted ? 0 : volume * 100
            volumeController.updateSliderVolume(volume: correctedVolume)
            changeStatusItemImage(value: correctedVolume)
        }
    }

    private func populateDeviceList(in menu: NSMenu) {
        guard let devices = audioManager.getOutputDevices() else {
            return
        }
        let defaultDevice = audioManager.getDefaultOutputDevice()
        let sortedDevices = devices.sorted { lhs, rhs in
            lhs.value.localizedCaseInsensitiveCompare(rhs.value) == .orderedAscending
        }

        // Insert device items immediately after the "Output Device:" header so menu ordering
        // stays stable on refresh.
        let insertionStart: Int
        if let anchor = outputSectionAnchor {
            let anchorIndex = menu.index(of: anchor)
            guard anchorIndex >= 0 else {
                Logger.warning("Output section anchor missing from menu; skipping device list rebuild")
                return
            }
            insertionStart = anchorIndex + 1
        } else {
            Logger.warning("Output section anchor not set; skipping device list rebuild")
            return
        }

        var cursor = insertionStart
        for device in sortedDevices {
            let item = NSMenuItem(
                title: truncate(device.value, length: Constants.optionMaxLength),
                action: #selector(menuItemAction),
                keyEquivalent: String()
            )
            item.target = self
            item.tag = Int(device.key)

            if device.key == defaultDevice {
                item.state = .on
                selectDevice(device: defaultDevice)
            }

            menu.insertItem(item, at: cursor)
            deviceMenuItems.append(item)
            cursor += 1
        }
    }

    private func getMenuItem(by type: MenuItem) -> NSMenuItem {
        switch type {
        case .volume:
            let item = NSMenuItem(title: Strings.volume, action: nil, keyEquivalent: Constants.Keys.empty.rawValue)
            item.isEnabled = false
            return item

        case .slider:
            let item = NSMenuItem(title: String(), action: nil, keyEquivalent: Constants.Keys.empty.rawValue)
            item.view = volumeController.view
            return item

        case .output:
            let item = NSMenuItem(title: Strings.output, action: nil, keyEquivalent: Constants.Keys.empty.rawValue)
            item.isEnabled = false
            return item

        case .separator:
            return NSMenuItem.separator()

        case .soundPreferences:
            let item = NSMenuItem(
                title: Strings.soundPreferences,
                action: #selector(menuSoundPreferencesAction),
                keyEquivalent: Constants.Keys.empty.rawValue
            )
            item.target = self
            return item

        case .audioSetup:
            let item = NSMenuItem(title: Strings.audioDevices, action: #selector(menuAudioSetupAction), keyEquivalent: Constants.Keys.empty.rawValue)
            item.target = self
            return item

        case .quit:
            let item = NSMenuItem(title: Strings.quit, action: #selector(menuQuitAction), keyEquivalent: Constants.Keys.q.rawValue)
            item.target = self
            return item
        }
    }

    private func selectDevice(device: AudioDeviceID) {
        audioManager.selectDevice(deviceID: device)
        guard let volume = audioManager.getSelectedDeviceVolume() else {
            return
        }
        let correctedVolume = audioManager.isMuted ? 0 : volume * 100
        volumeController.updateSliderVolume(volume: correctedVolume)
        changeStatusItemImage(value: correctedVolume)
    }

    private func truncate(_ string: String, length: Int, trailing: String = "…") -> String {
        if string.count > length {
            return String(string.prefix(length)) + trailing
        } else {
            return string
        }
    }

    @objc
    private func menuItemAction(sender: NSMenuItem) {
        for item in deviceMenuItems {
            item.state = (item == sender) ? .on : .off
        }
        selectDevice(device: AudioDeviceID(sender.tag))
    }

    @objc
    private func menuSoundPreferencesAction() {
        Runner.shell("open -b \(Constants.AppBundleIdentifier.systemPreferences) \(Constants.SystemPreferencesPane.sound)")
    }

    @objc
    private func menuAudioSetupAction() {
        Runner.launchApplication(bundleIndentifier: Constants.AppBundleIdentifier.audioDevices, options: .default)
    }

    @objc
    private func menuQuitAction() {
        NSApplication.shared.terminate(self)
    }
}

// MARK: - NSMenuDelegate

extension StatusBarControllerImpl: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
        if pendingRefresh {
            pendingRefresh = false
            refreshDeviceList()
        }
    }
}

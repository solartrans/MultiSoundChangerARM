//
//  AudioManager.swift
//  MultiSoundChanger
//
//  Created by Dmitry Medyuho on 15.11.2020.
//  Copyright © 2020 Dmitry Medyuho. All rights reserved.
//

import AudioToolbox
import Foundation

// MARK: - Protocols

protocol AudioManagerDelegate: AnyObject {
    func audioManagerDidChangeDevices(_ manager: AudioManager)
    func audioManagerDidChangeDefaultOutputDevice(_ manager: AudioManager)
}

protocol AudioManager: AnyObject {
    func getDefaultOutputDevice() -> AudioDeviceID
    func getOutputDevices() -> [AudioDeviceID: String]?
    func selectDevice(deviceID: AudioDeviceID)
    func getSelectedDeviceVolume() -> Float?
    func setSelectedDeviceVolume(volume: Float)
    func isSelectedDeviceMuted() -> Bool
    func toggleMute()
    // Update the app's selected device to track an external default-output change (e.g. the user
    // switched output in System Settings) without round-tripping through setOutputDevice — which
    // would refire the default-output listener and risk a feedback loop.
    func followSelectedDevice(deviceID: AudioDeviceID)

    var isMuted: Bool { get }
    var delegate: AudioManagerDelegate? { get set }
}

// MARK: - Implementation

final class AudioManagerImpl: AudioManager {
    weak var delegate: AudioManagerDelegate?

    private let audio: Audio = AudioImpl()
    private var devices: [AudioDeviceID: String]?
    private var selectedDevice: AudioDeviceID?
    private var listenerTokens: [AudioListenerToken] = []

    init() {
        devices = audio.getOutputDevices()
        let defaultDevice = audio.getDefaultOutputDevice()
        selectedDevice = (defaultDevice != kAudioDeviceUnknown) ? defaultDevice : nil
        printDevices()
        registerListeners()
    }

    deinit {
        for token in listenerTokens {
            audio.removeListener(token)
        }
    }

    func getDefaultOutputDevice() -> AudioDeviceID {
        return audio.getDefaultOutputDevice()
    }

    func getOutputDevices() -> [AudioDeviceID: String]? {
        return devices
    }

    func selectDevice(deviceID: AudioDeviceID) {
        selectedDevice = deviceID
        audio.setOutputDevice(newDeviceID: deviceID)
        Logger.debug(Constants.InnerMessages.selectDevice(deviceID: String(deviceID)))
    }

    func followSelectedDevice(deviceID: AudioDeviceID) {
        selectedDevice = deviceID
        Logger.debug(Constants.InnerMessages.selectDevice(deviceID: String(deviceID)))
    }

    func getSelectedDeviceVolume() -> Float? {
        guard let selectedDevice = selectedDevice else {
            return nil
        }

        if audio.isAggregateDevice(deviceID: selectedDevice) {
            let aggregatedDevices = audio.getAggregateDeviceSubDeviceList(deviceID: selectedDevice)

            for device in aggregatedDevices where audio.isOutputDevice(deviceID: device) {
                return audio.getDeviceVolume(deviceID: device).max()
            }
        } else {
            return audio.getDeviceVolume(deviceID: selectedDevice).max()
        }

        return nil
    }

    func setSelectedDeviceVolume(volume: Float) {
        guard let selectedDevice = selectedDevice else {
            return
        }

        let isMute = volume < Constants.muteVolumeLowerbound

        if audio.isAggregateDevice(deviceID: selectedDevice) {
            let aggregatedDevices = audio.getAggregateDeviceSubDeviceList(deviceID: selectedDevice)

            for device in aggregatedDevices {
                audio.setDeviceVolume(
                    deviceID: device,
                    masterChannelLevel: volume,
                    leftChannelLevel: volume,
                    rightChannelLevel: volume
                )
                audio.setDeviceMute(deviceID: device, isMute: isMute)
            }
        } else {
            audio.setDeviceVolume(
                deviceID: selectedDevice,
                masterChannelLevel: volume,
                leftChannelLevel: volume,
                rightChannelLevel: volume
            )
            audio.setDeviceMute(deviceID: selectedDevice, isMute: isMute)
        }
    }

    func setSelectedDeviceMute(isMute: Bool) {
        guard let selectedDevice = selectedDevice else {
            return
        }

        if audio.isAggregateDevice(deviceID: selectedDevice) {
            let aggregatedDevices = audio.getAggregateDeviceSubDeviceList(deviceID: selectedDevice)

            for device in aggregatedDevices {
                audio.setDeviceMute(deviceID: device, isMute: isMute)
            }
        } else {
            audio.setDeviceMute(deviceID: selectedDevice, isMute: isMute)
        }
    }

    func isSelectedDeviceMuted() -> Bool {
        guard let selectedDevice = selectedDevice else {
            return false
        }

        if audio.isAggregateDevice(deviceID: selectedDevice) {
            let aggregatedDevices = audio.getAggregateDeviceSubDeviceList(deviceID: selectedDevice)

            guard let device = aggregatedDevices.first else {
                return false
            }

            return audio.isDeviceMuted(deviceID: device)
        } else {
            return audio.isDeviceMuted(deviceID: selectedDevice)
        }
    }

    func toggleMute() {
        if isSelectedDeviceMuted() {
            // Only flip the mute flag. The previous implementation re-applied the current
            // scalar volume after unmuting, which trapped users on drivers that zero the
            // volume-scalar when muted (or users who were at 0 volume before muting): the
            // re-apply of 0 triggered `setSelectedDeviceVolume`'s auto-mute and immediately
            // re-muted the device.
            setSelectedDeviceMute(isMute: false)
        } else {
            setSelectedDeviceMute(isMute: true)
        }
    }

    var isMuted: Bool {
        return isSelectedDeviceMuted()
    }

    private func printDevices() {
        guard let devices = devices else {
            return
        }
        Logger.debug(Constants.InnerMessages.outputDevices)
        for device in devices {
            Logger.debug(Constants.InnerMessages.debugDevice(deviceID: String(device.key), deviceName: device.value))
        }
    }

    private func registerListeners() {
        if let token = audio.addDevicesListener(onChange: { [weak self] in self?.handleDevicesChanged() }) {
            listenerTokens.append(token)
        }
        if let token = audio.addDefaultOutputDeviceListener(onChange: { [weak self] in self?.handleDefaultOutputChanged() }) {
            listenerTokens.append(token)
        }
    }

    private func handleDevicesChanged() {
        devices = audio.getOutputDevices()
        // If the currently selected device was removed, fall back to whatever the system default
        // points at now — hotkeys and the slider keep working instead of silently no-oping.
        if let current = selectedDevice, devices?[current] == nil {
            let fallback = audio.getDefaultOutputDevice()
            selectedDevice = (fallback != kAudioDeviceUnknown) ? fallback : nil
        }
        delegate?.audioManagerDidChangeDevices(self)
    }

    private func handleDefaultOutputChanged() {
        delegate?.audioManagerDidChangeDefaultOutputDevice(self)
    }
}

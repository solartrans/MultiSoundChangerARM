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
    func toggleMute()
    // Update the app's selected device to track an external default-output change (e.g. the user
    // switched output in System Settings) without round-tripping through setOutputDevice — which
    // would refire the default-output listener and risk a feedback loop.
    func adoptSelectedDevice(deviceID: AudioDeviceID)

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
    private var volumeBeforeMute: Float?

    // Coalesce rapid `setSelectedDeviceVolume` calls (media-key repeat, slider drag) into a
    // single trailing-edge HAL write. Callers paint UI synchronously using the returned-from-
    // `getSelectedDeviceVolume` pending value; the HAL write fires `halApplyDelay` after the
    // most recent call.
    private var pendingTargetVolume: Float?
    private var pendingApplyItem: DispatchWorkItem?
    private static let halApplyDelay: TimeInterval = 1.0 / 30.0

    init() {
        devices = audio.getOutputDevices()
        let defaultDevice = audio.getDefaultOutputDevice()
        selectedDevice = (defaultDevice != kAudioDeviceUnknown) ? defaultDevice : nil
        printDevices()
        registerListeners()
    }

    deinit {
        pendingApplyItem?.cancel()
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
        cancelPendingVolumeApply()
        selectedDevice = deviceID
        audio.setOutputDevice(newDeviceID: deviceID)
        Logger.debug(Constants.InnerMessages.selectDevice(deviceID: String(deviceID)))
    }

    func adoptSelectedDevice(deviceID: AudioDeviceID) {
        cancelPendingVolumeApply()
        selectedDevice = deviceID
        Logger.debug(Constants.InnerMessages.selectDevice(deviceID: String(deviceID)))
    }

    func getSelectedDeviceVolume() -> Float? {
        // Prefer the most recent user-requested value so media-key quantization at the top of
        // `onMediaKeyTap` and slider-drag reads see consistent state across rapid events, even
        // when the debounced HAL write for the previous event hasn't fired yet. Falls through
        // to a live HAL read when nothing's pending (fresh app launch, post-device-switch, etc.).
        if let pending = pendingTargetVolume {
            return pending
        }
        return readDeviceVolumeFromHAL()
    }

    func setSelectedDeviceVolume(volume: Float) {
        guard selectedDevice != nil else {
            return
        }
        // Capture the latest target so any still-scheduled work item drops through — and any
        // intervening `getSelectedDeviceVolume` sees the new value.
        pendingTargetVolume = volume
        pendingApplyItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.flushPendingVolumeApply()
        }
        pendingApplyItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.halApplyDelay, execute: work)
    }

    func toggleMute() {
        // Mute/unmute takes precedence over any pending volume write — otherwise a queued
        // volume.apply would fire after the mute and overwrite the mute flag via
        // setSelectedDeviceVolume's auto-mute branch.
        let intendedVolume = getSelectedDeviceVolume()
        cancelPendingVolumeApply()

        if isSelectedDeviceMuted() {
            setSelectedDeviceMute(isMute: false)
            // Some drivers zero the volume scalar while muted. If we come back to an
            // effectively-zero scalar after unmuting, restore the pre-mute volume so the
            // user doesn't appear stuck at 0% audio. If the pre-mute volume was itself
            // below the auto-mute lowerbound (user deliberately muted silence), leave the
            // scalar alone — re-applying 0 here would re-trigger the auto-mute branch in
            // applyVolumeToHAL and undo the unmute.
            if let pre = volumeBeforeMute,
               pre >= Constants.muteVolumeLowerbound,
               let current = readDeviceVolumeFromHAL(),
               current < Constants.muteVolumeLowerbound {
                applyVolumeToHAL(pre)
            }
            volumeBeforeMute = nil
        } else {
            volumeBeforeMute = intendedVolume
            setSelectedDeviceMute(isMute: true)
        }
    }

    var isMuted: Bool {
        return isSelectedDeviceMuted()
    }

    // MARK: Private

    // Actual HAL writer — called from the debounced work item and from `toggleMute`'s
    // unmute-restore path. Not exposed.
    private func applyVolumeToHAL(_ volume: Float) {
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

    private func flushPendingVolumeApply() {
        guard let target = pendingTargetVolume else {
            return
        }
        pendingTargetVolume = nil
        pendingApplyItem = nil
        applyVolumeToHAL(target)
    }

    private func cancelPendingVolumeApply() {
        pendingApplyItem?.cancel()
        pendingApplyItem = nil
        pendingTargetVolume = nil
    }

    // Unconditional HAL read — bypasses the pending-target cache. Used by mute/unmute so the
    // driver-zeroed-scalar check sees the actual device state, not a cached intent.
    private func readDeviceVolumeFromHAL() -> Float? {
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

    private func setSelectedDeviceMute(isMute: Bool) {
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

    private func isSelectedDeviceMuted() -> Bool {
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
            cancelPendingVolumeApply()
            let fallback = audio.getDefaultOutputDevice()
            selectedDevice = (fallback != kAudioDeviceUnknown) ? fallback : nil
        }
        delegate?.audioManagerDidChangeDevices(self)
    }

    private func handleDefaultOutputChanged() {
        delegate?.audioManagerDidChangeDefaultOutputDevice(self)
    }
}

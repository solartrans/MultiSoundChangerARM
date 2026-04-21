//
//  ApplicationController.swift
//  MultiSoundChanger
//
//  Created by Dmitry Medyuho on 20.04.21.
//  Copyright © 2021 Dmitry Medyuho. All rights reserved.
//

import Foundation
import MediaKeyTap

// MARK: - Protocols

protocol ApplicationController: AnyObject {
    func start()
}

// MARK: - Implementation

final class ApplicationControllerImp: ApplicationController {
    private lazy var audioManager: AudioManager = AudioManagerImpl()
    private lazy var mediaManager: MediaManager = MediaManagerImpl(delegate: self)
    private lazy var statusBarController: StatusBarController = StatusBarControllerImpl(audioManager: audioManager)

    func start() {
        // Wire delegate before createMenu so that any listener callback AudioManagerImpl queues
        // during construction (unlikely, but main-thread-queued from a HAL firing in the gap)
        // finds a non-nil delegate when it runs.
        audioManager.delegate = self
        statusBarController.createMenu()
        mediaManager.listenMediaKeyTaps()
    }
}

// MARK: - AudioManagerDelegate

extension ApplicationControllerImp: AudioManagerDelegate {
    func audioManagerDidChangeDevices(_ manager: AudioManager) {
        statusBarController.refreshDeviceList()
    }

    func audioManagerDidChangeDefaultOutputDevice(_ manager: AudioManager) {
        statusBarController.syncDefaultOutputDevice()
    }
}

// MARK: - MediaManagerDelegate

extension ApplicationControllerImp: MediaManagerDelegate {
    func onMediaKeyTap(mediaKey: MediaKey) {
        guard let selectedDeviceVolume = audioManager.getSelectedDeviceVolume() else {
            return
        }

        let volumeStep: Float = 1 / Float(Constants.chicletsCount)
        var volume: Float = (selectedDeviceVolume / volumeStep).rounded() * volumeStep

        switch mediaKey {
        case .volumeUp:
            volume = (volume + volumeStep).clamped(to: 0...1)
            paintVolumeFeedback(volume)
            audioManager.setSelectedDeviceVolume(volume: volume)

        case .volumeDown:
            volume = (volume - volumeStep).clamped(to: 0...1)
            paintVolumeFeedback(volume)
            audioManager.setSelectedDeviceVolume(volume: volume)

        case .mute:
            // Mute path needs the post-toggle state to choose the OSD glyph, so the HAL write
            // has to come first here — unlike volumeUp/Down where we already know the target.
            audioManager.toggleMute()
            volume = audioManager.isMuted ? 0 : (audioManager.getSelectedDeviceVolume() ?? 0)
            paintVolumeFeedback(volume)

        default:
            break
        }
    }

    /// Paint the slider, status-bar icon, and OSD for the given 0…1 volume BEFORE the HAL
    /// `setSelectedDeviceVolume` call, so the visual feedback appears immediately instead of
    /// waiting for the CoreAudio round-trip (especially multi-sub-device aggregate writes).
    private func paintVolumeFeedback(_ volume: Float) {
        let correctedVolume = volume * 100
        statusBarController.updateVolume(value: correctedVolume)
        mediaManager.showOSD(volume: correctedVolume, chicletsCount: Constants.chicletsCount)
        Logger.debug(Constants.InnerMessages.selectedDeviceVolume(volume: String(correctedVolume)))
    }
}

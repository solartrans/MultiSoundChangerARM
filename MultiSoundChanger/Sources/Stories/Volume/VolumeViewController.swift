//
//  ViewController.swift
//  MultiSoundChanger
//
//  Created by Dmitry Medyuho on 02.04.17.
//  Copyright © 2017 Dmitry Medyuho. All rights reserved.
//

import Cocoa

final class VolumeViewController: NSViewController {
    @IBOutlet weak var volumeSlider: NSSlider!

    weak var statusBarController: StatusBarController?
    var audioManager: AudioManager?

    // NSSlider fires `volumeSliderAction` on every pixel of drag, and each fire currently does a
    // blocking CoreAudio write (multiplied by sub-device count on aggregates). Debounce the
    // HAL write to the trailing edge of a drag burst so the slider knob + status-bar icon
    // follow the cursor smoothly and the HAL catches up on pause/release.
    private var halApplyItem: DispatchWorkItem?
    private static let halApplyDelay: TimeInterval = 1.0 / 30.0

    private func changeDeviceVolume(value: Float) {
        audioManager?.setSelectedDeviceVolume(volume: value)
    }

    func updateSliderVolume(volume: Float) {
        volumeSlider.floatValue = volume.clamped(to: 0...100)
    }

    @IBAction func volumeSliderAction(_ sender: Any) {
        let sliderValue = volumeSlider.floatValue
        statusBarController?.changeStatusItemImage(value: sliderValue)

        halApplyItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.changeDeviceVolume(value: sliderValue / 100)
        }
        halApplyItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + VolumeViewController.halApplyDelay, execute: work)
    }
}

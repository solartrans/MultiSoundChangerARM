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

    func updateSliderVolume(volume: Float) {
        volumeSlider.floatValue = volume.clamped(to: 0...100)
    }

    @IBAction func volumeSliderAction(_ sender: Any) {
        let sliderValue = volumeSlider.floatValue
        statusBarController?.changeStatusItemImage(value: sliderValue)
        // `AudioManager.setSelectedDeviceVolume` internally debounces the HAL write, so it's
        // safe to call on every drag event — per-pixel slider motion no longer blocks main on
        // CoreAudio IPC.
        audioManager?.setSelectedDeviceVolume(volume: sliderValue / 100)
    }
}

//
//  MediaManager.swift
//  MultiSoundChanger
//
//  Created by Dmitry Medyuho on 15.11.2020.
//  Copyright © 2020 Dmitry Medyuho. All rights reserved.
//

import Cocoa
import Foundation
import MediaKeyTap

// MARK: - Protocols

protocol MediaManagerDelegate: AnyObject {
    func onMediaKeyTap(mediaKey: MediaKey)
}

protocol MediaManager: AnyObject {
    func listenMediaKeyTaps()
    func showOSD(volume: Float, chicletsCount: Int)
}

// MARK: - Implementation

final class MediaManagerImpl: MediaManager {
    private weak var delegate: MediaManagerDelegate?
    private var mediaKeyTap: MediaKeyTap?
    
    init(delegate: MediaManagerDelegate) {
        self.delegate = delegate
    }
    
    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
    }
    
    // MARK: Public
    
    func listenMediaKeyTaps() {
        observeMediaKeyOnAccessibiltiyApiChange()
        startMediaKeyTap()
    }
    
    func showOSD(volume: Float, chicletsCount: Int = 16) {
        let manager = OSDManager.sharedManager()

        let mouseloc: NSPoint = NSEvent.mouseLocation
        var displayForPoint: CGDirectDisplayID = 0
        var count: UInt32 = 0

        if CGGetDisplaysWithPoint(mouseloc, 1, &displayForPoint, &count) != .success {
            Logger.warning(Constants.InnerMessages.getDisplayError)
            displayForPoint = CGMainDisplayID()
        }

        let image = (volume == 0) ? OSDGraphic.speakerMuted.rawValue : OSDGraphic.speaker.rawValue
        let volumeStep: Float = 100 / Float(chicletsCount)

        manager.showImage(
            Int64(image),
            onDisplayID: displayForPoint,
            priority: 0x1F4,
            msecUntilFade: 1_000,
            filledChiclets: UInt32(volume / volumeStep),
            totalChiclets: UInt32(100.0 / volumeStep),
            locked: false
        )
    }
    
    // MARK: Private
    
    private func acquirePrivileges() {
        let trusted = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
        let privOptions = [trusted: true] as CFDictionary
        let accessEnabled = AXIsProcessTrustedWithOptions(privOptions)
        
        if accessEnabled {
            Logger.warning(Constants.InnerMessages.accessEnabled)
        } else {
            Logger.warning(Constants.InnerMessages.accessDenied)
        }
    }
    
    private func startMediaKeyTap() {
        acquirePrivileges()
        
        let keys: [MediaKey] = [
            .volumeUp,
            .volumeDown,
            .mute
        ]
        
        mediaKeyTap?.stop()
        mediaKeyTap = MediaKeyTap(delegate: self, for: keys, observeBuiltIn: true)
        mediaKeyTap?.start()
    }
    
    private func observeMediaKeyOnAccessibiltiyApiChange() {
        let notificaion = NSNotification.Name(rawValue: Constants.Notifications.accessibility)
        
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(onAccessibilityNotification),
            name: notificaion,
            object: nil
        )
    }
    
    @objc
    private func onAccessibilityNotification(_ aNotification: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.startMediaKeyTap()
        }
    }
}

// MARK: - MediaKeyTapDelegate

extension MediaManagerImpl: MediaKeyTapDelegate {
    func handle(mediaKey: MediaKey, event: KeyEvent?, modifiers: NSEvent.ModifierFlags?) {
        delegate?.onMediaKeyTap(mediaKey: mediaKey)
    }
}

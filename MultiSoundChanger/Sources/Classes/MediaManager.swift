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
    // Debounce handle for `onAccessibilityNotification`. DistributedNotificationCenter is a
    // system-wide bus — any local process can post `com.apple.accessibility.api`, which our
    // handler responds to by tearing down and recreating the CGEventTap. Coalesce bursts
    // so a flood of spoofed notifications can't force us into a restart loop.
    private var accessibilityNotificationWork: DispatchWorkItem?
    private static let accessibilityNotificationDebounce: TimeInterval = 0.5

    init(delegate: MediaManagerDelegate) {
        self.delegate = delegate
    }

    deinit {
        // Cancel any still-scheduled accessibility-notification work so a late fire can't
        // reference a mid-deallocation self. Mirrors AudioManagerImpl.deinit's handling of
        // pendingApplyItem. Safe in practice because our weak-self capture no-ops when
        // self is nil, but eliminates the tiny pending work item the runloop would
        // otherwise hold for up to `accessibilityNotificationDebounce` seconds.
        accessibilityNotificationWork?.cancel()
        DistributedNotificationCenter.default().removeObserver(self)
    }

    // MARK: Public

    func listenMediaKeyTaps() {
        observeMediaKeyOnAccessibilityApiChange()
        acquirePrivileges()
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
        let keys: [MediaKey] = [
            .volumeUp,
            .volumeDown,
            .mute
        ]

        mediaKeyTap?.stop()
        mediaKeyTap = MediaKeyTap(delegate: self, for: keys, observeBuiltIn: true)
        mediaKeyTap?.start()
    }

    private func observeMediaKeyOnAccessibilityApiChange() {
        let notification = NSNotification.Name(rawValue: Constants.Notifications.accessibility)

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(onAccessibilityNotification),
            name: notification,
            object: nil
        )
    }

    @objc
    private func onAccessibilityNotification(_ aNotification: Notification) {
        // DistributedNotificationCenter delivers on main; coalesce with a cancellable work
        // item so a burst only results in one tap restart.
        accessibilityNotificationWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.startMediaKeyTap()
        }
        accessibilityNotificationWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.accessibilityNotificationDebounce, execute: work)
    }
}

// MARK: - MediaKeyTapDelegate

extension MediaManagerImpl: MediaKeyTapDelegate {
    func handle(mediaKey: MediaKey, event: KeyEvent?, modifiers: NSEvent.ModifierFlags?) {
        delegate?.onMediaKeyTap(mediaKey: mediaKey)
    }
}

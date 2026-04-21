//
//  Audio.swift
//  MultiSoundChanger
//
//  Created by Dmitry Medyuho on 03.04.17.
//  Copyright © 2017 Dmitry Medyuho. All rights reserved.
//

import AudioToolbox
import Cocoa
import Foundation

// `kAudioObjectPropertyElementMaster` was renamed to `kAudioObjectPropertyElementMain` in macOS 12;
// both symbols resolve to element 0 and the value is invariant across CoreAudio versions. Using the
// literal keeps the deployment floor at 11.0 without producing a deprecation warning on macOS 12+ SDKs.
private let kAudioPropertyElement: AudioObjectPropertyElement = 0

// MARK: - Listener token

// Opaque handle returned by `addXxxListener` and required for removal so the HAL can match
// the exact block pointer it registered.
final class AudioListenerToken {
    fileprivate let objectID: AudioObjectID
    fileprivate var address: AudioObjectPropertyAddress
    fileprivate let block: AudioObjectPropertyListenerBlock

    fileprivate init(objectID: AudioObjectID, address: AudioObjectPropertyAddress, block: @escaping AudioObjectPropertyListenerBlock) {
        self.objectID = objectID
        self.address = address
        self.block = block
    }
}

// MARK: - Protocols

protocol Audio {
    func getOutputDevices() -> [AudioDeviceID: String]?
    func isOutputDevice(deviceID: AudioDeviceID) -> Bool
    func getAggregateDeviceSubDeviceList(deviceID: AudioDeviceID) -> [AudioDeviceID]
    func isAggregateDevice(deviceID: AudioDeviceID) -> Bool
    func setDeviceVolume(deviceID: AudioDeviceID, masterChannelLevel: Float, leftChannelLevel: Float, rightChannelLevel: Float)
    func setDeviceMute(deviceID: AudioDeviceID, isMute: Bool)
    func setOutputDevice(newDeviceID: AudioDeviceID)
    func isDeviceMuted(deviceID: AudioDeviceID) -> Bool
    func getDeviceVolume(deviceID: AudioDeviceID) -> [Float]
    func getDefaultOutputDevice() -> AudioDeviceID

    // Property listeners — callers receive the `onChange` callback on the main queue.
    // Returns `nil` when HAL refuses the registration; callers should treat that as a no-op
    // subscription and not store the token.
    func addDevicesListener(onChange: @escaping () -> Void) -> AudioListenerToken?
    func addDefaultOutputDeviceListener(onChange: @escaping () -> Void) -> AudioListenerToken?
    func removeListener(_ token: AudioListenerToken)
}

// MARK: - Implementation

final class AudioImpl: Audio {
    private static let logQueue = DispatchQueue(label: "com.multisoundchanger.audio.log")
    private static let listenerQueue = DispatchQueue(label: "com.multisoundchanger.audio.listener")
    private static var lastLoggedTimes: [String: TimeInterval] = [:]
    private static let logCooldown: TimeInterval = 2.0
    private static let maxLoggedKeys = 64

    // Logs non-noErr statuses with a per-(op, status) 2-second cooldown so a disconnected device
    // can't flood the log. Returns `true` when the call succeeded.
    @discardableResult
    private func check(_ status: OSStatus, _ op: String) -> Bool {
        if status == noErr {
            return true
        }
        let key = "\(op):\(status)"
        let now = Date().timeIntervalSinceReferenceDate
        var shouldLog = false
        Self.logQueue.sync {
            if let last = Self.lastLoggedTimes[key], now - last < Self.logCooldown {
                shouldLog = false
            } else {
                // Hard cap to keep pathological devices (flap storms, unique-status churn) from
                // growing the cooldown dictionary without bound. Clearing loses some cooldown
                // memory briefly but is bounded-work and never leaks.
                if Self.lastLoggedTimes.count >= Self.maxLoggedKeys {
                    Self.lastLoggedTimes.removeAll(keepingCapacity: true)
                }
                Self.lastLoggedTimes[key] = now
                shouldLog = true
            }
        }
        if shouldLog {
            Logger.warning("CoreAudio \(op) failed: status=\(status)")
        }
        return false
    }

    func getOutputDevices() -> [AudioDeviceID: String]? {
        var result: [AudioDeviceID: String] = [:]
        let devices = getAllDevices()

        for device in devices where isOutputDevice(deviceID: device) {
            result[device] = getDeviceName(deviceID: device)
        }

        return result
    }

    func isOutputDevice(deviceID: AudioDeviceID) -> Bool {
        var propertySize: UInt32 = 0

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: AudioObjectPropertySelector(kAudioDevicePropertyStreams),
            mScope: AudioObjectPropertyScope(kAudioDevicePropertyScopeOutput),
            mElement: kAudioPropertyElement)

        check(
            AudioObjectGetPropertyDataSize(deviceID, &propertyAddress, 0, nil, &propertySize),
            "isOutputDevice:GetPropertyDataSize"
        )

        return propertySize > 0
    }

    func getAggregateDeviceSubDeviceList(deviceID: AudioDeviceID) -> [AudioDeviceID] {
        let subDevicesCount = getNumberOfSubDevices(deviceID: deviceID)
        guard subDevicesCount > 0 else {
            return []
        }
        var subDevices = [AudioDeviceID](repeating: 0, count: Int(subDevicesCount))

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: AudioObjectPropertySelector(kAudioAggregateDevicePropertyActiveSubDeviceList),
            mScope: AudioObjectPropertyScope(kAudioObjectPropertyScopeGlobal),
            mElement: kAudioPropertyElement)

        var subDevicesSize = subDevicesCount * UInt32(MemoryLayout<AudioDeviceID>.size)

        guard check(
            AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &subDevicesSize, &subDevices),
            "getAggregateDeviceSubDeviceList:GetPropertyData"
        ) else {
            return []
        }

        return subDevices
    }

    func isAggregateDevice(deviceID: AudioDeviceID) -> Bool {
        let deviceType = getDeviceTransportType(deviceID: deviceID)
        return deviceType == kAudioDeviceTransportTypeAggregate
    }

    func isDeviceMuted(deviceID: AudioDeviceID) -> Bool {
        var mutedValue: UInt32 = 0
        var propertySize = UInt32(MemoryLayout<UInt32>.size)

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: AudioObjectPropertySelector(kAudioDevicePropertyMute),
            mScope: AudioObjectPropertyScope(kAudioDevicePropertyScopeOutput),
            mElement: kAudioPropertyElement)

        guard check(
            AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &propertySize, &mutedValue),
            "isDeviceMuted:GetPropertyData"
        ) else {
            return false
        }

        return mutedValue == 1
    }

    func setDeviceVolume(deviceID: AudioDeviceID, masterChannelLevel: Float, leftChannelLevel: Float, rightChannelLevel: Float) {
        var leftLevel = leftChannelLevel
        var rightLevel = rightChannelLevel
        var masterLevel = masterChannelLevel

        var masterLevelPropertyAddress = volumeScalarPropertyAddress(element: 0)
        var leftLevelPropertyAddress = volumeScalarPropertyAddress(element: 1)
        var rightLevelPropertyAddress = volumeScalarPropertyAddress(element: 2)

        var size = UInt32(0)

        if check(
            AudioObjectGetPropertyDataSize(deviceID, &masterLevelPropertyAddress, 0, nil, &size),
            "setDeviceVolume:master:GetPropertyDataSize"
        ) {
            check(
                AudioObjectSetPropertyData(deviceID, &masterLevelPropertyAddress, 0, nil, size, &masterLevel),
                "setDeviceVolume:master:SetPropertyData"
            )
        }

        if check(
            AudioObjectGetPropertyDataSize(deviceID, &leftLevelPropertyAddress, 0, nil, &size),
            "setDeviceVolume:left:GetPropertyDataSize"
        ) {
            check(
                AudioObjectSetPropertyData(deviceID, &leftLevelPropertyAddress, 0, nil, size, &leftLevel),
                "setDeviceVolume:left:SetPropertyData"
            )
        }

        if check(
            AudioObjectGetPropertyDataSize(deviceID, &rightLevelPropertyAddress, 0, nil, &size),
            "setDeviceVolume:right:GetPropertyDataSize"
        ) {
            check(
                AudioObjectSetPropertyData(deviceID, &rightLevelPropertyAddress, 0, nil, size, &rightLevel),
                "setDeviceVolume:right:SetPropertyData"
            )
        }
    }

    func setDeviceMute(deviceID: AudioDeviceID, isMute: Bool) {
        var mutedValue: UInt32 = isMute ? 1 : 0
        let propertySize = UInt32(MemoryLayout<UInt32>.size)

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: AudioObjectPropertySelector(kAudioDevicePropertyMute),
            mScope: AudioObjectPropertyScope(kAudioDevicePropertyScopeOutput),
            mElement: kAudioPropertyElement)

        check(
            AudioObjectSetPropertyData(deviceID, &propertyAddress, 0, nil, propertySize, &mutedValue),
            "setDeviceMute:SetPropertyData"
        )
    }

    func setOutputDevice(newDeviceID: AudioDeviceID) {
        let propertySize = UInt32(MemoryLayout<UInt32>.size)
        var deviceID = newDeviceID

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: AudioObjectPropertySelector(kAudioHardwarePropertyDefaultOutputDevice),
            mScope: AudioObjectPropertyScope(kAudioObjectPropertyScopeGlobal),
            mElement: kAudioPropertyElement)

        check(
            AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, propertySize, &deviceID),
            "setOutputDevice:SetPropertyData"
        )
    }

    func getDeviceVolume(deviceID: AudioDeviceID) -> [Float] {
        var leftLevel = Float32(0)
        var rightLevel = Float32(0)
        var masterLevel = Float32(0)

        var masterLevelPropertyAddress = volumeScalarPropertyAddress(element: 0)
        var leftLevelPropertyAddress = volumeScalarPropertyAddress(element: 1)
        var rightLevelPropertyAddress = volumeScalarPropertyAddress(element: 2)

        var size = UInt32(0)

        if check(
            AudioObjectGetPropertyDataSize(deviceID, &masterLevelPropertyAddress, 0, nil, &size),
            "getDeviceVolume:master:GetPropertyDataSize"
        ) {
            check(
                AudioObjectGetPropertyData(deviceID, &masterLevelPropertyAddress, 0, nil, &size, &masterLevel),
                "getDeviceVolume:master:GetPropertyData"
            )
        }

        if check(
            AudioObjectGetPropertyDataSize(deviceID, &leftLevelPropertyAddress, 0, nil, &size),
            "getDeviceVolume:left:GetPropertyDataSize"
        ) {
            check(
                AudioObjectGetPropertyData(deviceID, &leftLevelPropertyAddress, 0, nil, &size, &leftLevel),
                "getDeviceVolume:left:GetPropertyData"
            )
        }

        if check(
            AudioObjectGetPropertyDataSize(deviceID, &rightLevelPropertyAddress, 0, nil, &size),
            "getDeviceVolume:right:GetPropertyDataSize"
        ) {
            check(
                AudioObjectGetPropertyData(deviceID, &rightLevelPropertyAddress, 0, nil, &size, &rightLevel),
                "getDeviceVolume:right:GetPropertyData"
            )
        }

        return [masterLevel, leftLevel, rightLevel]
    }

    func getDefaultOutputDevice() -> AudioDeviceID {
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var deviceID = kAudioDeviceUnknown

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: AudioObjectPropertySelector(kAudioHardwarePropertyDefaultOutputDevice),
            mScope: AudioObjectPropertyScope(kAudioObjectPropertyScopeGlobal),
            mElement: kAudioPropertyElement)

        check(
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &propertySize, &deviceID),
            "getDefaultOutputDevice:GetPropertyData"
        )

        return deviceID
    }

    private func getDeviceTransportType(deviceID: AudioDeviceID) -> AudioDevicePropertyID {
        var deviceTransportType = AudioDevicePropertyID()
        var propertySize = UInt32(MemoryLayout<AudioDevicePropertyID>.size)

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: AudioObjectPropertySelector(kAudioDevicePropertyTransportType),
            mScope: AudioObjectPropertyScope(kAudioObjectPropertyScopeGlobal),
            mElement: kAudioPropertyElement)

        check(
            AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &propertySize, &deviceTransportType),
            "getDeviceTransportType:GetPropertyData"
        )

        return deviceTransportType
    }

    // MARK: Listeners

    func addDevicesListener(onChange: @escaping () -> Void) -> AudioListenerToken? {
        return addHardwareListener(selector: kAudioHardwarePropertyDevices, op: "addDevicesListener", onChange: onChange)
    }

    func addDefaultOutputDeviceListener(onChange: @escaping () -> Void) -> AudioListenerToken? {
        return addHardwareListener(selector: kAudioHardwarePropertyDefaultOutputDevice, op: "addDefaultOutputDeviceListener", onChange: onChange)
    }

    func removeListener(_ token: AudioListenerToken) {
        check(
            AudioObjectRemovePropertyListenerBlock(token.objectID, &token.address, Self.listenerQueue, token.block),
            "removeListener"
        )
    }

    private func addHardwareListener(selector: AudioObjectPropertySelector, op: String, onChange: @escaping () -> Void) -> AudioListenerToken? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: AudioObjectPropertyScope(kAudioObjectPropertyScopeGlobal),
            mElement: kAudioPropertyElement
        )
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            DispatchQueue.main.async {
                onChange()
            }
        }
        guard check(
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, Self.listenerQueue, block),
            op
        ) else {
            return nil
        }
        return AudioListenerToken(objectID: AudioObjectID(kAudioObjectSystemObject), address: address, block: block)
    }

    // MARK: Helpers

    private func volumeScalarPropertyAddress(element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        return AudioObjectPropertyAddress(
            mSelector: AudioObjectPropertySelector(kAudioDevicePropertyVolumeScalar),
            mScope: AudioObjectPropertyScope(kAudioDevicePropertyScopeOutput),
            mElement: element
        )
    }

    private func getNumberOfDevices() -> UInt32 {
        var propertySize: UInt32 = 0

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: AudioObjectPropertySelector(kAudioHardwarePropertyDevices),
            mScope: AudioObjectPropertyScope(kAudioObjectPropertyScopeGlobal),
            mElement: kAudioPropertyElement)

        check(
            AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &propertySize),
            "getNumberOfDevices:GetPropertyDataSize"
        )

        return propertySize / UInt32(MemoryLayout<AudioDeviceID>.size)
    }

    private func getNumberOfSubDevices(deviceID: AudioDeviceID) -> UInt32 {
        var propertySize: UInt32 = 0

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: AudioObjectPropertySelector(kAudioAggregateDevicePropertyActiveSubDeviceList),
            mScope: AudioObjectPropertyScope(kAudioObjectPropertyScopeGlobal),
            mElement: kAudioPropertyElement)

        check(
            AudioObjectGetPropertyDataSize(deviceID, &propertyAddress, 0, nil, &propertySize),
            "getNumberOfSubDevices:GetPropertyDataSize"
        )

        return propertySize / UInt32(MemoryLayout<AudioDeviceID>.size)
    }

    private func getDeviceName(deviceID: AudioDeviceID) -> String {
        var propertySize = UInt32(MemoryLayout<CFString>.size)

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: AudioObjectPropertySelector(kAudioDevicePropertyDeviceNameCFString),
            mScope: AudioObjectPropertyScope(kAudioObjectPropertyScopeGlobal),
            mElement: kAudioPropertyElement)

        var result: CFString = "" as CFString

        check(
            AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &propertySize, &result),
            "getDeviceName:GetPropertyData"
        )

        return result as String
    }

    private func getAllDevices() -> [AudioDeviceID] {
        let devicesCount = getNumberOfDevices()
        guard devicesCount > 0 else {
            return []
        }
        var devices = [AudioDeviceID](repeating: 0, count: Int(devicesCount))

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: AudioObjectPropertySelector(kAudioHardwarePropertyDevices),
            mScope: AudioObjectPropertyScope(kAudioObjectPropertyScopeGlobal),
            mElement: kAudioPropertyElement)

        var devicesSize = devicesCount * UInt32(MemoryLayout<AudioDeviceID>.size)

        guard check(
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &devicesSize, &devices),
            "getAllDevices:GetPropertyData"
        ) else {
            return []
        }

        return devices
    }
}

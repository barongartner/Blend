// Thin typed wrappers around the Core Audio HAL property API, plus the
// tap + private aggregate device pair that captures one process's audio.
//
// Adapted from Split (barongartner/Split), which in turn follows AudioCap by
// Guilherme Rambo (https://github.com/insidegui/AudioCap, BSD-2-Clause).
// Two things here are load-bearing and non-obvious, learned there:
//  - The output device MUST be the aggregate's main sub-device. A tap-only
//    aggregate "works" (every call returns noErr) and delivers pure silence.
//  - Don't touch CATapDescription.isExclusive after the convenience
//    initializer — it inverts include/exclude semantics; failure mode: silence.

import Foundation
import CoreAudio
import AudioToolbox

struct CoreAudioError: Error, CustomStringConvertible {
    let message: String
    let status: OSStatus
    var description: String { "\(message) (OSStatus \(status))" }
}

enum CA {

    static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func read<T>(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, into value: inout T) -> OSStatus {
        var addr = address(selector, scope: scope)
        var size = UInt32(MemoryLayout<T>.size)
        return withUnsafeMutableBytes(of: &value) { buf in
            AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, buf.baseAddress!)
        }
    }

    static func readString(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var value: CFString = "" as CFString
        var addr = address(selector)
        var size = UInt32(MemoryLayout<CFString>.size)
        let err = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, ptr)
        }
        guard err == noErr else { return nil }
        let s = value as String
        return s.isEmpty ? nil : s
    }

    static func translatePID(_ pid: pid_t) -> AudioObjectID? {
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var mutablePID = pid
        var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let err = AudioObjectGetPropertyData(systemObject, &addr, UInt32(MemoryLayout<pid_t>.size), &mutablePID, &size, &objectID)
        guard err == noErr, objectID != kAudioObjectUnknown else { return nil }
        return objectID
    }

    static func defaultOutputDevice() -> AudioDeviceID? {
        var id = AudioDeviceID(kAudioObjectUnknown)
        guard read(systemObject, kAudioHardwarePropertyDefaultOutputDevice, into: &id) == noErr, id != kAudioObjectUnknown else { return nil }
        return id
    }

    static func deviceUID(_ id: AudioDeviceID) -> String? {
        readString(id, kAudioDevicePropertyDeviceUID)
    }

    static func transportType(_ id: AudioDeviceID) -> UInt32 {
        var t: UInt32 = 0
        _ = read(id, kAudioDevicePropertyTransportType, into: &t)
        return t
    }

    static func allDevices() -> [AudioDeviceID] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObject, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(systemObject, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func hasOutputStreams(_ id: AudioDeviceID) -> Bool {
        var addr = address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr && size > 0
    }

    /// The device that clocks the capture aggregate. Never Bluetooth: starting
    /// IO on an aggregate that contains a Bluetooth headset can open its mic,
    /// which drops the whole headset to 8 kHz hands-free audio. Nothing is
    /// played through this device anyway (the tap mutes the process).
    static func captureClockDeviceUID() -> String? {
        let bluetooth: Set<UInt32> = [kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE, kAudioDeviceTransportTypeAirPlay]
        if let def = defaultOutputDevice(), !bluetooth.contains(transportType(def)), let uid = deviceUID(def) { return uid }
        let builtIn = allDevices().first { transportType($0) == kAudioDeviceTransportTypeBuiltIn && hasOutputStreams($0) }
        if let builtIn, let uid = deviceUID(builtIn) { return uid }
        let any = allDevices().first { !bluetooth.contains(transportType($0)) && hasOutputStreams($0) }
        if let any, let uid = deviceUID(any) { return uid }
        return defaultOutputDevice().flatMap { deviceUID($0) }
    }

    static func tapFormat(_ tapID: AudioObjectID) -> AudioStreamBasicDescription? {
        var asbd = AudioStreamBasicDescription()
        guard read(tapID, kAudioTapPropertyFormat, into: &asbd) == noErr, asbd.mSampleRate > 0 else { return nil }
        return asbd
    }
}

/// One process tap + one private aggregate device.
final class TapAggregate {
    let tapID: AudioObjectID
    let aggregateID: AudioObjectID
    let format: AudioStreamBasicDescription
    private(set) var invalidated = false

    init(processObjectID: AudioObjectID, destinationUID: String, mute: Bool) throws {
        let desc = CATapDescription(stereoMixdownOfProcesses: [processObjectID])
        desc.uuid = UUID()
        desc.muteBehavior = mute ? .mutedWhenTapped : .unmuted
        desc.isPrivate = true

        var tapID = AudioObjectID(kAudioObjectUnknown)
        var err = AudioHardwareCreateProcessTap(desc, &tapID)
        guard err == noErr, tapID != kAudioObjectUnknown else {
            throw CoreAudioError(message: "process tap creation failed", status: err)
        }
        self.tapID = tapID

        let aggDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Blend-\(desc.uuid.uuidString.prefix(8))",
            kAudioAggregateDeviceUIDKey: "com.barongartner.Blend.agg.\(desc.uuid.uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: destinationUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: destinationUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: desc.uuid.uuidString,
            ]],
        ]
        var aggID = AudioObjectID(kAudioObjectUnknown)
        err = AudioHardwareCreateAggregateDevice(aggDescription as CFDictionary, &aggID)
        guard err == noErr, aggID != kAudioObjectUnknown else {
            AudioHardwareDestroyProcessTap(tapID)
            throw CoreAudioError(message: "aggregate device creation failed", status: err)
        }
        aggregateID = aggID

        guard let format = CA.tapFormat(tapID) else {
            AudioHardwareDestroyAggregateDevice(aggID)
            AudioHardwareDestroyProcessTap(tapID)
            throw CoreAudioError(message: "could not read tap format", status: -1)
        }
        self.format = format
    }

    func invalidate() {
        guard !invalidated else { return }
        invalidated = true
        AudioHardwareDestroyAggregateDevice(aggregateID)
        AudioHardwareDestroyProcessTap(tapID)
    }

    deinit { invalidate() }
}

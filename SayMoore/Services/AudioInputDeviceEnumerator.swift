import CoreAudio
import Foundation
import os

/// A CoreAudio input device the user can pin. `transportType` and
/// `nominalSampleRate` are captured here so a future low-quality-mic policy can
/// classify without re-querying.
struct AudioInputDevice: Identifiable, Equatable, Sendable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let transportType: UInt32
    let nominalSampleRate: Double
}

/// Injectable seam. The real implementation talks to CoreAudio; tests inject
/// a fake so device selection is exercisable without hardware.
protocol AudioInputDeviceEnumerating: Sendable {
    func inputDevices() -> [AudioInputDevice]
    func deviceID(forUID uid: String) -> AudioDeviceID?
    func defaultInputDevice() -> AudioInputDevice?
}

/// Stateless CoreAudio queries. No mutable state → Sendable. Every OSStatus
/// is checked; failures degrade to empty/nil rather than crashing.
final class CoreAudioInputDeviceEnumerator: AudioInputDeviceEnumerating {
    init() {}

    func inputDevices() -> [AudioInputDevice] {
        allDeviceIDs().compactMap { id in
            guard hasInputStreams(id),
                  let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(id, kAudioDevicePropertyDeviceNameCFString)
            else { return nil }
            return AudioInputDevice(
                id: id, uid: uid, name: name,
                transportType: transportType(id),
                nominalSampleRate: nominalSampleRate(id)
            )
        }
    }

    func deviceID(forUID uid: String) -> AudioDeviceID? {
        inputDevices().first { $0.uid == uid }?.id
    }

    func defaultInputDevice() -> AudioInputDevice? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != 0,
              let uid = stringProperty(deviceID, kAudioDevicePropertyDeviceUID),
              let name = stringProperty(deviceID, kAudioDevicePropertyDeviceNameCFString)
        else { return nil }
        return AudioInputDevice(
            id: deviceID, uid: uid, name: name,
            transportType: transportType(deviceID),
            nominalSampleRate: nominalSampleRate(deviceID)
        )
    }

    // MARK: - CoreAudio helpers

    private func allDeviceIDs() -> [AudioDeviceID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0
        else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids
    }

    private func hasInputStreams(_ id: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0
        else { return false }
        let data = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { data.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, data) == noErr
        else { return false }
        let abl = UnsafeMutableAudioBufferListPointer(
            data.assumingMemoryBound(to: AudioBufferList.self)
        )
        for buffer in abl where buffer.mNumberChannels > 0 { return true }
        return false
    }

    private func stringProperty(_ id: AudioDeviceID,
                                _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var cfStr: CFString?
        let status = withUnsafeMutablePointer(to: &cfStr) {
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0)
        }
        guard status == noErr, let cfStr else { return nil }
        return cfStr as String
    }

    private func transportType(_ id: AudioDeviceID) -> UInt32 {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        _ = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value)
        return value
    }

    private func nominalSampleRate(_ id: AudioDeviceID) -> Double {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = Double(0)
        var size = UInt32(MemoryLayout<Double>.size)
        _ = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value)
        return value
    }
}

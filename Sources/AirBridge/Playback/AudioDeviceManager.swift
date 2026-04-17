import CoreAudio
import os

enum AudioDeviceManager {
    static func allOutputDevices(engineTargetUID: String? = nil) -> [AudioOutputDeviceInfo] {
        let deviceIDs = getOutputDeviceIDs()
        let defaultID = getDefaultOutputDeviceID()

        return deviceIDs.compactMap { devID -> AudioOutputDeviceInfo? in
            guard let uid = deviceUID(for: devID) else { return nil }
            let name = deviceName(for: devID)
            let transport = transportType(for: devID)

            return AudioOutputDeviceInfo(
                id: uid,
                name: name,
                transport: transport,
                isSystemDefault: devID == defaultID,
                isEngineTarget: uid == engineTargetUID
            )
        }.sorted { $0.name < $1.name }
    }

    static func getDefaultOutputDeviceID() -> AudioDeviceID {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        )
        return deviceID
    }

    static func deviceUID(for id: AudioDeviceID) -> String? {
        var size = UInt32(MemoryLayout<CFString>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: Unmanaged<CFString>?
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &uid)
        guard status == noErr, let cfStr = uid?.takeRetainedValue() else { return nil }
        return cfStr as String
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        let deviceIDs = getOutputDeviceIDs()
        for devID in deviceIDs {
            if deviceUID(for: devID) == uid {
                return devID
            }
        }
        return nil
    }

    static func transportType(for id: AudioDeviceID) -> AudioTransport {
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rawTransport: UInt32 = 0
        AudioObjectGetPropertyData(id, &address, 0, nil, &size, &rawTransport)

        switch rawTransport {
        case kAudioDeviceTransportTypeBuiltIn: return .builtIn
        case kAudioDeviceTransportTypeUSB: return .usb
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return .bluetooth
        case kAudioDeviceTransportTypeHDMI: return .hdmi
        case kAudioDeviceTransportTypeAirPlay: return .airplay
        case kAudioDeviceTransportTypeVirtual: return .virtual
        default: return .other
        }
    }

    // MARK: - Private

    private static func getOutputDeviceIDs() -> [AudioDeviceID] {
        var size: UInt32 = 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size
        ) == noErr else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceIDs
        ) == noErr else { return [] }

        return deviceIDs.filter { hasOutputChannels($0) }
    }

    private static func hasOutputChannels(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr else {
            return false
        }
        let bufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
        defer { bufferList.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, bufferList) == noErr else {
            return false
        }
        return UnsafeMutableAudioBufferListPointer(bufferList).reduce(0) { $0 + Int($1.mNumberChannels) } > 0
    }

    private static func deviceName(for id: AudioDeviceID) -> String {
        var size = UInt32(MemoryLayout<CFString>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name)
        guard status == noErr, let cfStr = name?.takeRetainedValue() else { return "Unknown" }
        return cfStr as String
    }
}

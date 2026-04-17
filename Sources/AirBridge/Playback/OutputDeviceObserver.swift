import CoreAudio
import os

final class OutputDeviceObserver: Sendable {
    private let callback: @Sendable (AudioDeviceID) -> Void

    init(onChange callback: @escaping @Sendable (AudioDeviceID) -> Void) {
        self.callback = callback
        startListening()
    }

    private func startListening() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let selfPtr = Unmanaged.passRetained(self).toOpaque()
        AudioObjectAddPropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            outputDeviceChanged,
            selfPtr
        )
        Log.output.info("OutputDeviceObserver started")
    }

    func stopListening() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            outputDeviceChanged,
            Unmanaged.passUnretained(self).toOpaque()
        )
        Log.output.info("OutputDeviceObserver stopped")
    }

    deinit {
        stopListening()
    }
}

private func outputDeviceChanged(
    _ objectID: AudioObjectID,
    _ numberAddresses: UInt32,
    _ addresses: UnsafePointer<AudioObjectPropertyAddress>,
    _ clientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let clientData else { return noErr }
    let observer = Unmanaged<OutputDeviceObserver>.fromOpaque(clientData).takeUnretainedValue()
    let newDefault = AudioDeviceManager.getDefaultOutputDeviceID()
    Log.output.info("System default output changed to device ID \(newDefault)")
    observer.callback(newDefault)
    return noErr
}

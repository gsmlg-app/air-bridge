import CoreAudio
import Foundation
import os

final class OutputDeviceObserver: @unchecked Sendable {
    final class ListenerToken: @unchecked Sendable {
        let block: AudioObjectPropertyListenerBlock

        init(block: @escaping AudioObjectPropertyListenerBlock) {
            self.block = block
        }
    }

    typealias ListenerOperation = (DispatchQueue, ListenerToken) -> OSStatus

    fileprivate let callback: @Sendable (AudioDeviceID) -> Void
    private let listenerQueue: DispatchQueue
    private let listenerToken: ListenerToken
    private let removeListener: ListenerOperation
    private let listenerRegistered: Bool

    convenience init(onChange callback: @escaping @Sendable (AudioDeviceID) -> Void) {
        self.init(
            addListener: Self.addSystemListener,
            removeListener: Self.removeSystemListener,
            onChange: callback
        )
    }

    init(
        listenerQueue: DispatchQueue = DispatchQueue(label: "com.gsmlg.airbridge.output-device-observer"),
        addListener: ListenerOperation,
        removeListener: @escaping ListenerOperation,
        onChange callback: @escaping @Sendable (AudioDeviceID) -> Void
    ) {
        let target = OutputDeviceListenerTarget()
        let listener: AudioObjectPropertyListenerBlock = { [target] _, _ in
            target.outputDeviceDidChange()
        }
        let listenerToken = ListenerToken(block: listener)

        self.callback = callback
        self.listenerQueue = listenerQueue
        self.listenerToken = listenerToken
        self.removeListener = removeListener
        self.listenerRegistered = addListener(listenerQueue, listenerToken) == noErr
        target.observer = self

        if listenerRegistered {
            Log.output.info("OutputDeviceObserver started")
        } else {
            Log.output.error("OutputDeviceObserver failed to start")
        }
    }

    deinit {
        guard listenerRegistered else { return }
        _ = removeListener(listenerQueue, listenerToken)
        Log.output.info("OutputDeviceObserver stopped")
    }

    private static func addSystemListener(
        queue: DispatchQueue,
        listener: ListenerToken
    ) -> OSStatus {
        var address = defaultOutputDeviceAddress
        return AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            queue,
            listener.block
        )
    }

    private static func removeSystemListener(
        queue: DispatchQueue,
        listener: ListenerToken
    ) -> OSStatus {
        var address = defaultOutputDeviceAddress
        return AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            queue,
            listener.block
        )
    }

    private static var defaultOutputDeviceAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}

private final class OutputDeviceListenerTarget: @unchecked Sendable {
    weak var observer: OutputDeviceObserver?

    func outputDeviceDidChange() {
        guard let observer else { return }
        let newDefault = AudioDeviceManager.getDefaultOutputDeviceID()
        Log.output.info("System default output changed to device ID \(newDefault)")
        observer.callback(newDefault)
    }
}

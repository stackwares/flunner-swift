// Adapted from @expo/serve-sim. Apache-2.0; see LICENSE and NOTICE.
import Foundation
import CoreDeviceKeyboard

/// A narrow adapter for CoreDevice's private Swift API. Apple does not ship its
/// module interface, so the C target preserves the ABI through guarded symbol
/// trampolines. No private symbol is a load-time dependency of Flunner.
public actor SimulatorKeyboard {

    private enum BridgeError: Error { case unavailable, deviceUnavailable, initializationTimedOut, resetDuringLookup }

    private var manager: CoreDeviceManagerObject?
    private var generation = 0
    private var capabilities: [String: CoreDeviceCapabilityObject] = [:]
    private func remoteDevice(udid: String) async throws -> CoreDeviceRemoteDevice {
        guard SSCoreDeviceInitialize() else { throw BridgeError.unavailable }

        if manager == nil {
            // Initializes resilient class metadata and field offsets before
            // using the class metadata's allocating initializer.
            _ = coreDeviceSharedManager()
            guard let managerMetadata = SSCoreDeviceSymbol("$s10CoreDevice0B7ManagerCN"),
                  let visibilityMetadata = SSCoreDeviceSymbol("$s10CoreDevice0B15VisibilityClassON"),
                  let visibilityType = unsafeBitCast(visibilityMetadata, to: Any.Type.self) as? any Hashable.Type
            else { throw BridgeError.unavailable }
            let managerType = unsafeBitCast(managerMetadata, to: CoreDeviceManagerObject.Type.self)
            let visibilitySet = Self.makeVisibilitySet(visibilityType)
            manager = withExtendedLifetime(visibilitySet) {
                let rawSet = withUnsafePointer(to: visibilitySet) {
                    UnsafeRawPointer($0).load(as: UnsafeMutableRawPointer.self)
                }
                // The private initializer consumes the Set. Keep the original
                // Any-owned value alive until initialization has completed.
                SSCoreDeviceRetainBridgeObject(rawSet)
                return managerType.create(connection: coreDeviceServiceConnection(), allowed: rawSet)
            }
        }
        guard let manager else { throw BridgeError.unavailable }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !manager.initialized() {
            guard ContinuousClock.now < deadline else { throw BridgeError.initializationTimedOut }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard let device = manager.allDevices().first(where: { $0.identifier().uuidString.caseInsensitiveCompare(udid) == .orderedSame })
        else { throw BridgeError.deviceUnavailable }
        return device
    }

    private static func makeVisibilitySet<T: Hashable>(_: T.Type) -> Any {
        // Open Apple's actual enum type, using its allCases getter rather than
        // constructing enum tags or hashing a substitute Swift type.
        let cases = unsafeBitCast(coreDeviceVisibilityAllCases(), to: [T].self)
        return Set(cases)
    }

    private func capability(udid: String, metadataSymbol: String, witnessSymbol: String) async throws -> CoreDeviceCapabilityObject {
        let key = "\(udid):\(metadataSymbol)"
        if let existing = capabilities[key] { return existing }
        let generation = self.generation
        let device = try await remoteDevice(udid: udid)

        guard let metadata = SSCoreDeviceSymbol(metadataSymbol),
              let witness = SSCoreDeviceSymbol(witnessSymbol)
        else { throw BridgeError.unavailable }
        let capability = CoreDeviceCapabilityObject()
        let emptyStaticMember = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
        defer { emptyStaticMember.deallocate() }
        // CapabilityStaticMember<T> is empty but resilient: its generic
        // method takes an address, actual T metadata, and its conformance.
        try await device.implementation(capability.storage, emptyStaticMember, metadata, witness)
        capability.initialized = true
        // A lookup may resume after the preview has closed or reloaded.
        guard generation == self.generation else { throw BridgeError.resetDuringLookup }
        capabilities[key] = capability
        return capability
    }

    private var heldKeys: [String: Set<UInt32>] = [:]
    public init() {}

    /// Returns false when this Xcode/device cannot provide CoreDevice input.
    /// The caller can then keep its existing simulator keyboard transport.
    public func send(device: String, usage: UInt32, down: Bool) async -> Bool {
        guard UUID(uuidString: device) != nil, usage <= 255,
              SSCoreDeviceKeyboardAvailable() else { return false }
        let metadata = "$s10CoreDevice21KeyboardHIDCapabilityVN"
        do {
            let keyboard = try await capability(udid: device, metadataSymbol: metadata,
                witnessSymbol: "$s10CoreDevice21KeyboardHIDCapabilityVAA0B10CapabilityAAWP")
            guard SSCoreDeviceSendKey(keyboard.storage, usage, down) else {
                capabilities.removeValue(forKey: "\(device):\(metadata)")
                return false
            }
            if down { heldKeys[device, default: []].insert(usage) }
            else { heldKeys[device]?.remove(usage) }
            // CoreDevice returns before the guest applies modifier state.
            // Pace replies so an immediate letter cannot overtake Shift/Command.
            try? await Task.sleep(for: .milliseconds(30))
            return true
        } catch { return false }
    }

    /// A closed preview must never leave Shift or another key held in iOS.
    public func releaseAll() {
        generation += 1
        for (device, usages) in heldKeys {
            guard let keyboard = capabilities["\(device):$s10CoreDevice21KeyboardHIDCapabilityVN"] else { continue }
            for usage in usages { _ = SSCoreDeviceSendKey(keyboard.storage, usage, false) }
        }
        heldKeys.removeAll()
        capabilities.removeAll()
    }

}
private protocol CoreDeviceServiceConnection {}
private protocol CoreDeviceOpaqueCapability {}

@_silgen_name("SSCDShared")
private func coreDeviceSharedManager() -> CoreDeviceManagerObject
@_silgen_name("SSCDConnection")
private func coreDeviceServiceConnection() -> any CoreDeviceServiceConnection
@_silgen_name("SSCDVisibilityAllCases")
private func coreDeviceVisibilityAllCases() -> UnsafeRawPointer

private class CoreDeviceManagerObject {
    @_silgen_name("SSCDCreateManager")
    static func create(connection: __owned any CoreDeviceServiceConnection, allowed: UnsafeRawPointer) -> CoreDeviceManagerObject
    @_silgen_name("SSCDAllDevices")
    final func allDevices() -> [CoreDeviceRemoteDevice]
    @_silgen_name("SSCDInitialized")
    final func initialized() -> Bool
}

class CoreDeviceRemoteDevice {
    @_silgen_name("SSCDIdentifier")
    final func identifier() -> UUID
    @_silgen_name("SSCDImplementation")
    final func implementation(_ result: UnsafeMutableRawPointer, _ empty: UnsafeRawPointer, _ metadata: UnsafeRawPointer, _ witness: UnsafeRawPointer) async throws
}

final class CoreDeviceCapabilityObject {
    let storage = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<any CoreDeviceOpaqueCapability>.size, alignment: MemoryLayout<any CoreDeviceOpaqueCapability>.alignment)
    var initialized = false

    deinit {
        if initialized {
            // Swift destroys the existential using the actual implementation's
            // metadata, including boxed values if Apple changes the type.
            storage.assumingMemoryBound(to: (any CoreDeviceOpaqueCapability).self).deinitialize(count: 1)
        }
        storage.deallocate()
    }
}

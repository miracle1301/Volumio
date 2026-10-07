import AudioToolbox
import CoreAudio
import Darwin
import Foundation

struct CoreAudioError: LocalizedError {
    let status: OSStatus
    let operation: String

    var errorDescription: String? {
        let n = UInt32(bitPattern: status)
        let bytes = [24, 16, 8, 0].map { UInt8((n >> $0) & 0xFF) }
        let fourCC = bytes.allSatisfy { $0 >= 32 && $0 < 127 }
            ? "'\(String(bytes: bytes, encoding: .ascii) ?? "")'"
            : "\(status)"
        return "\(operation) thất bại (\(fourCC))"
    }
}

@inline(__always)
func check(_ status: OSStatus, _ operation: String) throws {
    guard status == noErr else { throw CoreAudioError(status: status, operation: operation) }
}

extension AudioObjectID {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let unknown = AudioObjectID(kAudioObjectUnknown)

    private func address(_ selector: AudioObjectPropertySelector,
                         _ scope: AudioObjectPropertyScope) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    func read<T: BitwiseCopyable>(_ selector: AudioObjectPropertySelector,
                 scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                 default value: T) throws -> T {
        var addr = address(selector, scope)
        var size = UInt32(MemoryLayout<T>.size)
        var result = value
        try check(AudioObjectGetPropertyData(self, &addr, 0, nil, &size, &result), "Đọc thuộc tính")
        return result
    }

    func readString(_ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector, kAudioObjectPropertyScopeGlobal)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(self, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    func readObjectList(_ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var addr = address(selector, kAudioObjectPropertyScopeGlobal)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(self, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var list = [AudioObjectID](repeating: .unknown, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(self, &addr, 0, nil, &size, &list) == noErr else { return [] }
        return list
    }

    static func defaultOutputDevice() -> AudioObjectID? {
        let id = (try? AudioObjectID.system.read(kAudioHardwarePropertyDefaultOutputDevice, default: AudioObjectID.unknown)) ?? .unknown
        return id == .unknown ? nil : id
    }
}

// MARK: - System (master) volume of the output device

enum SystemVolume {
    private static var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain)

    static func get(_ device: AudioObjectID) -> Float? {
        guard AudioObjectHasProperty(device, &addr) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    static func set(_ device: AudioObjectID, _ volume: Float) {
        var value = Float32(min(max(volume, 0), 1))
        AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
    }

    private static var muteAddr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain)

    static func isMuted(_ device: AudioObjectID) -> Bool? {
        guard AudioObjectHasProperty(device, &muteAddr) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &muteAddr, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }

    static func setMuted(_ device: AudioObjectID, _ muted: Bool) {
        var value: UInt32 = muted ? 1 : 0
        AudioObjectSetPropertyData(device, &muteAddr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }
}

// MARK: - Process → owning .app bundle

private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
private let responsiblePID: ResponsibleFn? = {
    guard let handle = dlopen(nil, RTLD_NOW),
          let sym = dlsym(handle, "responsibility_get_pid_responsible_for_pid") else { return nil }
    return unsafeBitCast(sym, to: ResponsibleFn.self)
}()

func executablePath(of pid: pid_t) -> String? {
    var buffer = [CChar](repeating: 0, count: 4096)
    guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
    return String(cString: buffer)
}

/// Outermost `.app` bundle containing `path` (so Chrome helpers resolve to Google Chrome.app).
func outermostAppBundle(in path: String) -> String? {
    guard let range = path.range(of: ".app/") ?? (path.hasSuffix(".app") ? path.range(of: ".app", options: .backwards) : nil)
    else { return nil }
    return String(path[..<range.lowerBound]) + ".app"
}

/// Resolves an audio-producing pid to the user-facing app it belongs to.
/// XPC services (e.g. Safari's WebKit GPU process) are attributed via the responsible pid.
func owningAppBundle(of pid: pid_t) -> String? {
    if let fn = responsiblePID {
        let rpid = fn(pid)
        if rpid > 0, let path = executablePath(of: rpid), let bundle = outermostAppBundle(in: path) {
            return bundle
        }
    }
    return executablePath(of: pid).flatMap(outermostAppBundle(in:))
}

// MARK: - Output devices

struct OutputDevice: Identifiable, Equatable {
    let id: AudioObjectID
    let name: String
    let symbol: String
}

enum OutputDevices {
    /// Visible devices that can play audio, excluding Volumio's own private aggregate devices.
    static func all() -> [OutputDevice] {
        AudioObjectID.system.readObjectList(kAudioHardwarePropertyDevices).compactMap { id in
            guard hasOutputStreams(id),
                  ((try? id.read(kAudioDevicePropertyIsHidden, default: UInt32(0))) ?? 0) == 0,
                  let name = id.readString(kAudioObjectPropertyName),
                  !name.hasPrefix("Volumio")
            else { return nil }
            let transport = (try? id.read(kAudioDevicePropertyTransportType, default: UInt32(0))) ?? 0
            return OutputDevice(id: id, name: name, symbol: symbol(name: name, transport: transport))
        }
    }

    static func setDefault(_ id: AudioObjectID) {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var value = id
        AudioObjectSetPropertyData(.system, &addr, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &value)
    }

    private static func hasOutputStreams(_ id: AudioObjectID) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                              mScope: kAudioDevicePropertyScopeOutput,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr && size > 0
    }

    private static func symbol(name: String, transport: UInt32) -> String {
        let lower = name.lowercased()
        if lower.contains("airpods") { return "airpods" }
        if lower.contains("headphone") || lower.contains("tai nghe") { return "headphones" }
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return "laptopcomputer"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "headphones"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "display"
        case kAudioDeviceTransportTypeAirPlay: return "airplayaudio"
        case kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeThunderbolt: return "hifispeaker"
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate: return "waveform"
        default: return "speaker.wave.2"
        }
    }
}

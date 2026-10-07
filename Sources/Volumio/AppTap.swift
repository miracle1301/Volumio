import CoreAudio
import Foundation

/// Captures the audio of a group of processes with a Core Audio process tap (muting the
/// original stream) and plays it back to the output device with an adjustable gain.
final class AppTap {
    let processObjectIDs: [AudioObjectID]
    let outputUID: String

    var gain: Float {
        get { renderer.target.pointee }
        set { renderer.target.pointee = max(0, newValue) }
    }

    private let renderer: Renderer
    private var tapID = AudioObjectID.unknown
    private var aggregateID = AudioObjectID.unknown
    private var ioProcID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "Volumio.io", qos: .userInteractive)
    private var invalidated = false

    init(name: String, processObjectIDs: [AudioObjectID], outputUID: String, gain: Float) throws {
        self.processObjectIDs = processObjectIDs
        self.outputUID = outputUID
        self.renderer = Renderer(gain: gain)
        do {
            try start(name: name)
        } catch {
            invalidate()
            throw error
        }
    }

    deinit { invalidate() }

    private func start(name: String) throws {
        let description = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
        description.uuid = UUID()
        description.name = "Volumio – \(name)"
        description.muteBehavior = .mutedWhenTapped
        description.isPrivate = true

        try check(AudioHardwareCreateProcessTap(description, &tapID), "Tạo process tap")

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Volumio – \(name)",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID),
                  "Tạo aggregate device")

        let renderer = self.renderer
        try check(AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue) { _, input, _, output, _ in
            renderer.render(input: input, output: output)
        }, "Tạo IOProc")

        try check(AudioDeviceStart(aggregateID, ioProcID), "Khởi động thiết bị")
    }

    func invalidate() {
        guard !invalidated else { return }
        invalidated = true
        if aggregateID != .unknown {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != .unknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
    }
}

/// Real-time render state. Only `target` is written from the main thread.
private final class Renderer {
    let target: UnsafeMutablePointer<Float>
    private var current: Float

    init(gain: Float) {
        target = .allocate(capacity: 1)
        target.initialize(to: gain)
        current = gain
    }

    deinit { target.deallocate() }

    func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outList = UnsafeMutableAudioBufferListPointer(output)

        for buffer in outList {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }

        var inChannels = 0
        for buffer in inList { inChannels += Int(buffer.mNumberChannels) }
        guard inChannels > 0, inList[0].mNumberChannels > 0, inList[0].mData != nil else { return }
        let inFrames = Int(inList[0].mDataByteSize) / (MemoryLayout<Float>.size * Int(inList[0].mNumberChannels))

        var outChannels = 0
        for buffer in outList { outChannels += Int(buffer.mNumberChannels) }
        guard outChannels > 0 else { return }

        // Linear ramp from the previous gain to the new one avoids zipper noise.
        let start = current
        let end = target.pointee
        current = end

        @inline(__always) func sample(_ channel: Int, _ frame: Int) -> Float {
            var base = 0
            for buffer in inList {
                let n = Int(buffer.mNumberChannels)
                if channel < base + n {
                    guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { return 0 }
                    return data[frame * n + (channel - base)]
                }
                base += n
            }
            return 0
        }

        var channelBase = 0
        for buffer in outList {
            let n = Int(buffer.mNumberChannels)
            defer { channelBase += n }
            guard n > 0, let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let frames = min(Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * n), inFrames)
            guard frames > 0 else { continue }
            let step = (end - start) / Float(frames)

            for frame in 0..<frames {
                let g = start + step * Float(frame)
                for c in 0..<n {
                    let channel = channelBase + c
                    var s: Float
                    if outChannels == 1 {
                        // Mono device: downmix.
                        s = 0
                        for i in 0..<inChannels { s += sample(i, frame) }
                        s /= Float(inChannels)
                    } else if channel < inChannels {
                        s = sample(channel, frame)
                    } else {
                        continue
                    }
                    data[frame * n + c] = min(max(s * g, -1), 1)
                }
            }
        }
    }
}

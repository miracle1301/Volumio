import AppKit
import AudioToolbox
import CoreAudio
import Foundation

struct AudioApp: Identifiable, Equatable {
    let id: String          // bundle identifier (or bundle path as fallback)
    let name: String
    let bundlePath: String
    var processObjectIDs: [AudioObjectID]
    var isPlaying: Bool
    var isUsingMic: Bool
}

final class MixerModel: ObservableObject {
    static let maxVolume: Float = 1.5

    /// Apps shown in the UI: only those currently playing audio (with a short grace period).
    @Published private(set) var apps: [AudioApp] = []
    /// Every app with a Core Audio process; taps are kept for these so a custom volume
    /// is already in place the moment an app starts playing.
    private var allApps: [AudioApp] = []
    private var lastPlayed: [String: Date] = [:]
    private let playingGracePeriod: TimeInterval = 15
    @Published private(set) var outputName = "—"
    @Published private(set) var outputDevices: [OutputDevice] = []
    @Published private(set) var currentOutputID: AudioObjectID?
    @Published private(set) var systemVolume: Float?
    @Published private(set) var systemMuted: Bool?
    @Published private(set) var errorMessage: String?
    @Published private var volumes: [String: Float]
    @Published private var mutes: Set<String>

    // Auto-ducking: lower other apps while an editor plays or a call uses the microphone.
    static let duckLevel: Float = 0.2
    private static let duckHold: TimeInterval = 3          // wait before restoring, avoids pumping
    private static let duckFadeOut: TimeInterval = 0.4
    private static let duckFadeIn: TimeInterval = 1.2
    /// Video/audio editors whose playback triggers ducking.
    private static let editorBundlePrefixes = ["com.adobe.PremierePro", "com.adobe.AfterEffects", "com.adobe.Audition",
                                               "com.apple.FinalCut", "com.blackmagic-design.DaVinciResolve"]
    @Published var autoDuckEnabled: Bool {
        didSet { defaults.set(autoDuckEnabled, forKey: "autoDuck"); updateDucking() }
    }
    /// Names of the apps currently causing ducking (nil when not ducking).
    @Published private(set) var duckReason: String?
    @Published private(set) var duckedApps: Set<String> = []
    private var duckFactor: Float = 1
    private var duckTarget: Float = 1
    private var lastTriggerAt: Date = .distantPast
    private var fadeTimer: Timer?

    /// Row under the mouse in the popover ("system" or an app id); scroll-wheel target.
    var hoverTarget: String?
    /// Short text shown next to the menu bar icon after scrolling on it.
    @Published var menuBarFlash: String?
    var scrollMonitor: Any?
    var globalScrollMonitor: Any?
    var flashWorkItem: DispatchWorkItem?

    private var taps: [String: AppTap] = [:]
    private var failedSignatures: Set<String> = []
    private var outputDevice: AudioObjectID?
    private var outputUID: String?
    private var icons: [String: NSImage] = [:]
    private var timer: Timer?
    private let defaults = UserDefaults.standard
    private let ownBundlePath = Bundle.main.bundlePath

    init() {
        volumes = (defaults.dictionary(forKey: "volumes") as? [String: Double])?.mapValues(Float.init) ?? [:]
        mutes = Set(defaults.stringArray(forKey: "mutes") ?? [])
        autoDuckEnabled = defaults.object(forKey: "autoDuck") as? Bool ?? true

        updateOutputDevice()
        refresh()
        installListeners()
        installScrollMonitor()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.refresh() }

        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.taps.values.forEach { $0.invalidate() }
        }
    }

    // MARK: - Public API for the UI

    func volume(for app: AudioApp) -> Float { volumes[app.id] ?? 1 }
    func isMuted(_ app: AudioApp) -> Bool { mutes.contains(app.id) }

    func setVolume(_ value: Float, for app: AudioApp, snap: Bool = true) {
        let value = min(max(value, 0), Self.maxVolume)
        volumes[app.id] = abs(value - 1) < (snap ? 0.02 : 0.001) ? nil : value   // snap to 100%
        mutes.remove(app.id)   // moving the slider unmutes, like the macOS volume control
        persist()
        apply(app)
    }

    func toggleMute(_ app: AudioApp) {
        if mutes.contains(app.id) { mutes.remove(app.id) } else { mutes.insert(app.id) }
        persist()
        apply(app)
    }

    /// True when every app currently shown is muted.
    var allAppsMuted: Bool { !apps.isEmpty && apps.allSatisfy { mutes.contains($0.id) } }

    /// Mutes every app currently shown, or unmutes them all if they are already muted.
    func toggleMuteAll() {
        let mute = !allAppsMuted
        for app in apps {
            if mute { mutes.insert(app.id) } else { mutes.remove(app.id) }
            failedSignatures = failedSignatures.filter { !$0.hasPrefix(app.id + "|") }
        }
        persist()
        reconcile()
    }

    func toggleSystemMute() {
        guard let outputDevice, let muted = systemMuted else { return }
        SystemVolume.setMuted(outputDevice, !muted)
        systemMuted = SystemVolume.isMuted(outputDevice)
    }

    func resetAll() {
        volumes.removeAll()
        mutes.removeAll()
        persist()
        reconcile()
    }

    func setSystemVolume(_ value: Float) {
        guard let outputDevice else { return }
        let value = min(max(value, 0), 1)
        SystemVolume.set(outputDevice, value)
        systemVolume = value
        if systemMuted == true {
            SystemVolume.setMuted(outputDevice, false)
            systemMuted = false
        }
    }

    func selectOutput(_ device: OutputDevice) {
        guard device.id != currentOutputID else { return }
        OutputDevices.setDefault(device.id)   // the default-device listener rebuilds taps
    }

    func icon(for app: AudioApp) -> NSImage {
        if let cached = icons[app.bundlePath] { return cached }
        let image = NSWorkspace.shared.icon(forFile: app.bundlePath)
        icons[app.bundlePath] = image
        return image
    }

    // MARK: - Discovery

    private func installListeners() {
        var processes = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                   mScope: kAudioObjectPropertyScopeGlobal,
                                                   mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(.system, &processes, .main) { [weak self] _, _ in self?.refresh() }

        var devices = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(.system, &devices, .main) { [weak self] _, _ in self?.refreshOutputDevices() }

        var output = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                mScope: kAudioObjectPropertyScopeGlobal,
                                                mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(.system, &output, .main) { [weak self] _, _ in
            self?.updateOutputDevice()
            self?.failedSignatures.removeAll()
            self?.reconcile()
        }
    }

    private func updateOutputDevice() {
        stopObservingSystemVolume()
        outputDevice = AudioObjectID.defaultOutputDevice()
        outputUID = outputDevice?.readString(kAudioDevicePropertyDeviceUID)
        outputName = outputDevice?.readString(kAudioObjectPropertyName) ?? "—"
        currentOutputID = outputDevice
        refreshOutputDevices()
        startObservingSystemVolume()
        syncSystemVolume()
    }

    // Volume keys / Control Center change the device volume; listen for it instead of
    // waiting for the 1 s poll so the slider follows instantly.
    private static let systemVolumeSelectors = [kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                                kAudioDevicePropertyMute]
    private var systemVolumeListener: AudioObjectPropertyListenerBlock?

    private func startObservingSystemVolume() {
        guard let outputDevice else { return }
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.syncSystemVolume() }
        for selector in Self.systemVolumeSelectors {
            var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput,
                                                  mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(outputDevice, &addr, .main, listener)
        }
        systemVolumeListener = listener
    }

    private func refreshOutputDevices() {
        let devices = OutputDevices.all()
        if devices != outputDevices { outputDevices = devices }
    }

    private func stopObservingSystemVolume() {
        guard let outputDevice, let listener = systemVolumeListener else { return }
        for selector in Self.systemVolumeSelectors {
            var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput,
                                                  mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(outputDevice, &addr, .main, listener)
        }
        systemVolumeListener = nil
    }

    private func syncSystemVolume() {
        guard let outputDevice else { return }
        let v = SystemVolume.get(outputDevice)
        if v != systemVolume { systemVolume = v }
        let m = SystemVolume.isMuted(outputDevice)
        if m != systemMuted { systemMuted = m }
    }

    private func refresh() {
        var grouped: [String: AudioApp] = [:]
        // Only show regular (Dock) apps; hides system agents like loginwindow or ControlCenter.
        let regularApps = Set(NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { $0.bundleURL?.path })

        for object in AudioObjectID.system.readObjectList(kAudioHardwarePropertyProcessObjectList) {
            guard let pid = try? object.read(kAudioProcessPropertyPID, default: pid_t(0)), pid > 0,
                  let bundlePath = owningAppBundle(of: pid), bundlePath != ownBundlePath,
                  regularApps.contains(bundlePath)
            else { continue }
            let playing = ((try? object.read(kAudioProcessPropertyIsRunningOutput, default: UInt32(0))) ?? 0) != 0
            let usingMic = ((try? object.read(kAudioProcessPropertyIsRunningInput, default: UInt32(0))) ?? 0) != 0

            let bundle = Bundle(path: bundlePath)
            let key = bundle?.bundleIdentifier ?? bundlePath
            if grouped[key] == nil {
                let name = NSRunningApplication(processIdentifier: pid)?.localizedName.flatMap { n in
                    // Helper processes report their own name; prefer the parent app's.
                    n.localizedCaseInsensitiveContains("helper") ? nil : n
                } ?? FileManager.default.displayName(atPath: bundlePath).replacingOccurrences(of: ".app", with: "")
                grouped[key] = AudioApp(id: key, name: name, bundlePath: bundlePath, processObjectIDs: [], isPlaying: false, isUsingMic: false)
            }
            grouped[key]!.processObjectIDs.append(object)
            grouped[key]!.isPlaying = grouped[key]!.isPlaying || playing
            grouped[key]!.isUsingMic = grouped[key]!.isUsingMic || usingMic
        }

        let now = Date()
        allApps = grouped.values
            .map { var a = $0; a.processObjectIDs.sort(); return a }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
        for app in allApps where app.isPlaying { lastPlayed[app.id] = now }

        // Keep an app visible briefly after it stops (pause between tracks, buffering...).
        let visible = allApps.filter { now.timeIntervalSince(lastPlayed[$0.id] ?? .distantPast) < playingGracePeriod }
        if visible != apps { apps = visible }

        syncSystemVolume()   // fallback for devices that don't send change notifications
        updateDucking()
        reconcile()
    }

    // MARK: - Taps

    private func effectiveGain(_ id: String) -> Float {
        if mutes.contains(id) { return 0 }
        return (volumes[id] ?? 1) * (duckedApps.contains(id) ? duckFactor : 1)
    }

    // MARK: - Auto-ducking

    private func isDuckTrigger(_ app: AudioApp) -> Bool {
        app.isUsingMic || (app.isPlaying && Self.editorBundlePrefixes.contains { app.id.hasPrefix($0) })
    }

    private func updateDucking() {
        let triggers = autoDuckEnabled ? allApps.filter(isDuckTrigger) : []
        let now = Date()

        if !triggers.isEmpty {
            lastTriggerAt = now
            let triggerIDs = Set(triggers.map(\.id))
            let reason = triggers.map(\.name).joined(separator: ", ")
            if reason != duckReason { duckReason = reason }
            // Duck every other app that is playing; never the app that triggered it (e.g. Meet in Chrome).
            var ducked = duckedApps.subtracting(triggerIDs)
            for app in allApps where app.isPlaying && !triggerIDs.contains(app.id) { ducked.insert(app.id) }
            if ducked != duckedApps { duckedApps = ducked }
            setDuckTarget(Self.duckLevel)
        } else if autoDuckEnabled, now.timeIntervalSince(lastTriggerAt) < Self.duckHold {
            return
        } else {
            if duckReason != nil { duckReason = nil }
            setDuckTarget(1)
        }
    }

    private func setDuckTarget(_ target: Float) {
        guard target != duckTarget || (fadeTimer == nil && duckFactor != target) else { return }
        duckTarget = target
        reconcile()   // make sure ducked apps are tapped before fading
        fadeTimer?.invalidate()
        let interval: TimeInterval = 1.0 / 30
        let duration = target < duckFactor ? Self.duckFadeOut : Self.duckFadeIn
        let step = Float((1 - Self.duckLevel) * Float(interval / duration))
        fadeTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            if abs(self.duckTarget - self.duckFactor) <= step {
                self.duckFactor = self.duckTarget
                timer.invalidate()
                self.fadeTimer = nil
                if self.duckTarget == 1 {
                    self.duckedApps.removeAll()
                    self.reconcile()   // drop taps that were only needed for ducking
                }
            } else {
                self.duckFactor += self.duckTarget > self.duckFactor ? step : -step
            }
            for (id, tap) in self.taps { tap.gain = self.effectiveGain(id) }
        }
    }

    private func apply(_ app: AudioApp) {
        failedSignatures = failedSignatures.filter { !$0.hasPrefix(app.id + "|") }
        if let tap = taps[app.id], abs(effectiveGain(app.id) - 1) > 0.001 {
            tap.gain = effectiveGain(app.id)
        } else {
            reconcile()
        }
    }

    /// Creates, updates or tears down taps so that only apps with a non-100% volume are tapped.
    private func reconcile() {
        let present = Set(allApps.map(\.id))
        for (id, tap) in taps where !present.contains(id) {
            tap.invalidate()
            taps[id] = nil
        }
        guard let outputUID else { return }

        for app in allApps {
            let gain = effectiveGain(app.id)
            guard abs(gain - 1) > 0.001 || duckedApps.contains(app.id) else {
                taps.removeValue(forKey: app.id)?.invalidate()
                continue
            }
            if let tap = taps[app.id], tap.processObjectIDs == app.processObjectIDs, tap.outputUID == outputUID {
                tap.gain = gain
                continue
            }
            let signature = "\(app.id)|\(app.processObjectIDs)|\(outputUID)"
            guard !failedSignatures.contains(signature) else { continue }

            taps.removeValue(forKey: app.id)?.invalidate()
            do {
                taps[app.id] = try AppTap(name: app.name, processObjectIDs: app.processObjectIDs,
                                          outputUID: outputUID, gain: gain)
                errorMessage = nil
            } catch {
                failedSignatures.insert(signature)
                errorMessage = "\(app.name): \(error.localizedDescription)"
            }
        }
    }

    private func persist() {
        defaults.set(volumes.mapValues(Double.init), forKey: "volumes")
        defaults.set(Array(mutes), forKey: "mutes")
    }
}

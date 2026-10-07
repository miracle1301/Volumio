import AppKit

/// Scroll wheel / trackpad volume control: over the menu bar icon it changes the system volume,
/// inside the popover it changes whichever row (system or app) is under the pointer.
extension MixerModel {
    func installScrollMonitor() {
        // Events delivered to Volumio's own windows (the popover, and the status item on older macOS).
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            return handleScroll(event, overStatusItem: Self.isStatusItemWindow(event.window)) ? nil : event
        }
        // On macOS 26 the status item is rendered by Control Center, so scrolls over the icon go to
        // another process; a global monitor still sees them and we match on the pointer position.
        globalScrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, Self.statusItemFrames().contains(where: { $0.contains(NSEvent.mouseLocation) }) else { return }
            _ = handleScroll(event, overStatusItem: true)
        }
    }

    func setHover(_ target: String, _ hovering: Bool) {
        if hovering { hoverTarget = target } else if hoverTarget == target { hoverTarget = nil }
    }

    /// Returns true when the event was used to change a volume.
    private func handleScroll(_ event: NSEvent, overStatusItem: Bool) -> Bool {
        guard abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) else { return false }
        let delta = Self.volumeDelta(for: event)

        if overStatusItem {
            guard let current = systemVolume else { return false }
            setSystemVolume(current + delta)
            flashMenuBar("\(Int(((systemVolume ?? 0) * 100).rounded()))%")
            return true
        }
        switch hoverTarget {
        case "system"?:
            guard let current = systemVolume else { return false }
            setSystemVolume(current + delta)
            return true
        case let id?:
            guard let app = apps.first(where: { $0.id == id }) else { return false }
            setVolume(volume(for: app) + delta, for: app, snap: false)
            return true
        case nil:
            return false
        }
    }

    private static func isStatusItemWindow(_ window: NSWindow?) -> Bool {
        window.map { String(describing: type(of: $0)).contains("StatusBarWindow") } ?? false
    }

    private static func statusItemFrames() -> [NSRect] {
        NSApp.windows.filter { isStatusItemWindow($0) }.map(\.frame)
    }

    /// Up = louder regardless of the "natural scrolling" setting. One mouse-wheel notch ≈ 3%.
    private static func volumeDelta(for event: NSEvent) -> Float {
        var dy = Float(event.scrollingDeltaY)
        if event.isDirectionInvertedFromDevice { dy = -dy }
        return event.hasPreciseScrollingDeltas ? dy * 0.004 : dy * 0.03
    }

    private func flashMenuBar(_ text: String) {
        menuBarFlash = text
        flashWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.menuBarFlash = nil }
        flashWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }
}

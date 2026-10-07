import AVKit
import SwiftUI

@main
struct VolumioApp: App {
    @StateObject private var model = MixerModel()
    @StateObject private var updater = Updater()
    @StateObject private var launchAtLogin = LaunchAtLogin()

    var body: some Scene {
        MenuBarExtra {
            MixerView()
                .environmentObject(model)
                .environmentObject(updater)
                .environmentObject(launchAtLogin)
        } label: {
            // Briefly shows the new level after scrolling on the icon.
            if let flash = model.menuBarFlash {
                Text("\(Image(systemName: "speaker.wave.2.fill")) \(flash)").monospacedDigit()
            } else {
                Image(systemName: "slider.vertical.3")
            }
        }
        .menuBarExtraStyle(.window)
    }
}

struct MixerView: View {
    @EnvironmentObject private var model: MixerModel
    @EnvironmentObject private var updater: Updater
    @EnvironmentObject private var launchAtLogin: LaunchAtLogin
    @AppStorage("showOutputDevices") private var showOutputDevices = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if let volume = model.systemVolume {
                HStack(spacing: 10) {
                    Image(systemName: "speaker.wave.2.fill")
                        .frame(width: 24)
                        .foregroundStyle(.secondary)
                    Text("Hệ thống").frame(width: 90, alignment: .leading)
                    Slider(value: Binding(get: { volume }, set: { model.setSystemVolume($0) }), in: 0...1)
                        .tint(model.systemMuted == true ? Color.mutedTint : .accentColor)
                    Text("\(Int((volume * 100).rounded()))%")
                        .monospacedDigit()
                        .foregroundStyle(model.systemMuted == true ? .secondary : .primary)
                        .frame(width: 40, alignment: .trailing)
                    if let muted = model.systemMuted {
                        MuteButton(muted: muted) { model.toggleSystemMute() }
                    }
                }
                .hoverTarget("system")
            }

            Divider()

            HStack {
                Text("Ứng dụng").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Button {
                    model.toggleMuteAll()
                } label: {
                    Label(model.allAppsMuted ? "Bật tiếng tất cả" : "Tắt tiếng tất cả",
                          systemImage: model.allAppsMuted ? "speaker.wave.2.fill" : "speaker.slash.fill")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .disabled(model.apps.isEmpty)
            }

            if model.apps.isEmpty {
                Text("Không có ứng dụng nào đang phát âm thanh.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 16)
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(model.apps) { AppRow(app: $0) }
                    }
                }
                .frame(height: min(CGFloat(model.apps.count) * 38, 420))
            }

            autoDuckRow

            if let error = model.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !model.outputDevices.isEmpty {
                Divider()
                outputSection
            }

            Divider()

            HStack {
                Button("Đặt lại tất cả") { model.resetAll() }
                Spacer()
                Menu {
                    Toggle("Khởi động cùng máy", isOn: Binding(get: { launchAtLogin.isEnabled },
                                                               set: { launchAtLogin.set($0) }))
                    Button("Kiểm tra cập nhật…") { updater.checkForUpdates() }
                        .disabled(!updater.canCheckForUpdates)
                    Divider()
                    Text("Volumio \(updater.version)")
                } label: {
                    Image(systemName: "gearshape")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .onAppear { launchAtLogin.refresh() }
                Button("Thoát") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .frame(width: 380)
    }

    private var autoDuckRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.right.circle")
                .foregroundStyle(model.duckReason != nil ? Color.accentColor : .secondary)
                .frame(width: 24)
            Text("Tự giảm nhạc")
            if let reason = model.duckReason {
                Text("↓ \(reason)")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(1)
            }
            Spacer()
            Toggle("", isOn: $model.autoDuckEnabled)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
        .help("Khi dựng phim hoặc gọi điện, các app khác tự giảm còn \(Int(MixerModel.duckLevel * 100))%")
    }

    /// Collapsed by default: shows the current device; expands to the full device list.
    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { showOutputDevices.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .rotationEffect(.degrees(showOutputDevices ? 90 : 0))
                            .frame(width: 12)
                        Text("Thiết bị phát")
                        Spacer()
                        if !showOutputDevices, let current = model.outputDevices.first(where: { $0.id == model.currentOutputID }) {
                            Label(current.name, systemImage: current.symbol)
                                .font(.caption)
                                .lineLimit(1)
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if showOutputDevices {
                    AirPlayButton()
                        .frame(width: 22, height: 22)
                        .help("AirPlay")
                }
            }

            if showOutputDevices {
                VStack(spacing: 2) {
                    ForEach(model.outputDevices) { device in
                        OutputDeviceRow(device: device, selected: device.id == model.currentOutputID) {
                            model.selectOutput(device)
                        }
                    }
                }
            }
        }
    }

    private var header: some View {
        Text("Volumio").font(.headline)
    }
}

struct AppRow: View {
    @EnvironmentObject private var model: MixerModel
    let app: AudioApp

    var body: some View {
        let muted = model.isMuted(app)
        let volume = model.volume(for: app)

        HStack(spacing: 10) {
            Image(nsImage: model.icon(for: app))
                .resizable()
                .frame(width: 24, height: 24)
                .overlay(alignment: .bottomTrailing) {
                    if app.isPlaying {
                        Circle().fill(.green).frame(width: 7, height: 7)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if model.duckedApps.contains(app.id) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.white, Color.accentColor)
                            .offset(x: -3, y: -3)
                            .help("Đang tự giảm âm lượng")
                    }
                }

            Text(app.name)
                .lineLimit(1)
                .frame(width: 90, alignment: .leading)
                .help(app.name)

            Slider(value: Binding(get: { volume }, set: { model.setVolume($0, for: app) }),
                   in: 0...MixerModel.maxVolume)
                .tint(muted ? Color.mutedTint : volume > 1 ? .orange : .accentColor)

            Text("\(Int((volume * 100).rounded()))%")
                .monospacedDigit()
                .foregroundStyle(muted ? .secondary : .primary)
                .frame(width: 40, alignment: .trailing)

            MuteButton(muted: muted) { model.toggleMute(app) }
        }
        .hoverTarget(app.id)
    }
}

/// Highlights a row under the pointer and makes it the scroll-wheel volume target.
private struct HoverTarget: ViewModifier {
    @EnvironmentObject private var model: MixerModel
    let id: String
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.primary.opacity(0.06) : .clear))
            .onHover { hovering = $0; model.setHover(id, $0) }
    }
}

extension View {
    func hoverTarget(_ id: String) -> some View { modifier(HoverTarget(id: id)) }
}

/// System AirPlay route picker: AirPlay targets only become Core Audio devices once connected.
struct AirPlayButton: NSViewRepresentable {
    func makeNSView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.isRoutePickerButtonBordered = false
        return picker
    }

    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {}
}

struct OutputDeviceRow: View {
    let device: OutputDevice
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: device.symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(selected ? Color.white : Color.primary)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(selected ? Color.accentColor : Color.primary.opacity(0.1)))
                Text(device.name).lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.primary.opacity(0.08) : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

extension Color {
    /// Red-orange used for sliders of muted sources.
    static let mutedTint = Color(red: 1.0, green: 0.27, blue: 0.13)
}

struct MuteButton: View {
    let muted: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .foregroundStyle(muted ? Color.mutedTint : .secondary)
                .frame(width: 18)
        }
        .buttonStyle(.borderless)
        .help(muted ? "Bật tiếng" : "Tắt tiếng")
    }
}

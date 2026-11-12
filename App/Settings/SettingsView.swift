import SwiftUI

/// Settings. Everything here is a view onto the files in the mpv config directory: the
/// options read and write single lines of `mpv.conf` and `script-opts/yoru.conf`, and the
/// same files can also be edited as text.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var player = PlayerOptions.load()
    @State private var interface = YoruOptions.load()

    var body: some View {
        NavigationStack {
            SettingsForm(title: "Settings") {
                Section {
                    ForEach(SettingsCategory.allCases) { category in
                        NavigationLink {
                            page(for: category)
                        } label: {
                            SettingLabel(category.title, detail: category.summary, symbol: category.symbol)
                        }
                    }
                } footer: {
                    Text("Options are saved to the configuration files below and apply to the next video you open.")
                }
                configurationSection
                aboutSection
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onChange(of: player) { previous, current in current.save(changedFrom: previous) }
            .onChange(of: interface) { _, current in
                current.save()
                MediaPreviewStore.shared.rendersRemoteFiles = current.remoteThumbnails
            }
            // The files may have been edited as text in the meantime.
            .onAppear(perform: reload)
        }
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
    }

    private func reload() {
        // Compare first: assigning an equal value must not trigger a save.
        let loadedPlayer = PlayerOptions.load()
        if loadedPlayer != player { player = loadedPlayer }
        let loadedInterface = YoruOptions.load()
        if loadedInterface != interface { interface = loadedInterface }
    }

    @ViewBuilder
    private func page(for category: SettingsCategory) -> some View {
        switch category {
        case .playback: PlaybackSettings(player: $player, interface: $interface)
        case .video: VideoSettings(player: $player)
        case .audio: AudioSettings(player: $player)
        case .subtitles: SubtitleSettings(player: $player)
        case .gestures: GestureSettings(interface: $interface)
        case .storage: StorageSettings(player: $player, interface: $interface)
        }
    }

    private var configurationSection: some View {
        Section {
            ForEach(ConfigFile.allCases) { file in
                NavigationLink {
                    ConfigFileEditor(file: file)
                } label: {
                    SettingLabel(LocalizedStringKey(file.title), detail: file.summary, symbol: file.symbol)
                }
            }
        } header: {
            Text("Configuration Files")
        } footer: {
            Text("Edit the files directly for anything not listed above. They are the same files mpv uses on a desktop, and live in the mpv folder inside YORU in the Files app, next to fonts and scripts.")
        }
    }

    private var aboutSection: some View {
        Section {
            LabeledContent("Version", value: Self.version)
            LabeledContent("Player Core", value: "mpv")
        } header: {
            Text("About")
        }
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "-"
        let build = info?["CFBundleVersion"] as? String ?? "-"
        return "\(version) (\(build))"
    }
}

/// The pages Settings is divided into.
private enum SettingsCategory: CaseIterable, Identifiable {
    case playback
    case video
    case audio
    case subtitles
    case gestures
    case storage

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .playback: "Playback"
        case .video: "Video"
        case .audio: "Audio"
        case .subtitles: "Subtitles"
        case .gestures: "Gestures"
        case .storage: "Cache & Storage"
        }
    }

    var summary: LocalizedStringKey {
        switch self {
        case .playback: "Resuming, and what happens when a video ends."
        case .video: "Decoding, scaling and HDR."
        case .audio: "Preferred audio language."
        case .subtitles: "Language, size, position and font."
        case .gestures: "Double tap, brightness, volume and seeking."
        case .storage: "Read-ahead buffer and thumbnails."
        }
    }

    var symbol: String {
        switch self {
        case .playback: "play.circle"
        case .video: "tv"
        case .audio: "waveform"
        case .subtitles: "captions.bubble"
        case .gestures: "hand.tap"
        case .storage: "internaldrive"
        }
    }
}

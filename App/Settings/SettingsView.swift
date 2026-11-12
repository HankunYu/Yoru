import SwiftUI

/// Settings. Everything here is a view onto the files in the mpv config directory: the
/// options read and write single lines of `mpv.conf` and `script-opts/yoru.conf`, and the
/// same files can also be edited as text.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var player = PlayerOptions.load()
    @State private var interface = YoruOptions.load()
    @State private var resumePositionCount = ConfigDirectory.resumePositionCount
    @State private var isConfirmingClear = false

    var body: some View {
        NavigationStack {
            Form {
                languageSection
                subtitleSection
                videoSection
                playbackSection
                seekingSection
                configurationSection
                aboutSection
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onChange(of: player) { previous, current in current.save(changedFrom: previous) }
            .onChange(of: interface) { _, current in current.save() }
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
        resumePositionCount = ConfigDirectory.resumePositionCount
    }

    // MARK: - Sections

    private var languageSection: some View {
        Section {
            LanguagePicker("Subtitle Language", symbol: "captions.bubble", selection: $player.subtitleLanguage)
            LanguagePicker("Audio Language", symbol: "waveform", selection: $player.audioLanguage)
        } header: {
            Text("Languages")
        } footer: {
            Text("Which track to pick when a video has several.")
        }
        .listRowBackground(Theme.card)
    }

    private var subtitleSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SettingLabel("Subtitle Size", detail: nil, symbol: "textformat.size")
                    Spacer()
                    Text(player.subtitleScale, format: .percent.precision(.fractionLength(0)))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: $player.subtitleScale, in: 0.5...2, step: 0.05)
            }
            .padding(.vertical, 4)
            Toggle(isOn: $player.loadsExternalSubtitles) {
                SettingLabel(
                    "Load External Subtitles",
                    detail: "Use subtitle files next to the video with a matching name.",
                    symbol: "doc.badge.plus"
                )
            }
        } header: {
            Text("Subtitles")
        }
        .listRowBackground(Theme.card)
    }

    private var videoSection: some View {
        Section {
            Toggle(isOn: $player.usesHardwareDecoding) {
                SettingLabel(
                    "Hardware Decoding",
                    detail: "Decode with the device's video hardware. Turn off only to troubleshoot.",
                    symbol: "cpu"
                )
            }
            Toggle(isOn: $player.usesHighQualityScaling) {
                SettingLabel(
                    "High Quality Scaling",
                    detail: "Sharper scaling filters. Uses more power.",
                    symbol: "sparkles"
                )
            }
        } header: {
            Text("Video")
        }
        .listRowBackground(Theme.card)
    }

    private var playbackSection: some View {
        Section {
            Toggle(isOn: $player.resumesPlayback) {
                SettingLabel(
                    "Resume Playback",
                    detail: "Continue each video where you left off.",
                    symbol: "arrow.clockwise"
                )
            }
            Button(role: .destructive) {
                isConfirmingClear = true
            } label: {
                HStack {
                    SettingLabel("Clear Resume Positions", detail: nil, symbol: "clock.arrow.circlepath")
                    Spacer()
                    Text("\(resumePositionCount)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .disabled(resumePositionCount == 0)
            .confirmationDialog(
                "Forget where every video was left off?",
                isPresented: $isConfirmingClear,
                titleVisibility: .visible
            ) {
                Button("Clear Resume Positions", role: .destructive) {
                    ConfigDirectory.clearResumePositions()
                    resumePositionCount = ConfigDirectory.resumePositionCount
                }
            }
        } header: {
            Text("Playback")
        }
        .listRowBackground(Theme.card)
    }

    private var seekingSection: some View {
        Section {
            Toggle(isOn: $interface.seekbarKeyframes) {
                SettingLabel(
                    "Fast Seek Bar",
                    detail: "Jump between keyframes while dragging; land exactly on release.",
                    symbol: "forward.frame"
                )
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SettingLabel("Swipe Sensitivity", detail: nil, symbol: "hand.draw")
                    Spacer()
                    Text(String(format: "%.2f s / pt", interface.swipeSeekRate))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: $interface.swipeSeekRate, in: 0.03...0.4, step: 0.01)
            }
            .padding(.vertical, 4)
        } header: {
            Text("Seeking")
        } footer: {
            Text("Options above are saved to the configuration files below and apply to the next video you open.")
        }
        .listRowBackground(Theme.card)
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
        .listRowBackground(Theme.card)
    }

    private var aboutSection: some View {
        Section {
            LabeledContent("Version", value: Self.version)
            LabeledContent("Player Core", value: "mpv")
        } header: {
            Text("About")
        }
        .listRowBackground(Theme.card)
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "-"
        let build = info?["CFBundleVersion"] as? String ?? "-"
        return "\(version) (\(build))"
    }
}

/// Picks a track language; a hand-written list in the file shows up as an extra entry.
private struct LanguagePicker: View {
    let title: LocalizedStringKey
    let symbol: String
    @Binding var selection: LanguagePreference

    init(_ title: LocalizedStringKey, symbol: String, selection: Binding<LanguagePreference>) {
        self.title = title
        self.symbol = symbol
        _selection = selection
    }

    var body: some View {
        Picker(selection: $selection) {
            ForEach(options) { option in
                Text(name(of: option)).tag(option)
            }
        } label: {
            SettingLabel(title, detail: nil, symbol: symbol)
        }
    }

    private var options: [LanguagePreference] {
        if case .custom = selection {
            return LanguagePreference.presets + [selection]
        }
        return LanguagePreference.presets
    }

    private func name(of option: LanguagePreference) -> String {
        switch option {
        case .automatic: String(localized: "Automatic")
        case .chinese: String(localized: "Chinese")
        case .english: String(localized: "English")
        case .japanese: String(localized: "Japanese")
        case .korean: String(localized: "Korean")
        case .custom(let codes): codes
        }
    }
}

/// A settings row label: icon, title and an optional one-line explanation.
private struct SettingLabel: View {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey?
    let symbol: String

    init(_ title: LocalizedStringKey, detail: LocalizedStringKey?, symbol: String) {
        self.title = title
        self.detail = detail
        self.symbol = symbol
    }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .foregroundStyle(.primary)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

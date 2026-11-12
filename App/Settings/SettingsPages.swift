import SwiftUI

// One page per settings category. Each edits a binding owned by `SettingsView`, which
// saves on change.

struct PlaybackSettings: View {
    @Binding var player: PlayerOptions
    @Binding var interface: YoruOptions
    @State private var resumePositionCount = ConfigDirectory.resumePositionCount
    @State private var isConfirmingClear = false

    var body: some View {
        SettingsForm(title: "Playback") {
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
            }
            Section {
                Picker(selection: $interface.endAction) {
                    Text("Play Next").tag(EndAction.next)
                    Text("Stay on Last Frame").tag(EndAction.stay)
                    Text("Close Player").tag(EndAction.close)
                } label: {
                    SettingLabel("When a Video Ends", detail: nil, symbol: "stop.circle")
                }
            }
        }
    }
}

struct VideoSettings: View {
    @Binding var player: PlayerOptions

    var body: some View {
        SettingsForm(title: "Video") {
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
                Toggle(isOn: $player.debands) {
                    SettingLabel(
                        "Debanding",
                        detail: "Smooth out color bands in gradients and dark scenes. Uses more power.",
                        symbol: "circle.lefthalf.filled"
                    )
                }
            }
            Section {
                Toggle(isOn: $player.outputsHDR) {
                    SettingLabel(
                        "HDR Output",
                        detail: "Show HDR video as HDR. Turn off to convert it to standard range.",
                        symbol: "sun.max"
                    )
                }
            }
        }
    }
}

struct AudioSettings: View {
    @Binding var player: PlayerOptions

    var body: some View {
        SettingsForm(title: "Audio") {
            Section {
                LanguagePicker("Audio Language", symbol: "waveform", selection: $player.audioLanguage)
            } footer: {
                Text("Which track to pick when a video has several.")
            }
        }
    }
}

struct SubtitleSettings: View {
    @Binding var player: PlayerOptions
    @State private var fontFamilies = FontLibrary.families()

    var body: some View {
        SettingsForm(title: "Subtitles") {
            Section {
                LanguagePicker("Subtitle Language", symbol: "captions.bubble", selection: $player.subtitleLanguage)
                Toggle(isOn: $player.loadsExternalSubtitles) {
                    SettingLabel(
                        "Load External Subtitles",
                        detail: "Use subtitle files next to the video with a matching name.",
                        symbol: "doc.badge.plus"
                    )
                }
            }
            Section {
                SettingSlider(
                    title: "Subtitle Size",
                    symbol: "textformat.size",
                    valueText: player.subtitleScale.formatted(.percent.precision(.fractionLength(0))),
                    value: $player.subtitleScale,
                    range: 0.5...2,
                    step: 0.05
                )
                SettingSlider(
                    title: "Vertical Position",
                    symbol: "arrow.up.and.down",
                    valueText: "\(player.subtitlePosition)",
                    value: Binding(
                        get: { Double(player.subtitlePosition) },
                        set: { player.subtitlePosition = Int($0.rounded()) }
                    ),
                    range: 60...100,
                    step: 1
                )
                Picker(selection: $player.subtitleFont) {
                    Text("Default").tag(String?.none)
                    ForEach(fontOptions, id: \.self) { family in
                        Text(family).tag(String?.some(family))
                    }
                } label: {
                    SettingLabel("Font", detail: nil, symbol: "textformat")
                }
            } footer: {
                Text("100 puts subtitles at the bottom; lower values move them up. Fonts come from the fonts folder inside the mpv folder. Subtitles with their own styling may ignore the font and position.")
            }
        }
    }

    /// The installed families other than the default, plus the current value if its font
    /// file is gone, so the picker can still show it.
    private var fontOptions: [String] {
        var families = fontFamilies.filter { $0 != FontLibrary.defaultFamily }
        if let current = player.subtitleFont, !families.contains(current) {
            families.append(current)
        }
        return families
    }
}

struct GestureSettings: View {
    @Binding var interface: YoruOptions

    private static let seekSteps = [5, 10, 15, 30]
    private static let holdSpeeds = [1.5, 2, 2.5, 3, 4]

    var body: some View {
        SettingsForm(title: "Gestures") {
            Section {
                Picker(selection: $interface.doubleTapSeek) {
                    Text("Play / Pause").tag(0)
                    ForEach(doubleTapOptions, id: \.self) { seconds in
                        Text("Seek \(seconds) s").tag(seconds)
                    }
                } label: {
                    SettingLabel("Double Tap Sides", detail: nil, symbol: "hand.tap")
                }
                Picker(selection: $interface.holdSpeed) {
                    ForEach(holdSpeedOptions, id: \.self) { speed in
                        Text(verbatim: String(format: "%g×", speed)).tag(speed)
                    }
                } label: {
                    SettingLabel("Hold to Speed Up", detail: nil, symbol: "forward")
                }
            } footer: {
                Text("A double tap in the middle always plays or pauses.")
            }
            Section {
                Toggle(isOn: $interface.brightnessGesture) {
                    SettingLabel(
                        "Brightness",
                        detail: "Drag up or down on one half of the video.",
                        symbol: "sun.max"
                    )
                }
                Toggle(isOn: $interface.volumeGesture) {
                    SettingLabel(
                        "Volume",
                        detail: "Drag up or down on the other half.",
                        symbol: "speaker.wave.2"
                    )
                }
                Picker(selection: $interface.swapsGestureSides) {
                    Text("Brightness Left, Volume Right").tag(false)
                    Text("Volume Left, Brightness Right").tag(true)
                } label: {
                    SettingLabel("Sides", detail: nil, symbol: "rectangle.split.2x1")
                }
            }
            Section {
                Toggle(isOn: $interface.seekbarKeyframes) {
                    SettingLabel(
                        "Fast Seek Bar",
                        detail: "Jump between keyframes while dragging; land exactly on release.",
                        symbol: "forward.frame"
                    )
                }
                SettingSlider(
                    title: "Swipe Sensitivity",
                    symbol: "hand.draw",
                    valueText: String(format: "%.2f s / pt", interface.swipeSeekRate),
                    value: $interface.swipeSeekRate,
                    range: 0.03...0.4,
                    step: 0.01
                )
            } footer: {
                Text("Bindings written in input.conf take precedence over the gestures on this page.")
            }
        }
    }

    // A value written by hand in the file is offered too, so the picker can show it.
    private var doubleTapOptions: [Int] {
        (Self.seekSteps + [interface.doubleTapSeek]).filter { $0 > 0 }.uniqueSorted()
    }

    private var holdSpeedOptions: [Double] {
        (Self.holdSpeeds + [interface.holdSpeed]).uniqueSorted()
    }
}

struct StorageSettings: View {
    @Binding var player: PlayerOptions
    @Binding var interface: YoruOptions
    @State private var thumbnailBytes = MediaPreviewStore.shared.diskUsage()

    private static let bufferSizes = [64, 300, 500]

    var body: some View {
        SettingsForm(title: "Cache & Storage") {
            Section {
                Picker(selection: $player.readAheadMegabytes) {
                    Text("Default").tag(Int?.none)
                    ForEach(bufferOptions, id: \.self) { megabytes in
                        Text(verbatim: "\(megabytes) MB").tag(Int?.some(megabytes))
                    }
                } label: {
                    SettingLabel("Read-Ahead Buffer", detail: nil, symbol: "arrow.down.to.line")
                }
            } footer: {
                Text("How much of a video is loaded ahead of playback. A larger buffer rides out slow moments on network files and uses more memory.")
            }
            Section {
                Toggle(isOn: $interface.remoteThumbnails) {
                    SettingLabel(
                        "Thumbnails for Server Files",
                        detail: "Reads a few megabytes of each video once to make its thumbnail.",
                        symbol: "photo.badge.arrow.down"
                    )
                }
                Button(role: .destructive) {
                    MediaPreviewStore.shared.clear()
                    thumbnailBytes = MediaPreviewStore.shared.diskUsage()
                } label: {
                    HStack {
                        SettingLabel("Clear Thumbnails", detail: nil, symbol: "photo.on.rectangle")
                        Spacer()
                        Text(thumbnailBytes, format: .byteCount(style: .file))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .disabled(thumbnailBytes == 0)
            } footer: {
                Text("Thumbnails are made again the next time a video is shown.")
            }
        }
    }

    private var bufferOptions: [Int] {
        (Self.bufferSizes + [player.readAheadMegabytes].compactMap { $0 }).uniqueSorted()
    }
}

private extension Array where Element: Hashable & Comparable {
    func uniqueSorted() -> [Element] {
        Set(self).sorted()
    }
}

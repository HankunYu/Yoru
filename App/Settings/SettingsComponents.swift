import SwiftUI

/// Picks a track language; a hand-written list in the file shows up as an extra entry.
struct LanguagePicker: View {
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
struct SettingLabel: View {
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

/// A labelled slider row with its current value shown at the trailing edge.
struct SettingSlider: View {
    let title: LocalizedStringKey
    let symbol: String
    let valueText: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SettingLabel(title, detail: nil, symbol: symbol)
                Spacer()
                Text(valueText)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range, step: step)
        }
        .padding(.vertical, 4)
    }
}

/// The shared look of a settings page.
struct SettingsForm<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: Content

    var body: some View {
        Form {
            content
                .listRowBackground(Theme.card)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

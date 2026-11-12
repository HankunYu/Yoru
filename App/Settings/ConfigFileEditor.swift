import SwiftUI

/// The text config files that can be edited from Settings.
enum ConfigFile: String, CaseIterable, Identifiable {
    case mpv = "mpv.conf"
    case input = "input.conf"
    case yoru = "script-opts/yoru.conf"

    var id: String { rawValue }
    var url: URL { ConfigDirectory.url.appending(path: rawValue) }

    var title: String {
        switch self {
        case .mpv: "mpv.conf"
        case .input: "input.conf"
        case .yoru: "yoru.conf"
        }
    }

    var summary: LocalizedStringKey {
        switch self {
        case .mpv: "Player options: video, audio, subtitles, languages."
        case .input: "Key and gesture bindings."
        case .yoru: "Options for YORU's own interface."
        }
    }

    var symbol: String {
        switch self {
        case .mpv: "slider.horizontal.3"
        case .input: "hand.tap"
        case .yoru: "gearshape"
        }
    }
}

/// A plain-text editor for one config file.
struct ConfigFileEditor: View {
    let file: ConfigFile

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var savedText = ""
    @State private var isConfirmingRestore = false
    @State private var errorMessage: String?

    private var hasChanges: Bool { text != savedText }

    var body: some View {
        TextEditor(text: $text)
            .font(.system(size: 13, design: .monospaced))
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 12)
            .background(Theme.background)
            .navigationTitle(file.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(!hasChanges)
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button("Restore Default", systemImage: "arrow.uturn.backward") {
                        isConfirmingRestore = true
                    }
                }
            }
            .confirmationDialog(
                "Replace \(file.title) with YORU's default?",
                isPresented: $isConfirmingRestore,
                titleVisibility: .visible
            ) {
                Button("Restore Default", role: .destructive) {
                    text = ConfigDirectory.defaultContents(of: file.rawValue) ?? ""
                }
            } message: {
                Text("Nothing is written until you save.")
            }
            .alert("Could Not Save", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .onAppear(perform: load)
    }

    private func load() {
        text = (try? String(contentsOf: file.url, encoding: .utf8)) ?? ""
        savedText = text
    }

    private func save() {
        do {
            try text.write(to: file.url, atomically: true, encoding: .utf8)
            savedText = text
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

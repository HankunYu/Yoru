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

    var body: some View {
        PlainTextEditor(
            title: file.title,
            load: { (try? String(contentsOf: file.url, encoding: .utf8)) ?? "" },
            save: { try $0.write(to: file.url, atomically: true, encoding: .utf8) },
            restore: .init(
                title: "Restore Default",
                prompt: "Replace \(file.title) with YORU's default?",
                contents: { ConfigDirectory.defaultContents(of: file.rawValue) ?? "" }
            )
        )
    }
}

/// A plain-text editor for a file: monospaced, saved on request, with an optional way
/// back to some earlier text.
struct PlainTextEditor: View {
    struct Restore {
        let title: LocalizedStringKey
        let prompt: LocalizedStringKey
        /// The text to go back to. It replaces what is in the editor; nothing is written
        /// until the user saves.
        let contents: () -> String
    }

    let title: String
    let load: () -> String
    let save: (String) throws -> Void
    var restore: Restore?

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
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: write)
                        .disabled(!hasChanges)
                }
                if let restore {
                    ToolbarItem(placement: .secondaryAction) {
                        Button(restore.title, systemImage: "arrow.uturn.backward") {
                            isConfirmingRestore = true
                        }
                    }
                }
            }
            .confirmationDialog(
                restore?.prompt ?? "",
                isPresented: $isConfirmingRestore,
                titleVisibility: .visible
            ) {
                Button(restore?.title ?? "", role: .destructive) {
                    text = restore?.contents() ?? text
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
            .onAppear {
                text = load()
                savedText = text
            }
    }

    private func write() {
        do {
            try save(text)
            savedText = text
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

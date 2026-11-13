import SwiftUI

/// One shader: the numbers its author meant to be changed, its source, and a check of
/// whether the renderer accepts it.
struct ShaderDetailView: View {
    let name: String

    @State private var source = ShaderSource("")
    @State private var users: [ShaderLibrary.Group] = []
    @State private var hasOriginal = false
    @State private var check: CheckState = .idle
    @State private var isConfirmingRestore = false

    private enum CheckState: Equatable {
        case idle
        case running
        case done(ShaderCheck.Result)
    }

    var body: some View {
        SettingsForm(title: "Shader") {
            Section {
                Text(verbatim: name)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                if !users.isEmpty {
                    LabeledContent("Used In", value: users.map(\.title).joined(separator: ", "))
                }
            }

            let parameters = source.parameters
            if !parameters.isEmpty {
                Section {
                    ForEach(parameters) { parameter in
                        ParameterRow(parameter: parameter) { value in
                            source.set(parameter, to: value)
                            save()
                        }
                    }
                } header: {
                    Text("Values")
                } footer: {
                    Text("The numbers the shader defines at its top. Changes apply to the next video you open.")
                }
            }

            Section {
                NavigationLink {
                    PlainTextEditor(
                        title: ShaderLibrary.title(of: name),
                        load: { ShaderLibrary.text(of: name) },
                        save: { try ShaderLibrary.write($0, to: name) }
                    )
                } label: {
                    SettingLabel("Edit Source", detail: nil, symbol: "chevron.left.forwardslash.chevron.right")
                }
                if hasOriginal {
                    Button("Restore Original", systemImage: "arrow.uturn.backward", role: .destructive) {
                        isConfirmingRestore = true
                    }
                }
            }

            Section {
                Button {
                    runCheck()
                } label: {
                    HStack {
                        SettingLabel("Check Shader", detail: nil, symbol: "checkmark.seal")
                        Spacer()
                        if check == .running {
                            ProgressView()
                        }
                    }
                }
                .disabled(check == .running)
                if case .done(let result) = check {
                    if result.isClean {
                        Label("No problems found.", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else if !result.didRun, result.messages.isEmpty {
                        Label("The check could not be run.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    } else {
                        Text(verbatim: result.messages.joined(separator: "\n"))
                            .font(.caption.monospaced())
                            .foregroundStyle(.orange)
                            .textSelection(.enabled)
                    }
                }
            } footer: {
                Text("Runs a second of video through the renderer with only this shader on, and shows what it objected to. A shader with a mistake does no harm, it just has no effect.")
            }
        }
        .confirmationDialog(
            "Put this shader back as it was before it was edited here?",
            isPresented: $isConfirmingRestore, titleVisibility: .visible
        ) {
            Button("Restore Original", role: .destructive) {
                try? ShaderLibrary.restoreOriginal(of: name)
                load()
            }
        }
        // Also on coming back from the source editor.
        .onAppear(perform: load)
    }

    private func load() {
        source = ShaderSource(ShaderLibrary.text(of: name))
        users = ShaderLibrary.load().groups(using: name)
        hasOriginal = ShaderLibrary.hasOriginal(of: name)
        check = .idle
    }

    private func save() {
        try? ShaderLibrary.write(source.text, to: name)
        hasOriginal = ShaderLibrary.hasOriginal(of: name)
        check = .idle
    }

    private func runCheck() {
        check = .running
        let path = ShaderLibrary.path(of: name)
        Task {
            let result = await Task.detached(priority: .userInitiated) { ShaderCheck.run(shader: path) }.value
            check = .done(result)
        }
    }
}

/// One adjustable number of a shader: typed in, or stepped by its last written digit.
private struct ParameterRow: View {
    let parameter: ShaderSource.Parameter
    let onChange: (String) -> Void

    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(verbatim: parameter.name)
                    .font(.callout.monospaced())
                Spacer(minLength: 12)
                TextField("", text: $text)
                    .keyboardType(.numbersAndPunctuation)
                    .multilineTextAlignment(.trailing)
                    .font(.callout.monospacedDigit())
                    .frame(maxWidth: 90)
                    .focused($isFocused)
                    .onSubmit(commit)
                Stepper("", onIncrement: { step(by: 1) }, onDecrement: { step(by: -1) })
                    .labelsHidden()
            }
            if let comment = parameter.comment {
                Text(verbatim: comment)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .onAppear { text = parameter.value }
        .onChange(of: parameter.value) { text = parameter.value }
        .onChange(of: isFocused) { if !isFocused { commit() } }
    }

    private func step(by direction: Double) {
        let current = Double(text) ?? Double(parameter.value) ?? 0
        let value = parameter.formatted(current + direction * parameter.step)
        text = value
        onChange(value)
    }

    /// Takes what was typed if it is a number, written the way the shader writes it.
    private func commit() {
        guard let number = Double(text) else {
            text = parameter.value
            return
        }
        let value = parameter.formatted(number)
        text = value
        if value != parameter.value {
            onChange(value)
        }
    }
}

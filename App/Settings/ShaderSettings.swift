import SwiftUI
import UniformTypeIdentifiers

/// The shader library: what is in the config directory's `shaders` folder, and the groups
/// made of it. Everything here is a file there; nothing is kept anywhere else.
struct ShaderSettings: View {
    @State private var library = ShaderLibrary(names: [])
    @State private var isImporting = false
    /// A shader about to be deleted that groups still name.
    @State private var shaderInUse: String?

    var body: some View {
        SettingsForm(title: "Shaders") {
            Section {
                ForEach(library.groups) { group in
                    NavigationLink {
                        ShaderGroupEditor(file: group.file)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: group.title)
                            Text(detail(of: group))
                                .font(.caption)
                                .foregroundStyle(library.missingCount(in: group) > 0 ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        }
                    }
                }
                .onDelete { offsets in
                    for group in offsets.map({ library.groups[$0] }) {
                        Self.delete(group)
                    }
                    reload()
                }
                Button("New Group", systemImage: "plus") {
                    let name = library.unusedGroupName(String(localized: "New Group"))
                    try? ShaderLibrary.save([], asGroupNamed: name)
                    reload()
                }
            } header: {
                Text("Groups")
            } footer: {
                Text("A group switches several shaders on together, in a fixed order. Groups are switched in the player, under Adjustments > Picture.")
            }

            Section {
                ForEach(library.builtInShaders, id: \.self) { shader in
                    shaderLink(shader)
                }
            } header: {
                Text("Built-in")
            } footer: {
                Text("These come with YORU. An edited one can be put back as it was.")
            }

            if !library.importedShaders.isEmpty {
            Section {
                ForEach(library.importedShaders, id: \.self) { shader in
                    shaderLink(shader)
                }
                .onDelete { offsets in
                    let imported = library.importedShaders
                    for shader in offsets.map({ imported[$0] }) {
                        if library.groups(using: shader).isEmpty {
                            ShaderLibrary.delete(shader)
                        } else {
                            shaderInUse = shader
                        }
                    }
                    reload()
                }
            } header: {
                Text("Imported")
            }
            }

            if !library.tables.isEmpty {
                Section {
                    ForEach(library.tables, id: \.self) { table in
                        Text(verbatim: ShaderLibrary.title(of: table))
                    }
                    .onDelete { offsets in
                        offsets.map { library.tables[$0] }.forEach(ShaderLibrary.delete)
                        reload()
                    }
                } header: {
                    Text("Color Tables")
                }
            }

            Section {
                Button("Import Files", systemImage: "square.and.arrow.down") { isImporting = true }
            } footer: {
                Text("Takes .glsl shaders, .cube color tables and .group files. They are kept in the mpv/shaders folder inside YORU in the Files app, where they can also be copied directly.")
            }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                ShaderLibrary.importFiles(urls)
                reload()
            }
        }
        .confirmationDialog(
            "Groups use this shader. Delete it anyway?",
            isPresented: Binding(get: { shaderInUse != nil }, set: { if !$0 { shaderInUse = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let shaderInUse {
                    ShaderLibrary.delete(shaderInUse)
                    reload()
                }
            }
        } message: {
            Text("The groups keep its name and skip it while it is missing.")
        }
        .onAppear(perform: reload)
    }

    private func shaderLink(_ shader: String) -> some View {
        NavigationLink {
            ShaderDetailView(name: shader)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: ShaderLibrary.title(of: shader))
                let notes = (library.edited.contains(shader) ? [String(localized: "Edited")] : [])
                    + library.groups(using: shader).map(\.title)
                if !notes.isEmpty {
                    Text(verbatim: notes.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    private func reload() {
        library = ShaderLibrary.load()
    }

    private func detail(of group: ShaderLibrary.Group) -> String {
        let missing = library.missingCount(in: group)
        let count = String(localized: "\(group.shaders.count) shaders")
        return missing > 0 ? count + " · " + String(localized: "\(missing) files missing") : count
    }

    /// Deletes a group's file, and forgets it as the group in use if it was.
    static func delete(_ group: ShaderLibrary.Group) {
        ShaderLibrary.deleteGroup(group.file)
        var options = YoruOptions.load()
        if options.shaderGroup == group.file {
            options.shaderGroup = nil
            options.shaders = []
            options.save()
        }
    }
}

/// One group: its name and its shaders in the order they are applied.
struct ShaderGroupEditor: View {
    @State var file: String

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var shaders: [String] = []
    @State private var library = ShaderLibrary(names: [])
    @State private var isAdding = false
    @State private var isLoaded = false

    var body: some View {
        SettingsForm(title: "Group") {
            Section {
                TextField("Name", text: $name)
                    .onSubmit(rename)
            } header: {
                Text("Name")
            }

            Section {
                ForEach(shaders, id: \.self) { shader in
                    HStack {
                        Text(verbatim: ShaderLibrary.title(of: shader))
                        if !library.shaders.contains(shader) {
                            Spacer()
                            Text("Missing")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }
                .onMove { shaders.move(fromOffsets: $0, toOffset: $1) }
                .onDelete { shaders.remove(atOffsets: $0) }
                Button("Add Shaders", systemImage: "plus") { isAdding = true }
                    .disabled(library.shaders.allSatisfy(shaders.contains))
            } header: {
                Text("Shaders")
            } footer: {
                Text("Applied from top to bottom. Drag to reorder.")
            }

            Section {
                Button("Duplicate Group", systemImage: "plus.square.on.square") {
                    try? ShaderLibrary.save(shaders, asGroupNamed: library.unusedGroupName(name))
                    dismiss()
                }
                Button("Delete Group", systemImage: "trash", role: .destructive) {
                    ShaderSettings.delete(ShaderLibrary.Group(file: file, shaders: shaders))
                    dismiss()
                }
            }
        }
        // Always arrangeable: reordering is what this page is for.
        .environment(\.editMode, .constant(.active))
        .onChange(of: shaders) { save() }
        .onAppear(perform: load)
        .onDisappear(perform: rename)
        .sheet(isPresented: $isAdding) {
            ShaderPicker(candidates: library.shaders.filter { !shaders.contains($0) }) { shaders += $0 }
        }
    }

    private func load() {
        library = ShaderLibrary.load()
        guard !isLoaded else { return }
        isLoaded = true
        name = ShaderLibrary.title(of: file)
        shaders = library.groups.first { $0.file == file }?.shaders ?? []
    }

    private func save() {
        guard isLoaded, FileManager.default.fileExists(atPath: ShaderLibrary.directory.appending(path: file).path) else { return }
        try? ShaderLibrary.Group(file: file, shaders: shaders).text
            .write(to: ShaderLibrary.directory.appending(path: file), atomically: true, encoding: .utf8)
    }

    private func rename() {
        guard isLoaded, name != ShaderLibrary.title(of: file) else { return }
        guard let renamed = ShaderLibrary.renameGroup(file, to: name) else {
            // Taken or empty: the old name stands.
            name = ShaderLibrary.title(of: file)
            return
        }
        // The group in use is known by its file name.
        var options = YoruOptions.load()
        if options.shaderGroup == file {
            options.shaderGroup = renamed
            options.save()
        }
        file = renamed
    }
}

/// Picks shaders of the library to add to a group.
private struct ShaderPicker: View {
    let candidates: [String]
    let onAdd: ([String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var picked: [String] = []

    var body: some View {
        NavigationStack {
            SettingsForm(title: "Add Shaders") {
                Section {
                    ForEach(candidates, id: \.self) { shader in
                        Button {
                            if let index = picked.firstIndex(of: shader) {
                                picked.remove(at: index)
                            } else {
                                picked.append(shader)
                            }
                        } label: {
                            HStack {
                                Text(verbatim: ShaderLibrary.title(of: shader))
                                    .foregroundStyle(.primary)
                                Spacer()
                                // Added in the order they are picked.
                                if let index = picked.firstIndex(of: shader) {
                                    Text(verbatim: "\(index + 1)")
                                        .font(.caption.weight(.bold).monospacedDigit())
                                        .foregroundStyle(.black)
                                        .frame(width: 22, height: 22)
                                        .background(Theme.accent, in: .circle)
                                }
                            }
                        }
                    }
                } footer: {
                    Text("They are added in the order you pick them.")
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        onAdd(picked)
                        dismiss()
                    }
                    .disabled(picked.isEmpty)
                }
            }
        }
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
    }
}

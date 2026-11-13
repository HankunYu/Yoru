import Foundation

/// The picture shaders and color tables there are to use: those that come with the app,
/// and those a user has put in the config directory's `shaders` folder. Shaders are `.glsl`
/// files in mpv's hook format (Anime4K, FSRCNNX and the like), tables `.cube` lookup
/// tables. They are data for the GPU, which is why they can be brought in at all; FFmpeg's
/// own filters are compiled in and cannot.
///
/// A file in the folder stands in for a built-in shader of the same name: that is how a
/// built-in one is edited, and removing the file brings the app's own back.
struct ShaderLibrary: Equatable {
    static let directory = ConfigDirectory.url.appending(path: "shaders", directoryHint: .isDirectory)

    /// The shaders shipped in the app, read-only and replaced with each update.
    static let builtInDirectory = Bundle.main.resourceURL?.appending(path: "Shaders", directoryHint: .isDirectory)

    /// File names of the shaders that come with the app, in listing order.
    static let builtInShaders: [String] = {
        guard let builtInDirectory else { return [] }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: builtInDirectory.path)) ?? []
        return ShaderLibrary(names: names).shaders
    }()

    static func isBuiltIn(_ name: String) -> Bool {
        builtInShaders.contains(name)
    }

    /// Several shaders used as one, in a fixed order: what a set such as Anime4K comes as,
    /// one mode being half a dozen files. A group is a text file in the folder, `Name.group`,
    /// listing shader file names, so it can be written by hand, copied and shared.
    struct Group: Equatable, Identifiable {
        /// The group's file name, e.g. `Anime4K A.group`.
        let file: String
        /// The shaders it names, in order, whether or not they are there.
        let shaders: [String]

        var id: String { file }
        var title: String { ShaderLibrary.title(of: file) }

        /// Reads a group's text: a shader file name a line, or mpv's own spelling of a
        /// list, colon-separated with `~~/shaders/` before each name, so a line from a
        /// shader's install notes can be pasted as it is. Lines starting with # are notes.
        init(file: String, text: String) {
            self.file = file
            shaders = text.split(whereSeparator: \.isNewline)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
                .flatMap { $0.split(separator: ":") }
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'")) }
                .map { $0.hasPrefix("~~/shaders/") ? String($0.dropFirst("~~/shaders/".count)) : $0 }
                .filter { !$0.isEmpty }
        }

        init(file: String, shaders: [String]) {
            self.file = file
            self.shaders = shaders
        }

        /// The text of the group's file.
        var text: String { shaders.joined(separator: "\n") + "\n" }
    }

    static let groupExtension = "group"

    /// File names, in the order a file listing would show them. Shaders are the app's
    /// own and the folder's together.
    var shaders: [String] = []
    var tables: [String] = []
    var groups: [Group] = []
    /// The built-in shaders a file in the folder stands in for.
    var edited: Set<String> = []

    /// The shaders that are the user's own, not the app's.
    var importedShaders: [String] { shaders.filter { !Self.isBuiltIn($0) } }
    /// The shaders that come with the app.
    var builtInShaders: [String] { shaders.filter(Self.isBuiltIn) }

    static func load() -> ShaderLibrary {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        var library = ShaderLibrary(names: names + builtInShaders.filter { !names.contains($0) })
        library.edited = Set(names.filter(isBuiltIn))
        library.groups = names
            .filter { ($0 as NSString).pathExtension.lowercased() == groupExtension }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .compactMap { name in
                (try? String(contentsOf: directory.appending(path: name), encoding: .utf8)).map { Group(file: name, text: $0) }
            }
        return library
    }

    /// Writes a group to the folder, replacing one of the same name. Returns its file name.
    @discardableResult
    static func save(_ shaders: [String], asGroupNamed name: String) throws -> String {
        // A name is a file name: no path separators.
        let cleaned = name.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces)
        let file = cleaned + "." + groupExtension
        try Group(file: file, shaders: shaders).text.write(to: directory.appending(path: file), atomically: true, encoding: .utf8)
        return file
    }

    static func deleteGroup(_ file: String) {
        try? FileManager.default.removeItem(at: directory.appending(path: file))
    }

    // MARK: - Files

    /// Where the untouched copy of an edited shader is kept, to go back to.
    private static let originals = directory.appending(path: ".originals", directoryHint: .isDirectory)

    /// The file a name stands for: the one in the folder, else the app's own.
    static func url(of name: String) -> URL {
        let file = directory.appending(path: name)
        if !FileManager.default.fileExists(atPath: file.path), isBuiltIn(name), let builtInDirectory {
            return builtInDirectory.appending(path: name)
        }
        return file
    }

    /// Where a shader is kept as it was before it was edited: in the app for a built-in
    /// one, else in the folder set aside for it.
    private static func original(of name: String) -> URL {
        if isBuiltIn(name), let builtInDirectory {
            return builtInDirectory.appending(path: name)
        }
        return originals.appending(path: name)
    }

    static func text(of name: String) -> String {
        (try? String(contentsOf: url(of: name), encoding: .utf8)) ?? ""
    }

    /// Writes a shader's text to the folder, first setting its present contents aside if
    /// no original is kept yet: the first edit is the one that needs undoing.
    static func write(_ text: String, to name: String) throws {
        let file = directory.appending(path: name)
        let original = original(of: name)
        if FileManager.default.fileExists(atPath: file.path), !FileManager.default.fileExists(atPath: original.path) {
            try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: file, to: original)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
    }

    /// Whether a shader has been edited here and can be put back.
    static func hasOriginal(of name: String) -> Bool {
        FileManager.default.fileExists(atPath: directory.appending(path: name).path)
            && FileManager.default.fileExists(atPath: original(of: name).path)
    }

    /// Puts a shader back as it was before it was first edited here.
    static func restoreOriginal(of name: String) throws {
        let file = directory.appending(path: name)
        if isBuiltIn(name) {
            // The app's own shows again once nothing stands in for it.
            try FileManager.default.removeItem(at: file)
        } else {
            _ = try FileManager.default.replaceItemAt(file, withItemAt: originals.appending(path: name))
        }
    }

    /// Copies files picked elsewhere into the folder. A file of the same name is replaced.
    /// Returns how many were taken: those of a kind the library holds.
    @discardableResult
    static func importFiles(_ urls: [URL]) -> Int {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var count = 0
        for url in urls {
            let kind = url.pathExtension.lowercased()
            guard ["glsl", "hook", "cube", groupExtension].contains(kind) else { continue }
            let isScoped = url.startAccessingSecurityScopedResource()
            defer { if isScoped { url.stopAccessingSecurityScopedResource() } }
            let destination = directory.appending(path: url.lastPathComponent)
            try? FileManager.default.removeItem(at: destination)
            if (try? FileManager.default.copyItem(at: url, to: destination)) != nil {
                count += 1
            }
        }
        return count
    }

    /// Deletes a shader or color table from the folder, and the original kept of it.
    /// A built-in shader stays, as the app has it.
    static func delete(_ name: String) {
        try? FileManager.default.removeItem(at: directory.appending(path: name))
        try? FileManager.default.removeItem(at: originals.appending(path: name))
    }

    /// Renames a group's file. Returns the new file name, or nil if the name is taken or empty.
    static func renameGroup(_ file: String, to name: String) -> String? {
        let cleaned = name.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces)
        let renamed = cleaned + "." + groupExtension
        guard !cleaned.isEmpty, renamed != file,
              !FileManager.default.fileExists(atPath: directory.appending(path: renamed).path),
              (try? FileManager.default.moveItem(at: directory.appending(path: file), to: directory.appending(path: renamed))) != nil
        else { return nil }
        return renamed
    }

    /// A name no group has yet: `base`, or `base 2`, `base 3` ...
    func unusedGroupName(_ base: String) -> String {
        let taken = Set(groups.map { $0.title.lowercased() })
        guard taken.contains(base.lowercased()) else { return base }
        return (2...).lazy.map { "\(base) \($0)" }.first { !taken.contains($0.lowercased()) } ?? base
    }

    /// The groups that name a shader.
    func groups(using shader: String) -> [Group] {
        groups.filter { $0.shaders.contains(shader) }
    }

    /// How many of a group's shaders are not in the folder.
    func missingCount(in group: Group) -> Int {
        group.shaders.count { !shaders.contains($0) }
    }

    init(names: [String]) {
        let sorted = names.filter { !$0.hasPrefix(".") }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        shaders = sorted.filter { ["glsl", "hook"].contains(($0 as NSString).pathExtension.lowercased()) }
        tables = sorted.filter { ($0 as NSString).pathExtension.lowercased() == "cube" }
    }

    var isEmpty: Bool { shaders.isEmpty && tables.isEmpty && groups.isEmpty }

    /// Where mpv finds a file of the library.
    static func path(of name: String) -> String {
        url(of: name).path
    }

    /// A file's name as shown: without its extension, and for a built-in shader in the
    /// language of the app.
    static func title(of name: String) -> String {
        let title = (name as NSString).deletingPathExtension
        return isBuiltIn(name) ? Bundle.main.localizedString(forKey: title, value: title, table: nil) : title
    }

    /// What of a remembered selection is still there, in its remembered order: files get
    /// renamed and removed between sessions.
    func existing(_ selection: [String]) -> [String] {
        selection.filter(shaders.contains)
    }
}

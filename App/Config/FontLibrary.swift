import CoreText
import Foundation

/// The fonts in the config directory's `fonts/` folder: the only ones subtitles can use,
/// since libass cannot open system fonts from inside the sandbox.
enum FontLibrary {
    /// Family of the bundled font, the app's default `sub-font`.
    static let defaultFamily = "Noto Sans CJK SC"

    /// Family names of every font file in `fonts/`, sorted.
    static func families() -> [String] {
        let directory = ConfigDirectory.url.appending(path: "fonts", directoryHint: .isDirectory)
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var families: Set<String> = []
        for file in files {
            let descriptors = CTFontManagerCreateFontDescriptorsFromURL(file as CFURL) as? [CTFontDescriptor] ?? []
            for descriptor in descriptors {
                if let family = CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String {
                    families.insert(family)
                }
            }
        }
        return families.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

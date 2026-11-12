import Foundation

/// Picks the subtitle to start with when external subtitles came from the app rather than
/// from mpv's own same-folder scan.
///
/// mpv reads the language of a subtitle it finds itself from the file name
/// (`Movie.chs.ass`), and its language preference then applies to it. Subtitles handed
/// over by the app (remote sources) carry no language, so the preference never selects
/// them. This applies the same idea: rank every subtitle by the preferred languages, taking
/// an external one's language from its file name, and say which should be selected.
enum SubtitleChooser {
    struct Candidate {
        let id: Int
        let isSelected: Bool
        /// The language tag of an embedded track.
        let language: String?
        /// The file name of an external track; nil for embedded ones.
        let externalName: String?
    }

    /// The track to switch to, or nil to keep mpv's own choice.
    ///
    /// - Parameters:
    ///   - codes: Preferred language codes, best first (mpv's `slang`). Empty for no preference.
    ///   - stem: The video's file name without its extension.
    static func choice(among candidates: [Candidate], codes: [String], stem: String) -> Int? {
        let externals = candidates.filter { $0.externalName != nil }
        guard !externals.isEmpty else { return nil }
        let codes = codes.map { $0.lowercased() }
        let selected = candidates.first(where: \.isSelected)

        guard !codes.isEmpty else {
            // No preference: an external subtitle was put there to be used, so take the
            // plainest one unless mpv already picked something.
            return selected == nil ? plainest(externals)?.id : nil
        }
        let ranked = externals.compactMap { candidate in
            rank(of: candidate, codes: codes, stem: stem).map { (candidate, $0) }
        }
        guard let best = ranked.map(\.1).min() else { return nil }
        // An external subtitle wins a tie: it was added on purpose.
        if let selected, let current = rank(of: selected, codes: codes, stem: stem), current < best {
            return nil
        }
        let winner = plainest(ranked.filter { $0.1 == best }.map(\.0))
        return winner?.id == selected?.id ? nil : winner?.id
    }

    // MARK: - Private

    /// Position of the candidate's language in the preference list; nil if it is not in it.
    private static func rank(of candidate: Candidate, codes: [String], stem: String) -> Int? {
        let tags = candidate.externalName.map { tags(inFileName: $0, stem: stem) }
            ?? [candidate.language?.lowercased()].compactMap { $0 }
        return codes.firstIndex { code in tags.contains { $0 == code || $0.hasPrefix(code + "-") } }
    }

    /// The dot-separated parts between the video's name and the extension, further split on
    /// separators: `Movie.zh-CN&en.forced.ass` gives `zh-cn`, `zh`, `cn`, `en`, `forced`.
    private static func tags(inFileName name: String, stem: String) -> [String] {
        var rest = (name as NSString).deletingPathExtension.lowercased()
        let stem = stem.lowercased()
        if rest.hasPrefix(stem) {
            rest = String(rest.dropFirst(stem.count))
        }
        var tags: [String] = []
        for part in rest.split(whereSeparator: { ".[]()&+, ".contains($0) }) {
            tags.append(String(part))
            let pieces = part.split(whereSeparator: { "-_".contains($0) })
            if pieces.count > 1 {
                tags += pieces.map(String.init)
            }
        }
        return tags
    }

    /// Among equally good subtitles, the one with the shortest name: `Movie.chs.ass` rather
    /// than `Movie.chs.commentary.ass`.
    private static func plainest(_ candidates: [Candidate]) -> Candidate? {
        candidates.min { ($0.externalName?.count ?? 0, $0.id) < ($1.externalName?.count ?? 0, $1.id) }
    }
}

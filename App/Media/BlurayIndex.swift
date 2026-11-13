import Foundation

/// Which playlist each numbered title of a Blu-ray disc plays.
///
/// A disc numbers its titles in `index.bdmv`; each points at a movie object in
/// `MovieObject.bdmv`, a short program that sooner or later plays a playlist. The names a
/// disc gives its titles go by these numbers, so this is the way from a name to a
/// playlist. Programs that choose a playlist while running (from a register, or in Java)
/// cannot be followed, and their titles are left out.
enum BlurayIndex {
    /// Title number (from 1) to playlist name, for the titles that play exactly one.
    static func playlists(index: Data, movieObjects: Data) -> [Int: String] {
        let objects = programs(movieObjects)
        var result: [Int: String] = [:]
        for (number, object) in titleObjects(index) {
            let played = playlists(playedBy: object, in: objects, depth: 0)
            if played.count == 1, let playlist = played.first {
                result[number] = String(format: "%05d", playlist)
            }
        }
        return result
    }

    /// Title number to the movie object it starts, for titles run by movie objects.
    private static func titleObjects(_ data: Data) -> [Int: Int] {
        var reader = BinaryReader(data)
        guard reader.text(4) == "INDX", reader.skip(4), let start = reader.uint32() else { return [:] }
        // Length, then first playback and top menu, twelve bytes each, then the titles.
        reader.offset = Int(start)
        guard reader.skip(4 + 24), let count = reader.uint16() else { return [:] }
        var objects: [Int: Int] = [:]
        for number in 1...max(Int(count), 1) where number <= Int(count) {
            // Object type in the top two bits: 1 is a movie object, 2 Java.
            guard let type = reader.uint8(), reader.skip(5), let object = reader.uint16(), reader.skip(4) else { break }
            if type >> 6 == 1 {
                objects[number] = Int(object)
            }
        }
        return objects
    }

    private enum Command {
        case play(playlist: Int)
        case jump(object: Int)
    }

    /// The commands of each movie object that play a playlist or hand over to another
    /// object, where the operand is written out rather than taken from a register.
    private static func programs(_ data: Data) -> [[Command]] {
        var reader = BinaryReader(data)
        guard reader.text(4) == "MOBJ", reader.skip(36), reader.skip(8), let count = reader.uint16() else { return [] }
        var programs: [[Command]] = []
        for _ in 0..<count {
            guard reader.skip(2), let commandCount = reader.uint16() else { break }
            var commands: [Command] = []
            for _ in 0..<commandCount {
                guard let operation = reader.uint8(), let options = reader.uint8(), reader.skip(2),
                      let destination = reader.uint32(), reader.skip(4) else { return programs }
                // Group 0 is branching; its sub group 1 jumps, 2 plays.
                let group = operation >> 3 & 0b11
                let subGroup = operation & 0b111
                let isImmediate = options & 0x80 != 0
                let option = options & 0x0F
                guard group == 0, isImmediate else { continue }
                if subGroup == 2, option <= 2 {
                    commands.append(.play(playlist: Int(destination)))
                } else if subGroup == 1, option == 1 || option == 3 {
                    // Jump to, or call, another object.
                    commands.append(.jump(object: Int(destination)))
                }
            }
            programs.append(commands)
        }
        return programs
    }

    private static func playlists(playedBy object: Int, in programs: [[Command]], depth: Int) -> Set<Int> {
        guard object < programs.count, depth < 4 else { return [] }
        var played: Set<Int> = []
        for command in programs[object] {
            switch command {
            case .play(let playlist): played.insert(playlist)
            case .jump(let next): played.formUnion(playlists(playedBy: next, in: programs, depth: depth + 1))
            }
        }
        return played
    }
}

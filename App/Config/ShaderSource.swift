import Foundation

/// The text of a shader, as far as the app edits it: the numbers its author meant to be
/// changed. Those are written as `#define NAME 0.5  // what it does` near the top, and
/// each such line is offered as a setting. Everything else is left to the text editor.
struct ShaderSource: Equatable {
    struct Parameter: Equatable, Identifiable {
        let name: String
        /// The number as written, e.g. `0.55` or `288.0`.
        var value: String
        /// The comment after it on the line, if any.
        let comment: String?
        /// Which line of the text it is on.
        let line: Int

        var id: String { name }

        /// Whether the number is written with a decimal point, and so must stay a float.
        var isDecimal: Bool { value.contains(".") }

        /// How much one press of a stepper changes it: a unit of its last written digit,
        /// taking `288.0` as counting in ones.
        var step: Double {
            guard let point = value.firstIndex(of: ".") else { return 1 }
            let fraction = value[value.index(after: point)...]
            let digits = fraction.allSatisfy { $0 == "0" } ? 0 : fraction.count
            return pow(10, -Double(digits))
        }

        /// The value as written after a change, keeping its number of decimals and the
        /// point a float needs.
        func formatted(_ number: Double) -> String {
            guard isDecimal else { return String(Int(number.rounded())) }
            let fraction = value[value.index(after: value.firstIndex(of: ".")!)...]
            return String(format: "%.\(max(fraction.count, 1))f", number)
        }
    }

    private(set) var text: String

    init(_ text: String) {
        self.text = text
    }

    private nonisolated(unsafe) static let pattern = /^(\s*#define\s+)([A-Za-z_]\w*)(\s+)(-?(?:\d+\.?\d*|\.\d+))(\s*)(?:\/\/\s*(.*?))?\s*$/

    var parameters: [Parameter] {
        var seen: Set<String> = []
        return text.split(separator: "\n", omittingEmptySubsequences: false).enumerated().compactMap { index, line in
            guard let match = String(line).wholeMatch(of: Self.pattern), seen.insert(String(match.2)).inserted else { return nil }
            let comment = match.6.map(String.init).flatMap { $0.isEmpty ? nil : $0 }
            return Parameter(name: String(match.2), value: String(match.4), comment: comment, line: index)
        }
    }

    /// Writes a new number into a parameter's line, leaving the rest of the line alone.
    mutating func set(_ parameter: Parameter, to value: String) {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard parameter.line < lines.count, let match = lines[parameter.line].wholeMatch(of: Self.pattern),
              match.2 == parameter.name else { return }
        let line = lines[parameter.line]
        lines[parameter.line] = line.replacingCharacters(in: match.4.startIndex..<match.4.endIndex, with: value)
        text = lines.joined(separator: "\n")
    }
}

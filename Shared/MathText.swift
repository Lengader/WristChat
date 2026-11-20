import Foundation

enum MathText {
    enum Part: Equatable {
        case prose(String)
        case formula(latex: String, display: Bool)
    }

    private static let formulas = try! NSRegularExpression(pattern: #"""
        (?x)
        ^[ \t]{0,3}(?<fence>`{3,}|~{3,})[^\n]*\n[\s\S]*?(?:^[ \t]{0,3}\k<fence>[ \t]*$|\z)
        | (?<tick>`+)[^\n]*?\k<tick>(?!`)
        | (?<!\\)\\\[(?<block>[\s\S]*?)(?:\\\]|\](?=\^))(?<power>\^(?:\{[^{}]*\}|[A-Za-z0-9+\-]))?
        | (?<!\\)\\\((?<inline>[\s\S]*?)\\\)
        | (?<![\\$])\$\$(?<dollars>[\s\S]*?)\$\$
        | (?<![\\$])\$(?![\s$])(?<dollar>(?:\\\$|[^$\n])+?)(?<!\s)\$(?![\d$])
        | (?<!\\)(?<environment>\\begin\{(?<name>align\*?|aligned(?:at)?|alignat\*?|gather\*?|gathered|equation\*?|split|multline\*?|cases|[pPbBvV]?matrix|array)\}[\s\S]*?\\end\{\k<name>\})
        """#, options: .anchorsMatchLines)
    private static let proseSpacing = try! NSRegularExpression(pattern: #"(?<!\\)\\q?quad\b"#)
    private static let fractions = try! NSRegularExpression(pattern: #"\\(?:dfrac|tfrac|frac)\s*\{([^{}]*)\}\s*\{([^{}]*)\}"#)
    private static let roots = try! NSRegularExpression(pattern: #"\\sqrt\s*\{([^{}]*)\}"#)
    private static let scripts = try! NSRegularExpression(pattern: #"([_^])(?:\{([^{}]*)\}|([A-Za-z0-9+\-]))"#)
    private static let commands = try! NSRegularExpression(pattern: #"\\[A-Za-z]+|\\[,;! ]"#)
    private static let superscripts = Dictionary(uniqueKeysWithValues: zip("0123456789+-=()in", "⁰¹²³⁴⁵⁶⁷⁸⁹⁺⁻⁼⁽⁾ⁱⁿ"))
    private static let subscripts = Dictionary(uniqueKeysWithValues: zip("0123456789+-=()aehijklmnoprstuvx", "₀₁₂₃₄₅₆₇₈₉₊₋₌₍₎ₐₑₕᵢⱼₖₗₘₙₒₚᵣₛₜᵤᵥₓ"))
    private static let symbols = [
        #"\alpha"#: "α", #"\beta"#: "β", #"\gamma"#: "γ", #"\delta"#: "δ", #"\epsilon"#: "ε",
        #"\theta"#: "θ", #"\lambda"#: "λ", #"\mu"#: "μ", #"\pi"#: "π", #"\rho"#: "ρ",
        #"\sigma"#: "σ", #"\phi"#: "φ", #"\omega"#: "ω", #"\Delta"#: "Δ", #"\Omega"#: "Ω",
        #"\times"#: "×", #"\cdot"#: "·", #"\div"#: "÷", #"\pm"#: "±", #"\infty"#: "∞", #"\sum"#: "∑",
        #"\int"#: "∫", #"\prod"#: "∏", #"\partial"#: "∂", #"\approx"#: "≈", #"\neq"#: "≠", #"\ne"#: "≠",
        #"\le"#: "≤", #"\leq"#: "≤", #"\ge"#: "≥", #"\geq"#: "≥", #"\rightarrow"#: "→", #"\to"#: "→",
        #"\in"#: "∈", #"\forall"#: "∀", #"\exists"#: "∃", #"\left"#: "", #"\right"#: "",
        #"\sin"#: "sin", #"\cos"#: "cos", #"\tan"#: "tan", #"\log"#: "log", #"\ln"#: "ln", #"\lim"#: "lim",
        #"\quad"#: "  ", #"\qquad"#: "    ", #"\,"#: " ", #"\;"#: " ", #"\!"#: "", #"\ "#: " ",
    ]

    static func parts(_ text: String) -> [Part] {
        let original = text as NSString
        let range = NSRange(location: 0, length: original.length)
        var result: [Part] = []
        var prose = ""
        var cursor = 0
        func addProse(until end: Int) {
            let fragment = original.substring(with: NSRange(location: cursor, length: end - cursor))
            prose += replace(proseSpacing, in: fragment) { _ in "  " }
        }
        for match in formulas.matches(in: text, range: range) {
            func field(_ name: String) -> String? {
                let range = match.range(withName: name)
                return range.location == NSNotFound ? nil : original.substring(with: range)
            }
            addProse(until: match.range.location)
            cursor = NSMaxRange(match.range)
            let display = field("block") ?? field("dollars") ?? field("environment")
            guard let source = display ?? field("inline") ?? field("dollar"), !source.isEmpty else {
                prose += original.substring(with: match.range)
                continue
            }
            if !prose.isEmpty {
                result.append(.prose(prose))
                prose = ""
            }
            let latex = field("power").map { "(\(source))\($0)" } ?? source
            result.append(.formula(latex: latex, display: display != nil))
        }
        addProse(until: original.length)
        if !prose.isEmpty { result.append(.prose(prose)) }
        return result
    }

    static func readable(_ text: String) -> String {
        parts(text).map { part in
            switch part {
            case .prose(let fragment): fragment
            case .formula(let latex, _): normalize(latex)
            }
        }.joined()
    }

    private static func normalize(_ text: String) -> String {
        let fraction = replace(fractions, in: text) { "(\($0[1] ?? ""))⁄(\($0[2] ?? ""))" }
        let root = replace(roots, in: fraction) { "√(\($0[1] ?? ""))" }
        let words = replace(commands, in: root) { symbols[$0[0] ?? ""] ?? $0[0] ?? "" }
        return replace(scripts, in: words) { groups in
            let marker = groups[1] ?? "^"
            let value = groups[2] ?? groups[3] ?? ""
            let table = marker == "^" ? superscripts : subscripts
            let converted = value.compactMap { table[$0] }
            return converted.count == value.count ? String(converted) : marker + "(" + value + ")"
        }
    }

    private static func replace(_ pattern: NSRegularExpression, in text: String, using: ([String?]) -> String) -> String {
        let matches = pattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
        let result = NSMutableString(string: text)
        let original = text as NSString
        for match in matches.reversed() {
            let groups: [String?] = (0..<match.numberOfRanges).map { index in
                let range = match.range(at: index)
                return range.location == NSNotFound ? nil : original.substring(with: range)
            }
            result.replaceCharacters(in: match.range, with: using(groups))
        }
        return String(result)
    }
}

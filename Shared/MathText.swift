import Foundation

enum MathText {
    private static let formulas = try! NSRegularExpression(
        pattern: #"\\\[([\s\S]*?)\\\]((?:\^(?:\{[^{}]*\}|[A-Za-z0-9+\-]))?)|\\\(([\s\S]*?)\\\)|\$\$([\s\S]*?)\$\$|(?<!\\)\$(?![\s$])([^$\n]+?)(?<!\s)\$"#
    )
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
        #"\quad"#: "  ", #"\,"#: " ", #"\;"#: " ", #"\!"#: "", #"\ "#: " ",
    ]

    static func readable(_ text: String) -> String {
        replace(formulas, in: text) { groups in
            if let display = groups[1] {
                let power = groups[2] ?? ""
                return normalize(power.isEmpty ? display : "(\(display))\(power)")
            }
            return normalize(groups[3] ?? groups[4] ?? groups[5] ?? "")
        }
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

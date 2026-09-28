import Foundation

/// Values that ollama.com writes in English (`21.4M`, `5.2GB`, `2 weeks ago`,
/// `Text, Image input`), rewritten for a French interface. In English they are shown as is.
public enum LibraryText {
    /// Pull counts: `21.4M` → `21,4 M`.
    public static func count(_ value: String, french: Bool) -> String {
        guard french, let match = firstMatch(countPattern, in: value) else { return value }
        let unit = ["K": "k", "M": "M", "B": "Md"][match[2].uppercased()] ?? ""
        return decimal(match[1]) + (unit.isEmpty ? "" : "\u{202F}" + unit)
    }

    /// Download sizes (`5.2GB` → `5,2 Go`) and the usage levels of cloud models.
    public static func size(_ value: String, french: Bool) -> String {
        guard french else { return value }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        switch trimmed.lowercased() {
        case "low usage": return "Utilisation faible"
        case "medium usage": return "Utilisation moyenne"
        case "high usage": return "Utilisation élevée"
        case "extra high usage": return "Utilisation très élevée"
        default: break
        }
        guard let match = firstMatch(sizePattern, in: trimmed) else { return value }
        let units = ["B": "o", "KB": "Ko", "MB": "Mo", "GB": "Go", "TB": "To", "PB": "Po"]
        guard let unit = units[match[2].uppercased()] else { return value }
        return decimal(match[1]) + "\u{00A0}" + unit
    }

    /// Ages: `2 weeks ago` → `il y a 2 semaines`, `a month ago` → `il y a 1 mois`, `yesterday` → `hier`.
    public static func age(_ value: String, french: Bool) -> String {
        guard french else { return value }
        let words = value.lowercased().split(whereSeparator: \.isWhitespace)
        if words == ["yesterday"] { return "hier" }
        guard words.count == 3, words[2] == "ago" else { return value }
        let number: Int
        if ["a", "an", "one"].contains(words[0]) {
            number = 1
        } else if let parsed = Int(words[0]) {
            number = parsed
        } else {
            return value
        }
        var unit = String(words[1])
        if unit.hasSuffix("s") { unit.removeLast() }
        let plural = number > 1
        let french: String
        switch unit {
        case "second": french = plural ? "secondes" : "seconde"
        case "minute": french = plural ? "minutes" : "minute"
        case "hour": french = plural ? "heures" : "heure"
        case "day": french = plural ? "jours" : "jour"
        case "week": french = plural ? "semaines" : "semaine"
        case "month": french = "mois"
        case "year": french = plural ? "ans" : "an"
        default: return value
        }
        return "il y a \(number) \(french)"
    }

    /// Inputs of a tag, shown under an "Input" title: `Text, Image input` → `Text, Image`,
    /// or `Texte, image` in French.
    public static func input(_ value: String, french: Bool) -> String {
        var text = value.trimmingCharacters(in: .whitespaces)
        if text.lowercased().hasSuffix(" input") { text.removeLast(" input".count) }
        guard french else { return text }
        let names = ["text": "texte", "image": "image", "audio": "audio", "video": "vidéo", "file": "fichier"]
        let parts = text.split(separator: ",").map { part -> String in
            let word = part.trimmingCharacters(in: .whitespaces).lowercased()
            return names[word] ?? word
        }
        guard let first = parts.first, !first.isEmpty else { return value }
        return ([first.prefix(1).uppercased() + first.dropFirst()] + parts.dropFirst()).joined(separator: ", ")
    }

    // MARK: Helpers

    private static let countPattern = try! NSRegularExpression(pattern: #"^\s*(\d+(?:\.\d+)?)\s*([KMB]?)\s*$"#, options: .caseInsensitive)
    private static let sizePattern = try! NSRegularExpression(pattern: #"^(\d+(?:\.\d+)?)\s*([KMGTP]?B)$"#, options: .caseInsensitive)

    private static func firstMatch(_ regex: NSRegularExpression, in text: String) -> [String]? {
        let nsText = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: nsText.length)) else { return nil }
        return (0..<match.numberOfRanges).map { index in
            let range = match.range(at: index)
            return range.location == NSNotFound ? "" : nsText.substring(with: range)
        }
    }

    private static func decimal(_ number: String) -> String {
        number.replacingOccurrences(of: ".", with: ",")
    }
}

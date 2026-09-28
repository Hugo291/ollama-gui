import Foundation

/// Display helpers shared by the app.
public enum Format {
    /// File-style byte count, localized (`3.3 GB`, `3,3 Go`).
    public static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    /// Token counts the way Ollama prints context windows: `8K`, `256K`, `1M`.
    public static func tokens(_ value: Int) -> String {
        if value >= 1_048_576, value % 1_048_576 == 0 { return "\(value / 1_048_576)M" }
        if value >= 1024 { return "\(Int((Double(value) / 1024).rounded()))K" }
        return "\(value)"
    }

    /// Parameter counts: `268M`, `4.3B`, `2.8T`.
    public static func parameterCount(_ value: Int64) -> String {
        let number = Double(value)
        let (scaled, suffix): (Double, String) = switch number {
        case 1e12...: (number / 1e12, "T")
        case 1e9...: (number / 1e9, "B")
        case 1e6...: (number / 1e6, "M")
        case 1e3...: (number / 1e3, "K")
        default: (number, "")
        }
        let digits = scaled >= 100 ? 0 : 1
        var text = String(format: "%.\(digits)f", scaled)
        if text.hasSuffix(".0") { text.removeLast(2) }
        return text + suffix
    }

    /// Numeric value of a parameter size label (`873.44M`, `4.4B`, `2.81T`), for sorting.
    public static func parameterValue(_ label: String?) -> Double {
        guard var text = label?.trimmingCharacters(in: .whitespaces).uppercased(), !text.isEmpty else { return 0 }
        let multipliers: [Character: Double] = ["K": 1e3, "M": 1e6, "B": 1e9, "T": 1e12]
        var multiplier = 1.0
        if let last = text.last, let value = multipliers[last] {
            multiplier = value
            text.removeLast()
        }
        return (Double(text) ?? 0) * multiplier
    }

    /// Human wording for the statuses streamed by `/api/pull` and `/api/create`.
    public static func progressStatus(_ status: String) -> String {
        let lower = status.lowercased()
        if lower == "pulling manifest" { return String(localized: "Fetching manifest…") }
        if lower.hasPrefix("pulling ") || lower.hasPrefix("downloading") { return String(localized: "Downloading…") }
        if lower.hasPrefix("verifying") { return String(localized: "Verifying…") }
        if lower.hasPrefix("writing manifest") { return String(localized: "Writing manifest…") }
        if lower.hasPrefix("removing") { return String(localized: "Cleaning up…") }
        if lower.hasPrefix("using existing layer") || lower.hasPrefix("creating new layer") || lower.hasPrefix("using autodetected template") {
            return String(localized: "Preparing layers…")
        }
        if lower == "success" { return String(localized: "Completed") }
        return status
    }
}

import Foundation

/// Parses the RFC 3339 timestamps produced by Ollama, which carry up to nanosecond
/// precision (`2026-09-07T23:25:52.874993187+02:00`) that `ISO8601DateFormatter` rejects.
public enum OllamaDate {
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    public static func parse(_ string: String) -> Date? {
        var text = string.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }

        // Strip the fractional seconds and add them back afterwards.
        var fraction: TimeInterval = 0
        if let dot = text.firstIndex(of: ".") {
            let digitsStart = text.index(after: dot)
            let digitsEnd = text[digitsStart...].firstIndex(where: { !("0"..."9").contains($0) }) ?? text.endIndex
            let digits = text[digitsStart..<digitsEnd]
            if !digits.isEmpty {
                fraction = Double("0." + digits) ?? 0
            }
            text.removeSubrange(dot..<digitsEnd)
        }

        guard let date = formatter.date(from: text) else { return nil }
        return date.addingTimeInterval(fraction)
    }
}

extension KeyedDecodingContainer {
    /// Decodes an Ollama timestamp, returning `nil` instead of failing on odd values.
    func ollamaDate(forKey key: Key) -> Date? {
        guard let string = try? decodeIfPresent(String.self, forKey: key) else { return nil }
        return OllamaDate.parse(string)
    }
}

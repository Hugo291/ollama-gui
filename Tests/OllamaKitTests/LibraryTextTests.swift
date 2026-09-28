import Testing
@testable import OllamaKit

@Suite("ollama.com values and pages")
struct LibraryTextTests {
    @Test func frenchValues() {
        #expect(LibraryText.age("2 weeks ago", french: true) == "il y a 2 semaines")
        #expect(LibraryText.age("a month ago", french: true) == "il y a 1 mois")
        #expect(LibraryText.age("11 months ago", french: true) == "il y a 11 mois")
        #expect(LibraryText.age("1 year ago", french: true) == "il y a 1 an")
        #expect(LibraryText.age("an hour ago", french: true) == "il y a 1 heure")
        #expect(LibraryText.age("yesterday", french: true) == "hier")
        #expect(LibraryText.age("Updated recently", french: true) == "Updated recently")
        #expect(LibraryText.size("5.2GB", french: true) == "5,2\u{00A0}Go")
        #expect(LibraryText.size("815MB", french: true) == "815\u{00A0}Mo")
        #expect(LibraryText.size("Extra High Usage", french: true) == "Utilisation très élevée")
        #expect(LibraryText.input("Text, Image input", french: true) == "Texte, image")
        #expect(LibraryText.input("Text input", french: true) == "Texte")
        #expect(LibraryText.count("21.4M", french: true) == "21,4\u{202F}M")
        #expect(LibraryText.count("512.3K", french: true) == "512,3\u{202F}k")
        #expect(LibraryText.count("58", french: true) == "58")
    }

    @Test func englishValuesAreUnchanged() {
        for value in ["2 weeks ago", "5.2GB", "Extra High Usage", "Text, Image input", "21.4M"] {
            #expect(LibraryText.age(value, french: false) == value)
            #expect(LibraryText.size(value, french: false) == value)
            #expect(LibraryText.input(value, french: false) == value)
            #expect(LibraryText.count(value, french: false) == value)
        }
    }

    @Test func nextPageMarker() {
        let html = #"<li hx-get="/search?page=2&amp;q=qwen" hx-trigger="revealed"></li>"#
        #expect(LibraryParser.linksToPage(2, in: html))
        #expect(!LibraryParser.linksToPage(3, in: html))
        #expect(LibraryParser.linksToPage(3, in: #"<div hx-get="/search?page=3"></div>"#))
        #expect(!LibraryParser.linksToPage(2, in: "<ul></ul>"))
    }
}

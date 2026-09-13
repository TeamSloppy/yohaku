import Foundation
import StudyCore
import StudyIntelligence
import Testing
@testable import Yohaku

@MainActor
struct LocalizationTests {
    @Test
    func appBundleContainsEnglishAndRussianLocalizations() throws {
        let appBundle = Bundle(for: MarkdownTextView.self)
        #expect(Set(appBundle.localizations).isSuperset(of: ["en", "ru"]))

        let englishPath = try #require(appBundle.path(forResource: "en", ofType: "lproj"))
        let russianPath = try #require(appBundle.path(forResource: "ru", ofType: "lproj"))
        let english = try #require(Bundle(path: englishPath))
        let russian = try #require(Bundle(path: russianPath))

        #expect(english.localizedString(forKey: "Место для мысли", value: nil, table: nil) == "A Place to Think")
        #expect(english.localizedString(forKey: "Модели и настройки", value: nil, table: nil) == "Models and Settings")
        #expect(russian.localizedString(forKey: "Место для мысли", value: nil, table: nil) == "Место для мысли")
        #expect(DocumentKind.notebook.title == "Notebook")
        #expect(PaperPattern.grid.title == "Grid")
        #expect(ModelBrowser.Mode.recommended.title == "For This Device")
    }
}

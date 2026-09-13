import Testing
@testable import StudyIntelligence
@testable import Yohaku

@MainActor struct NetworkSettingsStateTests {
    @Test func repeatedViewUpdatesPreserveEnteredTokenAndCatalog() {
        let state = NetworkModelSettingsState()
        var config = ModelConfiguration()
        config.provider = .sloppy; config.sloppyEndpoint = "https://first.test"
        state.configure(config)
        state.key = "unsaved-token"
        state.status = "Каталог загружен"
        state.models = [.init(id: "mock:test-model", title: "Test")]
        state.configure(config)
        #expect(state.key == "unsaved-token")
        #expect(state.models.count == 1)
        #expect(state.status == "Каталог загружен")
        config.sloppyEndpoint = "https://second.test"
        state.configure(config)
        #expect(state.key.isEmpty)
        #expect(state.models.isEmpty)
        state.cancel()
    }
}

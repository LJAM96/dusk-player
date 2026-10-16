import Foundation
import Testing
@testable import Dusk

@Suite("Home preferences")
struct HomePreferencesTests {
    @Test("Personalized shelves defaults on and persists both switch positions")
    @MainActor func personalizedShelvesPersistence() {
        let defaults = UserDefaults.standard
        let key = "personalizedShelvesEnabled"
        let previous = defaults.object(forKey: key)
        defer {
            if let previous { defaults.set(previous, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }

        defaults.removeObject(forKey: key)
        let preferences = UserPreferences()
        #expect(preferences.personalizedShelvesEnabled)
        preferences.personalizedShelvesEnabled = false
        #expect(!UserPreferences().personalizedShelvesEnabled)
        preferences.personalizedShelvesEnabled = true
        #expect(UserPreferences().personalizedShelvesEnabled)
    }
}

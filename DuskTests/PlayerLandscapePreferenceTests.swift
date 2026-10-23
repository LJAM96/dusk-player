import Foundation
import Testing
@testable import Dusk

@Suite("Player landscape preference")
struct PlayerLandscapePreferenceTests {
    @Test("Always play in landscape defaults on and persists both switch positions")
    @MainActor func alwaysPlayInLandscapeDefaultsOn() {
        let defaults = UserDefaults.standard
        let key = "alwaysPlayInLandscape"
        let previous = defaults.object(forKey: key)
        defer {
            if let previous { defaults.set(previous, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }

        defaults.removeObject(forKey: key)
        let preferences = UserPreferences()
        #expect(preferences.alwaysPlayInLandscape)
        preferences.alwaysPlayInLandscape = false
        #expect(!UserPreferences().alwaysPlayInLandscape)
        preferences.alwaysPlayInLandscape = true
        #expect(UserPreferences().alwaysPlayInLandscape)
    }
}

import Foundation

final class SettingsStore {
    private let defaults = UserDefaults.standard
    
    var threshold: Double {
        get { defaults.double(forKey: "knockThreshold") == 0 ? 0.10 : defaults.double(forKey: "knockThreshold") }
        set { defaults.set(newValue, forKey: "knockThreshold") }
    }
    
    init() {
        print("[SettingsStore] Initialized")
    }
}

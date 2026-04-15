import Foundation

final class USBWatcher {
    var onEvent: ((String) -> Void)?
    
    init() {
        print("[USBWatcher] Initialized")
    }
}

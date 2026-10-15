import Foundation
import Synchronization

/// Incognito mode: playback doesn't touch the library (no "Continue watching", no sync) and network
/// clients use ephemeral sessions, so searches, results and posters never reach a disk cache.
///
/// Mirrors `AppSettings.incognito` (kept in step by `ProfileStore`) so actors can read it from any thread.
enum Incognito {
    private static let state = Mutex(false)

    static var isOn: Bool {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }
}

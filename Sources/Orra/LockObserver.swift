import Foundation

/// Listens for the system's lock / unlock broadcasts.
final class LockObserver {
    private var tokens: [NSObjectProtocol] = []

    init(onLock: @escaping () -> Void, onUnlock: @escaping () -> Void) {
        let c = DistributedNotificationCenter.default()
        tokens.append(c.addObserver(forName: .init("com.apple.screenIsLocked"),
                                    object: nil, queue: .main) { _ in onLock() })
        tokens.append(c.addObserver(forName: .init("com.apple.screenIsUnlocked"),
                                    object: nil, queue: .main) { _ in onUnlock() })
    }

    deinit { tokens.forEach { DistributedNotificationCenter.default().removeObserver($0) } }
}

import Foundation

public actor IPCStartupGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let onWaiterBlocked: (@Sendable () async -> Void)?

    public init(onWaiterBlocked: (@Sendable () async -> Void)? = nil) {
        self.onWaiterBlocked = onWaiterBlocked
    }

    public func waitUntilReady() async {
        if isOpen {
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
            if let onWaiterBlocked {
                Task {
                    await onWaiterBlocked()
                }
            }
        }
    }

    public func open() {
        guard !isOpen else {
            return
        }
        isOpen = true
        let waiters = waiters
        self.waiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

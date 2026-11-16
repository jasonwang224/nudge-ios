import Foundation

enum NotificationDelegateCompletion {
    // UIKit may update its snapshot when this callback runs. Avoid the async
    // Objective-C delegate bridge, which can finish on a background executor.
    // Await durable action handling before telling iOS the response is finished.
    nonisolated static func finish<Value>(
        after operation: @escaping @MainActor () async -> Value,
        completion: @escaping (Value) -> Void
    ) {
        Task { @MainActor in
            let value = await operation()
            completion(value)
        }
    }
}

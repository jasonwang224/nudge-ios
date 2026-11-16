import Foundation

// Pump the real main run loop while invoking the production callback adapter
// from a background queue, matching UserNotifications delegate delivery.
final class Results: @unchecked Sendable {
    private let lock = NSLock()
    private var operations = Set<Int>()
    private var callbacks = Set<Int>()
    func didHandle(_ id: Int) {
        precondition(Thread.isMainThread)
        lock.lock(); defer { lock.unlock() }
        precondition(operations.insert(id).inserted)
    }
    func didFinish(_ id: Int) {
        precondition(Thread.isMainThread, "iOS completion must run on main")
        lock.lock(); defer { lock.unlock() }
        precondition(operations.contains(id), "Completion ran before action finished")
        precondition(callbacks.insert(id).inserted, "Completion ran twice")
    }
    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return callbacks.count
    }
}
let results = Results()
let total = 200
for id in 0..<total {
    DispatchQueue.global().async {
        precondition(!Thread.isMainThread)
        if id.isMultiple(of: 2) {
            NotificationDelegateCompletion.finish(after: {
                precondition(Thread.isMainThread)
                // Exercise suspension, like durable Done/Snooze scheduling.
                try? await Task.sleep(nanoseconds: 1_000_000)
                results.didHandle(id)
                return id
            }, completion: { value in
                precondition(value == id)
                results.didFinish(id)
            })
        } else {
            NotificationDelegateCompletion.finish(after: {
                // Exercise the immediate/early-return (invalid payload) path.
                results.didHandle(id)
                return
            }, completion: { _ in results.didFinish(id) })
        }
    }
}
let deadline = Date().addingTimeInterval(10)
while results.count < total && Date() < deadline {
    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
}
precondition(results.count == total, "Lost notification completion")
RunLoop.main.run(until: Date().addingTimeInterval(0.1))
precondition(results.count == total)
print("PASS: 200 background callbacks finish exactly once on main, after handling, including suspended and early-return paths")

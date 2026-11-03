import Foundation

/// Lock-protected slot array for concurrent result collection.
final class ResultBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var slots: [T?]
    init(count: Int) { slots = Array(repeating: nil, count: count) }
    func set(_ i: Int, _ v: T) { lock.lock(); slots[i] = v; lock.unlock() }
    var values: [T?] { lock.lock(); defer { lock.unlock() }; return slots }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func take(upTo limit: Int) -> Int? {
        lock.lock(); defer { lock.unlock() }
        guard n < limit else { return nil }
        n += 1
        return n - 1
    }
}

/// Wraps a non-Sendable value (AX elements are thread-safe CF objects) for crossing into worker closures.
struct Unchecked<T>: @unchecked Sendable { var value: T }

/// Maps `input` with a small worker pool. With a `deadline`, workers stop taking new items once it passes and the
/// call returns at the deadline even if some items are still in flight; unfinished items come back as nil
/// (their workers finish in the background and their results are discarded).
func boundedParallelMap<T: Sendable, R: Sendable>(
    _ input: [T], workers: Int, deadline: Date? = nil, _ f: @escaping @Sendable (T) -> R
) -> [R?] {
    guard !input.isEmpty else { return [] }
    let box = ResultBox<R>(count: input.count)
    let next = Counter()
    let group = DispatchGroup()
    for _ in 0..<min(workers, input.count) {
        DispatchQueue.global(qos: .userInitiated).async(group: group) {
            while let i = next.take(upTo: input.count) {
                if let d = deadline, Date() >= d { return }
                box.set(i, f(input[i]))
            }
        }
    }
    if let d = deadline {
        _ = group.wait(timeout: .now() + max(0, d.timeIntervalSinceNow))
    } else {
        group.wait()
    }
    return box.values
}

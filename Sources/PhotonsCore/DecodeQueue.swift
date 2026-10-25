import Foundation

/// One serial queue of its own for **developments**, so a camera move is never queued behind
/// ImageIO.
///
/// The bug this type closes (Q29): the loupe developed *and* rendered on one serial queue, so a
/// 60 MP development (~800–1400 ms measured) stood in front of every pan. Nothing errored — the
/// picture simply froze for the length of the development, and then a queue of stale frames
/// drained. A freeze with no error in it is the kind of defect a pixel assertion can never catch,
/// which is why the pan budget is measured here rather than inferred.
///
/// The policy a caller gets:
///
///   · **One job per `(identity, scale)`.** A development already queued or running is *joined*, not
///     repeated: twenty pans during one full development cost one decode, not twenty. That is what
///     keeps `fit → 1:1 → fit → 1:1` at two developments even when every one of those frames asks.
///   · **Generations.** Every request carries the caller's generation and every delivery reports it
///     back, so a caller can drop a buffer that arrived for a photo or a camera position it has
///     already left. The queue does not decide staleness; it reports honestly, and the caller — the
///     only thing that knows what is on screen — decides.
///   · **Cancellation.** `cancel(identity:)` forgets the queued work *and* the delivery of work
///     already running: a photo the user left must not paint over the one they are looking at.
///     ImageIO cannot be aborted mid-flight, so an in-flight development finishes and is dropped;
///     work that has not started is skipped entirely.
///
/// Everything a job needs is captured in its closure: the queue holds no decoder, no URL, no view
/// state. `RAWDecoder` instances are per job (as they always were — one `CIContext` each), so the
/// decode queue shares nothing with the render queue, including the GPU command queue.
public final class DecodeQueue {

    /// The unit a queued job is unique for. `scale` is `DecodeOptions.scale`, i.e. the rung.
    public struct Key: Hashable, Sendable {
        public let identity: String
        public let scale: Float

        public init(identity: String, scale: Float) {
            self.identity = identity
            self.scale = scale
        }
    }

    /// What became of a request: a new job, or a join of one already on its way.
    public enum Outcome: Sendable {
        case started
        case coalesced
    }

    public typealias Work = () throws -> DecodeRung
    /// `(result, generation)` — the generation the *request* named, so a caller can compare it with
    /// what it is showing now.
    public typealias Completion = (Result<DecodeRung, Error>, Int) -> Void

    private let queue: DispatchQueue
    private let lock = NSLock()

    /// Every job that is queued or running, by key, with the completions waiting on it
    /// (generation → callback). A key is removed exactly once — by the job itself, at hand-off — so
    /// "one development per rung" is a property of this dictionary, not of the caller's discipline.
    private var waiters: [Key: [Int: Completion]] = [:]

    // Counters. Not part of any policy: they exist so a test can assert "one decode, not twenty"
    // and "the delivery was dropped" instead of inferring it from a wall clock.
    private var createdJobs = 0
    private var executedDecodes = 0
    private var coalescedRequests = 0
    private var deliveredResults = 0
    private var droppedDeliveries = 0

    /// - Parameter label: the queue's label, so Instruments and a crash report say which one.
    ///   Defaults to the loupe's own name.
    public init(label: String = "photons.decode") {
        queue = DispatchQueue(label: label, qos: .userInitiated)
    }

    // MARK: - counters

    /// Developments this queue actually ran — not the jobs it created: a job of a cancelled photo is
    /// skipped, and a coalesced request creates no job at all.
    public var decodes: Int { locked { executedDecodes } }
    /// Jobs created (a coalesced request joins one instead).
    public var jobs: Int { locked { createdJobs } }
    /// Requests that joined a development already on its way.
    public var coalesced: Int { locked { coalescedRequests } }
    /// Completions handed to a caller.
    public var deliveries: Int { locked { deliveredResults } }
    /// Results that were dropped because the caller cancelled the photo first.
    public var drops: Int { locked { droppedDeliveries } }

    public var pendingKeys: [Key] { locked { Array(waiters.keys).sorted { $0.identity < $1.identity } } }
    public var isIdle: Bool { locked { waiters.isEmpty } }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    // MARK: - requests

    /// Ask for one rung. Returns immediately; `completion` runs on the decode queue.
    ///
    /// A request for a key that is already queued or running does **not** start a second development:
    /// its completion is added to that job, and it is called when the one buffer exists. Two pans
    /// asking for the same missing rung during the same development therefore cost one decode and two
    /// notifications — and the caller's "is it already resident?" test is what makes the second one a
    /// no-op instead of a second repaint.
    @discardableResult
    public func request(identity: String, scale: Float, generation: Int,
                        work: @escaping Work, completion: @escaping Completion) -> Outcome {
        let key = Key(identity: identity, scale: scale)
        lock.lock()
        if var existing = waiters[key] {
            existing[generation] = completion
            waiters[key] = existing
            coalescedRequests += 1
            lock.unlock()
            return .coalesced
        }
        waiters[key] = [generation: completion]
        createdJobs += 1
        lock.unlock()

        queue.async { [weak self] in self?.run(key: key, work: work) }
        return .started
    }

    /// Forget every pending development of one photo, and refuse to deliver one already running.
    ///
    /// This is what "the user left that photo" means: the buffer is not wanted, presenting it would
    /// paint the wrong picture, and finishing the *next* queued development of that photo would
    /// steal ImageIO from the one they are looking at now.
    public func cancel(identity: String) {
        lock.lock()
        let keys = waiters.keys.filter { $0.identity == identity }
        for key in keys {
            let waiting = waiters.removeValue(forKey: key)?.count ?? 0
            droppedDeliveries += waiting
        }
        lock.unlock()
    }

    /// Block until every queued development has finished. Tests and the bench only: the loupe never
    /// waits for a development (that is the whole point of this type).
    @discardableResult
    public func waitUntilIdle(timeout: TimeInterval = 60) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        queue.async { semaphore.signal() }      // serial: everything queued before this has run
        return semaphore.wait(timeout: .now() + timeout) == .success
    }

    // MARK: - the job

    private func run(key: Key, work: Work) {
        // Cancelled while queued: never open the file. The waiters were dropped by `cancel`, and
        // nobody would receive these pixels.
        guard locked({ waiters[key] != nil }) else { return }

        locked { executedDecodes += 1 }
        var result: Result<DecodeRung, Error>
        do { result = .success(try work()) } catch { result = .failure(error) }

        lock.lock()
        let callbacks = waiters.removeValue(forKey: key) ?? [:]
        deliveredResults += callbacks.count
        lock.unlock()

        // A cancel that landed *during* the development removed the waiters; the pixels are already
        // paid for, but they still must not reach a canvas that has moved on.
        for generation in callbacks.keys.sorted() {
            guard let callback = callbacks[generation] else { continue }
            callback(result, generation)
        }
    }
}

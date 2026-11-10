import Foundation

// MARK: - priority
//
// Priority, high to low: the loupe's current frame, the visible grid/filmstrip, one off-screen row,
// re-renders of edited visible items, then import backfill of `t256` / offline recovery. Prefetch is
// the visible window ± 1 row and only resumes 150 ms after scrolling stops; cancellation bumps a
// `generation` and drops stale jobs, but an in-flight decode cannot be interrupted — it runs to
// completion and is written, its result is simply not delivered.
//
// The service is deliberately *pipeline-agnostic*: it owns the queue, the single-flight map, the
// cancellation tokens and the counters, and it asks an injected `ThumbnailProducer` for JPEG bytes.
// Two producers exist in the app (`preview` = ImageIO on the embedded camera JPEG, `graph` =
// `RenderGraph.render` at a scale) and both write into the same `ThumbnailCache`, exactly because
// the key already carries `pipeline` (§0: one renderer, two sources of pixels — D12).

/// Where a request sits in the queue. Higher raw value wins; equal priorities are FIFO by sequence.
public enum ThumbPriority: Int, Sendable, Comparable, CaseIterable {
    /// §4 ⑤ — import backfill of `t256`, offline-root recovery. Cheapest claim on the machine.
    case background = 0
    /// §4 ③ — one row above/below the viewport, released 150 ms after scrolling stops.
    case prefetch = 1
    /// §4 ①② — the loupe frame and the visible grid/filmstrip.
    case onScreen = 2

    public static func < (lhs: ThumbPriority, rhs: ThumbPriority) -> Bool { lhs.rawValue < rhs.rawValue }

    public var name: String {
        switch self {
        case .background: return "background"
        case .prefetch: return "prefetch"
        case .onScreen: return "onScreen"
        }
    }
}

/// One thumbnail the caller wants, and where its source file lives.
///
/// The source URL is part of the request rather than of the key on purpose: the key is
/// content-addressed (§3), so a moved file and a duplicate copy share one cache entry while each
/// request still knows which file to decode.
public struct ThumbRequestSpec: Sendable, Hashable {
    public let key: ThumbKey
    public let source: URL
    /// 326 — a request whose pixels nobody is waiting for *right now*: the loupe's HD warm (311).
    ///
    /// The distinction is what the pause is for (§4 `isInteracting`). A cell's request is refused
    /// while the user drags, because the frame being composited is the one that matters and a new
    /// decode would compete with it. A warm is the opposite: it exists precisely so that the frame
    /// *after* the interaction has something to show, so refusing it means nobody will ever ask
    /// again (nobody else asks for that key in the loupe) and the preview stays on the document
    /// before the last edit. A warm is therefore **enqueued but not started** while paused: the
    /// queue entry waits, `pump()` on resume starts it, and no producer runs during the interaction.
    public let isBackgroundWarm: Bool

    public init(key: ThumbKey, source: URL, isBackgroundWarm: Bool = false) {
        self.key = key
        self.source = source
        self.isBackgroundWarm = isBackgroundWarm
    }
}

/// What actually happened to a request.
public enum ThumbOrigin: String, Sendable {
    /// Served from disk. No producer call.
    case hit
    /// The producer ran and the bytes were written to the cache.
    case generated
    /// Cancelled or dropped before it could be delivered (§5). Nothing was written.
    case cancelled
    /// The producer threw (no embedded preview, tier above the preview ceiling, no Metal, …).
    case failed
}

/// A delivered (or recorded) outcome.
///
/// `data` is only populated for completion callbacks. `result(for:)` hands back the *summary*
/// (`data == nil`) so a 1000-key batch does not pin 120 MB of JPEG bytes in a dictionary — the
/// bytes are on disk at this point, which is the whole point of the cache.
public struct ThumbResult: Sendable {
    public let key: ThumbKey
    public let origin: ThumbOrigin
    public let data: Data?
    /// Provenance label from the producer ("embedded", "fallback", "graph", …). Reporting only.
    public let source: String?
    /// Long edge of the pixels the result was derived from (0 = the producer did not say). This is
    /// the number `禁止放大` is checked against (§1) without decoding the file a second time.
    public let sourceLongEdge: Int
    /// Enqueue → delivery. This is what a grid cell waits, so it includes queueing (§5).
    public let waitedMilliseconds: Double
    /// Producer-only time (0 for a hit). Compare with `waitedMilliseconds` to see queue cost.
    public let producedMilliseconds: Double
    public let error: String?

    public var pipeline: ThumbPipeline { key.pipeline }
    public var tier: ThumbTier { key.tier }
}

/// What a producer hands back: the JPEG plus the two facts a report needs to explain it.
public struct ThumbPayload: Sendable {
    public let data: Data
    public let source: String
    public let sourceLongEdge: Int

    public init(data: Data, source: String, sourceLongEdge: Int = 0) {
        self.data = data
        self.source = source
        self.sourceLongEdge = sourceLongEdge
    }
}

/// Turns one key into JPEG bytes. The service owns *when* and *how many at once*; the producer owns
/// *pixels*, and must be safe to call from several worker threads at once (the service allows
/// `maxConcurrency` of them, §4 "并发上限 3").
public protocol ThumbnailProducer: AnyObject {
    func produce(_ key: ThumbKey, source: URL) throws -> ThumbPayload
}

public enum ThumbServiceError: LocalizedError {
    case noProducer(ThumbKey)
    case producerReturnedEmpty(ThumbKey)

    public var errorDescription: String? {
        switch self {
        case .noProducer(let k): return "no producer installed for \(k.pipeline.rawValue) \(k.tier.rawValue)"
        case .producerReturnedEmpty(let k): return "producer returned 0 bytes for \(k.tier.rawValue)"
        }
    }
}

// MARK: - tickets

/// The cancellable handle `request` returns. Cancelling it unsubscribes this caller; when the last
/// subscriber of a key goes away the job itself is cancelled (dequeued, or suppressed if the
/// producer already started — the decode is uninterruptible, §5, but its bytes are discarded).
public final class ThumbTicket: @unchecked Sendable {
    public let key: ThumbKey
    public let priority: ThumbPriority
    public let id: Int64

    private weak var service: ThumbnailService?
    private let stateLock = NSLock()
    private var cancelled = false
    /// 326 — refused at admission while paused, but retained in the service's replay set. Not
    /// cancelled: the caller still gets its pixels, one interaction later.
    private var held = false

    init(key: ThumbKey, priority: ThumbPriority, id: Int64, service: ThumbnailService) {
        self.key = key
        self.priority = priority
        self.id = id
        self.service = service
    }

    public var isCancelled: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return cancelled
    }

    /// 326 — `true` between the refusal and the replay: the request is waiting for the interaction to
    /// end, not gone.
    public var isHeld: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return held && !cancelled
    }

    /// Idempotent. Safe from any thread.
    public func cancel() {
        service?.cancel([self])
    }

    func markCancelled() {
        stateLock.lock(); cancelled = true; held = false; stateLock.unlock()
    }

    func markHeld(_ value: Bool) {
        stateLock.lock(); held = value; stateLock.unlock()
    }

    func stillWanted() -> Bool { !isCancelled }
}

/// "The view went away" in one call: cancels a whole visible set at once (§5 generation cancel).
public func cancel(_ tickets: [ThumbTicket]) {
    for t in tickets { t.cancel() }
}

// MARK: - service

/// Priority queue + single-flight + cancellation + concurrency limit, in front of `ThumbnailCache`.
///
/// Invariants that matter (each is a unit test):
/// * **Single flight.** One job per `ThumbKey`; every later request joins it and receives the same
///   bytes. `stats.coalesced` counts the joins, so the log can prove it.
/// * **Concurrency ceiling.** At most `config.maxConcurrency` producers run at once, regardless of
///   queue depth. `stats.activePeak` is the observed maximum, not the configured one.
/// * **Priority.** Highest priority first, FIFO inside a priority (job sequence).
/// * **No main thread.** `request` only takes a lock, appends to an array and dispatches; every
///   cache read, producer call, disk write and completion callback happens on a worker queue.
/// * **Cancel means no write.** A cancelled job never produces bytes that reach the disk. An
///   in-flight decode still runs to completion (CIRAWFilter cannot be interrupted) but its bytes are
///   dropped — the stricter of §5's "写盘不浪费" and the acceptance rule "取消后不再写盘".
/// * **Every live subscriber reaches a terminal state.** A job is booked exactly once (`hit`,
///   `generated`, `cancelled`, `failed`); a subscriber that did not cancel itself always gets its
///   callback; and a producer that never returns is booked `failed` with a reason when
///   `Config.producerDeadline` expires. A request that arrives while a *condemned* job (every
///   earlier subscriber left) is still running **adopts** that job rather than joining one that has
///   already decided to call nobody back — that join was 007's "pending forever".
public final class ThumbnailService: @unchecked Sendable {

    public struct Config: Sendable {
        /// 2…3 in the app (LightCraft's value is 3, §4); tests use 1 to make ordering observable.
        public var maxConcurrency: Int
        /// Optional admission cap. 0 = unlimited: the queue is bounded by the visible window, and
        /// silently dropping work because a prefetch ran long would make hit rates unexplainable.
        public var queueDepthLimit: Int
        /// Nothing may sit in a producer forever: one wedged decode would hold a concurrency slot
        /// (and with it `maxConcurrency` cells) until the app quit. A job that exceeds this is
        /// booked `failed` with a reason and its bytes are dropped if they ever arrive. 0 disables.
        /// A normal render here is ~0.3 s; the deadline exists for "the filter never returns", not
        /// for slow machines.
        public var producerDeadline: TimeInterval

        /// 308 — the *service* default follows the machine too, so a caller that builds a service
        /// without a config cannot silently reinstate the old 3. The app always goes through
        /// `ThumbnailProvider.defaultConcurrency`; this is the floor under it.
        public init(maxConcurrency: Int = max(2, ProcessInfo.processInfo.activeProcessorCount - 1),
                    queueDepthLimit: Int = 0,
                    producerDeadline: TimeInterval = 30) {
            self.maxConcurrency = max(1, maxConcurrency)
            self.queueDepthLimit = max(0, queueDepthLimit)
            self.producerDeadline = max(0, producerDeadline)
        }
    }

    /// Self-consistent counters. Everything the report prints comes from here — no estimates.
    public struct Stats: Sendable {
        /// Subscriptions accepted. Requests refused before becoming a job (`isPaused`, stale
        /// generation, `queueDepthLimit`) are *not* counted here — they live in the three reject
        /// counters below, which keeps the headline invariant honest:
        ///
        ///     requests == coalesced + hits + missGenerated + missCancelled + missFailed
        ///
        /// (each request is either a join, or the first subscriber of a job that ends in exactly
        /// one of the four outcome buckets).
        public var requests = 0
        /// Jobs served from disk without a producer call. Job-level, not subscription-level.
        public var hits = 0
        /// Jobs the producer rendered and the cache wrote. Job-level.
        public var missGenerated = 0
        /// Jobs (or queued subscriptions of a dead job) cancelled before any bytes were written.
        public var missCancelled = 0
        public var missFailed = 0
        /// Requests that joined a job someone else had already created.
        public var coalesced = 0
        /// Cache writes performed by this service.
        public var writes = 0
        /// P1f — **graph** thumbnails generated *because the directory was upgraded*, i.e. written
        /// under a different `StageAlgorithmVersion` set than the one this process runs.
        ///
        /// It is 0 in every process that found the cache already stamped with the current arithmetic,
        /// which is what makes it a measurement instead of a coincidence: after one upgrade the number
        /// equals the count of `graph` thumbnails on disk (every one of them contains S2, so every one
        /// is rebuilt), and the next start reports 0 while serving the same pixels as hits.
        public var rebuilt = 0
        /// Jobs cancelled after the producer had started (bytes dropped).
        public var cancelledInFlight = 0
        /// Requests refused because `isPaused` (§4 `isInteracting`).
        ///
        /// 326 — a refusal is also *retained*: the latest refused spec per key is replayed when the
        /// interaction ends (`resumeHeld`), so the visible cell whose request landed mid-drag is
        /// served without waiting for the next `configure`. This counter therefore counts "not
        /// admitted at that moment", which is what the pause means; the replay is a separate
        /// admission (and a separate `requests`).
        public var rejectedWhilePaused = 0
        /// 326 — warms enqueued **instead of** refused while paused. They are ordinary queue entries:
        /// nothing runs until `isPaused` goes false, and `pump()` then starts them. Zero producer runs
        /// happen during the interaction, which is the whole point of the pause.
        public var queuedWhilePaused = 0
        /// 326 — refusals that were re-admitted on resume (the visible cells' second chance).
        public var replayedAfterPause = 0
        /// Requests dropped because their generation was stale at enqueue time.
        public var droppedStaleGeneration = 0
        /// Requests dropped by `Config.queueDepthLimit`.
        public var rejectedByDepth = 0
        public var queued = 0
        public var queuedPeak = 0
        public var active = 0
        public var activePeak = 0
        public var maxConcurrency = 0
        public var delivered = 0
        public var waitSamples = 0
        public var totalWaitMilliseconds = 0.0
        public var maxWaitMilliseconds = 0.0
        /// 311 — the cache write (temp file + rename + prune) of the last job, and its average.
        /// The third leg of a warm, next to the producer's render and encode.
        public var lastWriteMilliseconds = 0.0
        public var totalWriteMilliseconds = 0.0
        public var writeSamples = 0
        public var averageWriteMilliseconds: Double {
            writeSamples == 0 ? 0 : totalWriteMilliseconds / Double(writeSamples)
        }

        public var lookups: Int { hits + missGenerated + missCancelled + missFailed }
        public var hitRatio: Double { lookups == 0 ? 0 : Double(hits) / Double(lookups) }
        public var averageWaitMilliseconds: Double {
            waitSamples == 0 ? 0 : totalWaitMilliseconds / Double(waitSamples)
        }
    }

    public let cache: ThumbnailCache
    public let config: Config
    public private(set) var producer: ThumbnailProducer?

    private let lock = NSCondition()
    private let workers = DispatchQueue(label: "photons.thumbs.workers", qos: .userInitiated,
                                        attributes: .concurrent)

    private final class Subscription {
        let id: Int64
        var cancelled = false
        /// The view this subscriber belonged to no longer exists (§5 generation bump). It asked to be
        /// called back, but its pixels are worthless now — so it gets no callback, while any later
        /// subscriber of the same still-running job does.
        var stale = false
        let completion: ((ThumbResult) -> Void)?
        init(id: Int64, completion: ((ThumbResult) -> Void)?) {
            self.id = id
            self.completion = completion
        }
    }

    private final class Job {
        let key: ThumbKey
        let source: URL
        let sequence: Int64
        let generation: Int
        var priority: ThumbPriority
        var subscribers: [Subscription] = []
        var started = false
        /// Hard cancel: drop the bytes the producer is making. Cleared again when a later request
        /// adopts the job (`requestBatch`), because then somebody *does* want those bytes.
        var suppressWrite = false
        /// Set by `finish` (and by the producer deadline): exactly one terminal state per job.
        var finished = false
        var enqueuedAt = DispatchTime.now()
        var producerMilliseconds = 0.0

        init(key: ThumbKey, source: URL, sequence: Int64, generation: Int, priority: ThumbPriority) {
            self.key = key
            self.source = source
            self.sequence = sequence
            self.generation = generation
            self.priority = priority
        }
    }

    private var pending: [Job] = []
    /// Pending *and* in-flight jobs, by key: this dictionary is the single-flight map.
    private var jobs: [ThumbKey: Job] = [:]

    /// 326 — a request the pause refused, kept so it can be replayed the moment the interaction ends.
    ///
    /// One entry per key (the latest ask wins: an older closure for the same key would draw the same
    /// pixels, and a cell that reconfigured has already replaced its own request).
    private final class Held {
        let spec: ThumbRequestSpec
        let priority: ThumbPriority
        let generation: Int
        let completion: ((ThumbResult) -> Void)?
        let ticket: ThumbTicket

        init(spec: ThumbRequestSpec, priority: ThumbPriority, generation: Int,
             completion: ((ThumbResult) -> Void)?, ticket: ThumbTicket) {
            self.spec = spec
            self.priority = priority
            self.generation = generation
            self.completion = completion
            self.ticket = ticket
        }
    }

    private var held: [ThumbKey: Held] = [:]
    private var heldOrder: [ThumbKey] = []
    /// Ceiling for the replay set: three panes of visible cells is tens of keys, and a cap is what
    /// keeps a long drag from turning the set into a second queue.
    static let heldLimit = 64
    /// Test-only witness of admission order (see `recordsAdmissionOrder`). Never used by the app.
    private var recordsAdmissions = false
    private var admissions: [ThumbKey] = []
    private var counters = Stats()
    private var sequence: Int64 = 0
    private var subscriptionID: Int64 = 0
    private var activeCount = 0
    private var currentGeneration = 0
    private var paused = false
    private var summaries: [Int64: ThumbResult] = [:]

    public init(cache: ThumbnailCache, config: Config = Config(),
                producer: ThumbnailProducer? = nil) {
        self.cache = cache
        self.config = config
        self.producer = producer
        lock.lock()
        counters.maxConcurrency = config.maxConcurrency
        lock.unlock()
    }

    // MARK: knobs

    /// §4: no thumbnail job is posted while the user is dragging or zooming.
    ///
    /// 326 — what a pause does with a request depends on whether anybody is waiting for it:
    /// * `.isBackgroundWarm` (the loupe's 311 warm) is **queued**, not refused: its whole purpose is
    ///   the frame after the interaction, and in the loupe nothing else ever asks for that key;
    /// * every other request is refused **and retained** — `resumeHeld` re-admits it the moment the
    ///   interaction ends, so a visible cell whose ask landed mid-drag is served without waiting for
    ///   the next `configure` (the user-visible half of this bug: the small previews stalled too).
    /// `rejectedWhilePaused` still moves for the second kind, which is how the report proves the
    /// pause was not simply switched off.
    public var isPaused: Bool {
        get { lock.lock(); defer { lock.unlock() }; return paused }
        set {
            lock.lock()
            paused = newValue
            let resume = !newValue
            lock.unlock()
            if resume { resumeHeld() }
        }
    }

    public var generation: Int {
        lock.lock(); defer { lock.unlock() }
        return currentGeneration
    }

    public var pendingCount: Int {
        lock.lock(); defer { lock.unlock() }
        return pending.count
    }

    /// §5: every visible-set change increments the generation. Pending jobs from older generations
    /// are dropped; in-flight ones are allowed to finish **and write** (the work is already paid for,
    /// §5 "让它跑完并写盘"), but their results are not delivered to a view that no longer exists.
    /// Keys in `keeping` (the new visible set) survive the sweep — that is the "same cells, new
    /// generation" case a scroll that lands on the same row produces.
    ///
    /// "Not delivered" is per **subscriber** (`Subscription.stale`), not per job: a later request for
    /// the same still-running key is a different view, and it does want its callback.
    @discardableResult
    public func beginGeneration(keeping keys: Set<ThumbKey> = []) -> Int {
        lock.lock()
        currentGeneration += 1
        let gen = currentGeneration
        var dropped = 0
        pending.removeAll { job in
            guard job.generation < gen, !keys.contains(job.key) else { return false }
            job.subscribers.forEach { $0.cancelled = true }
            jobs.removeValue(forKey: job.key)
            dropped += 1
            return true
        }
        for job in jobs.values where job.started && job.generation < gen && !keys.contains(job.key) {
            job.subscribers.forEach { $0.stale = true }
        }
        counters.queued = pending.count
        counters.missCancelled += dropped
        lock.broadcast()
        lock.unlock()
        return gen
    }

    // MARK: request

    /// Enqueue one request. Never blocks on I/O, never touches the main thread.
    ///
    /// Passing `completion` gets you the bytes on a worker thread; passing `nil` lets you read the
    /// summary later with `result(for:)`, which is what a batch CLI wants.
    @discardableResult
    public func request(_ spec: ThumbRequestSpec, priority: ThumbPriority = .onScreen,
                        generation: Int? = nil,
                        completion: ((ThumbResult) -> Void)? = nil) -> ThumbTicket {
        requestBatch([spec], priority: priority, generation: generation, completion: completion)[0]
    }

    @discardableResult
    public func request(_ specs: [ThumbRequestSpec], priority: ThumbPriority = .onScreen,
                        generation: Int? = nil,
                        completion: ((ThumbResult) -> Void)? = nil) -> [ThumbTicket] {
        requestBatch(specs, priority: priority, generation: generation, completion: completion)
    }

    private func requestBatch(_ specs: [ThumbRequestSpec], priority: ThumbPriority,
                              generation: Int?, completion: ((ThumbResult) -> Void)?) -> [ThumbTicket] {
        var tickets: [ThumbTicket] = []
        tickets.reserveCapacity(specs.count)
        var toDispatch: [Job] = []

        lock.lock()
        let gen = generation ?? currentGeneration
        for spec in specs {
            subscriptionID += 1
            let id = subscriptionID
            let ticket = ThumbTicket(key: spec.key, priority: priority, id: id, service: self)
            tickets.append(ticket)

            if paused && !spec.isBackgroundWarm {
                // §4 `isInteracting`: not admitted while the frame is being composited — but kept
                // (326), so the visible cell is served when the interaction ends instead of waiting
                // for its next `configure` (which, in the loupe, never comes).
                counters.rejectedWhilePaused += 1
                holdLocked(spec, priority: priority, generation: gen, completion: completion,
                           ticket: ticket)
                continue
            }
            if gen < currentGeneration {
                // Stale view: refused before it becomes a job, so it is not an outcome bucket.
                counters.droppedStaleGeneration += 1
                ticket.markCancelled()
                continue
            }
            // 326 — a warm that arrives mid-interaction is queued, not started: `pump()` below is
            // gated on `!paused`, and the setter's `resumeHeld()` pumps when the drag ends.
            if paused { counters.queuedWhilePaused += 1 }
            if let job = admitLocked(spec, ticket: ticket, priority: priority, generation: gen,
                                     completion: completion) {
                toDispatch.append(job)
            }
        }
        let shouldDispatch = !toDispatch.isEmpty && !paused
        lock.unlock()

        if shouldDispatch { pump() }
        return tickets
    }

    /// The admission itself: single-flight join, depth cap, or a new job in `pending`.
    /// Returns the job when the caller should dispatch it (the service may be paused: then the entry
    /// simply waits for `pump()`).
    private func admitLocked(_ spec: ThumbRequestSpec, ticket: ThumbTicket, priority: ThumbPriority,
                             generation gen: Int,
                             completion: ((ThumbResult) -> Void)?) -> Job? {
        counters.requests += 1

        if let existing = jobs[spec.key] {
            // Single flight: same key, same bytes, one producer call.
            //
            // Adoption: if every earlier subscriber left while this decode was already running,
            // the job is *condemned* — it would finish, throw its bytes away and call nobody
            // back. Joining it as-is is how a request turns into "pending forever": the caller
            // waits for a callback that this job has already decided not to make (007 §root
            // cause). A request that wants the bytes now un-condemns the job instead, so the
            // render already paid for is written and delivered (§5 "让它跑完并写盘").
            if existing.suppressWrite {
                existing.suppressWrite = false
                counters.missCancelled = max(0, counters.missCancelled - 1)
                counters.cancelledInFlight = max(0, counters.cancelledInFlight - 1)
            }
            existing.subscribers.append(Subscription(id: ticket.id, completion: completion))
            if priority > existing.priority { existing.priority = priority }
            counters.coalesced += 1
            return nil
        }
        if config.queueDepthLimit > 0 && pending.count >= config.queueDepthLimit {
            counters.rejectedByDepth += 1
            ticket.markCancelled()
            return nil
        }

        sequence += 1
        let job = Job(key: spec.key, source: spec.source, sequence: sequence,
                      generation: gen, priority: priority)
        job.subscribers.append(Subscription(id: ticket.id, completion: completion))
        pending.append(job)
        jobs[spec.key] = job
        counters.queued = pending.count
        counters.queuedPeak = max(counters.queuedPeak, pending.count)
        return job
    }

    // MARK: held refusals (326)

    /// Refuse a request while paused **and keep it**: one entry per key, bounded by `heldLimit`.
    /// The lock is held. An older entry for the same key is dropped (its caller is cancelled: it is
    /// the same pixels and, for a cell, the reconfigure that asked again has replaced it).
    private func holdLocked(_ spec: ThumbRequestSpec, priority: ThumbPriority, generation: Int,
                            completion: ((ThumbResult) -> Void)?, ticket: ThumbTicket) {
        if let existing = held[spec.key] {
            existing.ticket.markCancelled()
            heldOrder.removeAll { $0 == spec.key }
        }
        ticket.markHeld(true)
        held[spec.key] = Held(spec: spec, priority: priority, generation: generation,
                             completion: completion, ticket: ticket)
        heldOrder.append(spec.key)
        while heldOrder.count > ThumbnailService.heldLimit {
            let evicted = heldOrder.removeFirst()
            // Evicted by the cap, not served: the caller must not wait for a callback that the set
            // no longer holds.
            held.removeValue(forKey: evicted)?.ticket.markCancelled()
        }
    }

    /// 326 — the interaction ended: give the refused requests their second chance **now**, so a
    /// visible cell does not have to wait for the next `configure` to notice the document moved.
    ///
    /// Policy, in this order:
    ///  * an owner that cancelled its ticket meanwhile (the cell was recycled) drops its entry;
    ///  * a request whose generation is stale is dropped, exactly as if it had arrived after the sweep;
    ///  * of several held **HD** keys for one photo, only the newest survives — the older ones are
    ///    documents the user already moved past, and replaying them would write the very files 311's
    ///    dedupe exists to prevent (a drag would land twenty);
    ///  * everything else is admitted through the same door as a live request, so single-flight,
    ///    priority, depth cap and the outcome counters behave identically.
    private func resumeHeld() {
        lock.lock()
        let entries = heldOrder.compactMap { held[$0] }
        held.removeAll()
        heldOrder.removeAll()

        // Newest held document per photo (the replay is for the document the user is looking at).
        var newestHDDigest: [String: String] = [:]
        for entry in entries where entry.spec.key.spec.isHDFamily {
            newestHDDigest[entry.spec.key.contentHash] = entry.spec.key.digest
        }

        for entry in entries {
            let key = entry.spec.key
            entry.ticket.markHeld(false)
            guard !entry.ticket.isCancelled else { continue }
            if key.spec.isHDFamily, newestHDDigest[key.contentHash] != key.digest {
                entry.ticket.markCancelled()
                continue
            }
            if entry.generation < currentGeneration {
                counters.droppedStaleGeneration += 1
                entry.ticket.markCancelled()
                continue
            }
            counters.replayedAfterPause += 1
            _ = admitLocked(entry.spec, ticket: entry.ticket, priority: entry.priority,
                            generation: entry.generation, completion: entry.completion)
        }
        lock.unlock()
        // A **warm** queued during the pause sits in `pending` and was never dispatched (that is what
        // the pause means), so the resume is what starts it — it may be the only entry there.
        pump()
    }

    /// 326 — how many refusals are waiting for the interaction to end. Read by the acceptance.
    public var heldCount: Int {
        lock.lock(); defer { lock.unlock() }
        return held.count
    }

    // MARK: cancel

    /// Cancel specific handles. If every subscriber of a key cancels, the job dies with them.
    public func cancel(_ tickets: [ThumbTicket]) {
        guard !tickets.isEmpty else { return }
        lock.lock()
        for ticket in tickets {
            ticket.markCancelled()
            // 326 — a held refusal has no job yet: the owner leaving is the only thing that can drop
            // it. Nothing is booked `missCancelled` (it was never admitted; `rejectedWhilePaused`
            // already counts it).
            if let entry = held[ticket.key], entry.ticket === ticket {
                held.removeValue(forKey: ticket.key)
                heldOrder.removeAll { $0 == ticket.key }
                continue
            }
            guard let job = jobs[ticket.key] else { continue }
            for sub in job.subscribers where sub.id == ticket.id { sub.cancelled = true }
            guard job.subscribers.allSatisfy({ $0.cancelled }) else { continue }
            guard !job.suppressWrite else { continue } // already dead: count the job once
            if job.started {
                // Uninterruptible decode: let it finish, throw the bytes away (§5 + "取消后不写盘").
                // A later request for the same key adopts the job and rescinds both flags.
                job.suppressWrite = true
                counters.cancelledInFlight += 1
                counters.missCancelled += 1
            } else {
                pending.removeAll { $0 === job }
                jobs.removeValue(forKey: job.key)
                counters.queued = pending.count
                counters.missCancelled += 1
            }
        }
        lock.broadcast()
        lock.unlock()
        // Completions are never called for a cancelled subscription: the caller already left.
    }

    /// Everything in flight or queued goes away (window closed, library switched).
    public func cancelAll() {
        lock.lock()
        for job in jobs.values where job.started {
            job.suppressWrite = true
            job.subscribers.forEach { $0.cancelled = true }
            counters.cancelledInFlight += 1
            counters.missCancelled += 1
        }
        for job in pending {
            job.subscribers.forEach { $0.cancelled = true }
            counters.missCancelled += 1
        }
        pending.removeAll()
        // 326 — refusals waiting for the interaction are also "the window went away".
        for entry in held.values { entry.ticket.markCancelled() }
        held.removeAll()
        heldOrder.removeAll()
        jobs = jobs.filter { $0.value.started }
        counters.queued = 0
        lock.broadcast()
        lock.unlock()
    }

    // MARK: scheduling

    /// Start as many jobs as the ceiling allows, highest priority (then oldest) first.
    private func pump() {
        var batch: [Job] = []
        lock.lock()
        while activeCount < config.maxConcurrency, let job = takeNextLocked() {
            job.started = true
            activeCount += 1
            counters.active = activeCount
            counters.activePeak = max(counters.activePeak, activeCount)
            batch.append(job)
            if recordsAdmissions { admissions.append(job.key) }
        }
        counters.active = activeCount
        lock.unlock()

        for job in batch {
            workers.async { [weak self] in self?.execute(job) }
        }
    }

    private func takeNextLocked() -> Job? {
        guard let best = pending.max(by: { a, b in
            a.priority == b.priority ? a.sequence > b.sequence : a.priority < b.priority
        }) else { return nil }
        pending.removeAll { $0 === best }
        counters.queued = pending.count
        return best
    }

    private func execute(_ job: Job) {
        // A job cancelled between `pump` and the worker actually starting must not touch the disk.
        lock.lock()
        let abortEarly = job.suppressWrite
        lock.unlock()
        if abortEarly {
            finish(job, origin: .cancelled, data: nil, payload: nil, error: nil)
            return
        }

        // Cache first: a duplicate request for an already-present key is a hit, not a render.
        if let data = cache.data(for: job.key) {
            finish(job, origin: .hit, data: data, payload: nil, error: nil)
            return
        }

        guard let producer else {
            finish(job, origin: .failed, data: nil, payload: nil,
                   error: ThumbServiceError.noProducer(job.key).localizedDescription)
            return
        }

        let t0 = DispatchTime.now()
        let payload: ThumbPayload
        if config.producerDeadline > 0 {
            // Safety net for a producer that never returns: without it, one wedged decode holds a
            // concurrency slot forever and the queue behind it never moves.
            let deadline = config.producerDeadline
            workers.asyncAfter(deadline: .now() + deadline) { [weak self] in
                self?.expire(job, after: deadline)
            }
        }
        do {
            payload = try producer.produce(job.key, source: job.source)
            guard !payload.data.isEmpty else { throw ThumbServiceError.producerReturnedEmpty(job.key) }
        } catch {
            finish(job, origin: .failed, data: nil, payload: nil, error: error.localizedDescription)
            return
        }
        let producedMs = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e6

        lock.lock()
        job.producerMilliseconds = producedMs
        let dropBytes = job.suppressWrite
        lock.unlock()

        if dropBytes {
            // Cancelled while the producer ran: bytes are discarded, never written. (Unless a later
            // request adopted the job before this line — then `dropBytes` is false and we store.)
            finish(job, origin: .cancelled, data: nil, payload: nil, error: nil)
            return
        }

        do {
            // 311 — the third leg of a warm's cost: the write itself (temp file + rename + the
            // one-file-per-photo prune). Measured, because "render+encode+write" is the number the
            // acceptance asks for and an estimate would hide the disk.
            let writeStart = DispatchTime.now()
            try cache.store(payload.data, for: job.key)
            let writeMs = Double(DispatchTime.now().uptimeNanoseconds
                                 - writeStart.uptimeNanoseconds) / 1e6
            lock.lock()
            counters.lastWriteMilliseconds = writeMs
            counters.totalWriteMilliseconds += writeMs
            counters.writeSamples += 1
            lock.unlock()
        } catch {
            finish(job, origin: .failed, data: nil, payload: nil, error: error.localizedDescription)
            return
        }
        // P1f: a `graph` thumbnail written by the process that migrated the directory is a rebuild.
        //
        // The definition is *process-scoped* on purpose, and the reason is arithmetic: the recipe
        // digest contains the algorithm version, so an upgraded key can never equal the key of the file
        // it replaces — the old file's name is not recoverable from the new one, and matching them is
        // impossible in principle. What is exact is the *deletion* (`versionSweep.removedGraphFiles`)
        // and this count of `graph` writes in the migrating process; when the grid is re-requested they
        // are the same number, which is the acceptance this counter exists for. A document imported
        // after the update in that same session would also be counted, and the sweep's own number is
        // the one to read in that case.
        let rebuilt = job.key.pipeline == .graph && cache.wasUpgradedByAlgorithmVersion
        lock.lock()
        counters.writes += 1
        if rebuilt { counters.rebuilt += 1 }
        lock.unlock()

        finish(job, origin: .generated, data: payload.data, payload: payload, error: nil)
    }

    /// The producer deadline fired. Book the job `failed` (with the reason) so its subscribers get a
    /// terminal state and its slot is returned; if the decode ever returns, `finish` is a no-op and
    /// its bytes are dropped (`suppressWrite`).
    private func expire(_ job: Job, after deadline: TimeInterval) {
        lock.lock()
        if job.finished {
            lock.unlock()
            return
        }
        job.suppressWrite = true
        lock.unlock()
        finish(job, origin: .failed, data: nil, payload: nil,
               error: "producer exceeded \(String(format: "%.0f", deadline)) s without returning")
    }

    /// Bookkeeping + delivery. Completions run outside the lock, on the worker thread.
    ///
    /// Exactly one terminal state per job: a second call (the producer finally returning after the
    /// deadline, say) returns immediately without touching the counters or the cache.
    private func finish(_ job: Job, origin: ThumbOrigin, data: Data?, payload: ThumbPayload?,
                        error: String?) {
        let waited = Double(DispatchTime.now().uptimeNanoseconds - job.enqueuedAt.uptimeNanoseconds) / 1e6

        lock.lock()
        guard !job.finished else { lock.unlock(); return }
        job.finished = true
        activeCount = max(0, activeCount - 1)
        counters.active = activeCount
        if jobs[job.key] === job { jobs.removeValue(forKey: job.key) }
        counters.queued = pending.count

        switch origin {
        case .hit: counters.hits += 1
        case .generated: counters.missGenerated += 1
        case .cancelled: break // already counted at cancel time
        case .failed: counters.missFailed += 1
        }

        // A subscriber that asked to be called back gets called back — always. `cancelled` means its
        // owner left (it already dropped the token); `stale` means its generation is gone (§5).
        let subscribers = job.subscribers
        lock.broadcast() // waitUntilIdle sees this job leave the queue
        lock.unlock()

        if let error, origin == .failed {
            // "失败必须有原因": the counter alone cannot tell a report *why* a cell stayed empty.
            let line = "photons: thumbnail \(job.key.tier.rawValue) \(job.key.digest.prefix(8)) "
                + "failed — \(error)\n"
            FileHandle.standardError.write(Data(line.utf8))
        }

        for sub in subscribers where !sub.cancelled && !sub.stale {
            let result = ThumbResult(key: job.key, origin: origin, data: data,
                                     source: payload?.source,
                                     sourceLongEdge: payload?.sourceLongEdge ?? 0,
                                     waitedMilliseconds: waited,
                                     producedMilliseconds: job.producerMilliseconds,
                                     error: error)
            lock.lock()
            counters.delivered += 1
            counters.waitSamples += 1
            counters.totalWaitMilliseconds += waited
            counters.maxWaitMilliseconds = max(counters.maxWaitMilliseconds, waited)
            if sub.completion == nil {
                // Summary only: the bytes are on disk, and pinning 1000 payloads in a
                // dictionary would cost more than the batch it describes.
                summaries[sub.id] = ThumbResult(key: result.key, origin: result.origin, data: nil,
                                                source: result.source,
                                                sourceLongEdge: result.sourceLongEdge,
                                                waitedMilliseconds: result.waitedMilliseconds,
                                                producedMilliseconds: result.producedMilliseconds,
                                                error: result.error)
            }
            lock.unlock()
            sub.completion?(result)
        }
        lock.broadcast() // waitUntilIdle
        pump()
    }

    // MARK: observation

    /// Block until the queue is empty and nothing is running. The CLI and the perf harness need
    /// this; the app never calls it (it is driven by callbacks).
    @discardableResult
    public func waitUntilIdle(timeout: TimeInterval = 120) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        lock.lock()
        while !(pending.isEmpty && activeCount == 0) {
            if !lock.wait(until: deadline) { lock.unlock(); return false }
        }
        lock.unlock()
        return true
    }

    public func stats() -> Stats {
        lock.lock(); defer { lock.unlock() }
        return counters
    }

    // MARK: test-only observation

    /// Witness of the **admission order**: while this is on, `pump()` appends the key of every job it
    /// hands a worker slot to, inside the same lock that chose it. The array is therefore the
    /// scheduler's own decision order — a structural property — unlike the order the worker threads
    /// happen to reach the producer, or the order completions are delivered, both of which move with
    /// thread scheduling and therefore jitter on a loaded machine.
    ///
    /// It changes nothing about dispatch: the app never turns it on, and while it is off the cost is
    /// one bool test per admission. Set it before a batch; read `admissionWitness()` when idle.
    public var recordsAdmissionOrder: Bool {
        get { lock.lock(); defer { lock.unlock() }; return recordsAdmissions }
        set {
            lock.lock()
            recordsAdmissions = newValue
            if newValue { admissions.removeAll(keepingCapacity: true) }
            lock.unlock()
        }
    }

    /// Keys in the order `pump()` admitted them. Empty unless `recordsAdmissionOrder` is on.
    public func admissionWitness() -> [ThumbKey] {
        lock.lock(); defer { lock.unlock() }
        return admissions
    }

    public func resetStats() {
        lock.lock()
        counters = Stats()
        counters.maxConcurrency = config.maxConcurrency
        counters.active = activeCount
        counters.queued = pending.count
        lock.unlock()
    }

    /// Summary of a ticket requested without a completion handler. `data` is `nil`: the bytes are in
    /// the cache, where the next reader will get them without a second producer call.
    public func result(for ticket: ThumbTicket) -> ThumbResult? {
        lock.lock(); defer { lock.unlock() }
        return summaries[ticket.id]
    }

    public func clearResults() {
        lock.lock(); summaries.removeAll(); lock.unlock()
    }
}

// MARK: - report

/// The numbers `photonsctl thumbs --report` prints. Mirrored as JSON so a script can assert on it
/// instead of scraping text (§5: print measured values, not estimates).
public struct ThumbServiceReport: Sendable, Codable {
    public var requests: Int
    public var coalesced: Int
    public var hits: Int
    public var generated: Int
    public var cancelled: Int
    public var cancelledInFlight: Int
    public var failed: Int
    public var rejectedWhilePaused: Int
    /// 326 — warms queued (not refused) while paused, and refusals replayed on resume.
    public var queuedWhilePaused: Int
    public var replayedAfterPause: Int
    public var droppedStaleGeneration: Int
    public var rejectedByDepth: Int
    public var queuedPeak: Int
    public var activePeak: Int
    public var maxConcurrency: Int
    public var averageWaitMilliseconds: Double
    public var maxWaitMilliseconds: Double
    public var hitRatio: Double
    public var writes: Int
    /// P1f: `graph` thumbnails rebuilt because the cache was upgraded (0 on every later start).
    public var rebuilt: Int

    public init(_ s: ThumbnailService.Stats) {
        requests = s.requests
        coalesced = s.coalesced
        hits = s.hits
        generated = s.missGenerated
        cancelled = s.missCancelled
        cancelledInFlight = s.cancelledInFlight
        failed = s.missFailed
        rejectedWhilePaused = s.rejectedWhilePaused
        queuedWhilePaused = s.queuedWhilePaused
        replayedAfterPause = s.replayedAfterPause
        droppedStaleGeneration = s.droppedStaleGeneration
        rejectedByDepth = s.rejectedByDepth
        queuedPeak = s.queuedPeak
        activePeak = s.activePeak
        maxConcurrency = s.maxConcurrency
        averageWaitMilliseconds = s.averageWaitMilliseconds
        maxWaitMilliseconds = s.maxWaitMilliseconds
        hitRatio = s.hitRatio
        writes = s.writes
        rebuilt = s.rebuilt
    }

    public var summaryLine: String {
        String(format: "service    req %d  coalesced %d  hits %d  gen %d  cancelled %d (inflight %d)"
               + "  failed %d  write %d  rebuilt %d", requests, coalesced, hits, generated, cancelled,
               cancelledInFlight, failed, writes, rebuilt)
    }

    public var queueLine: String {
        String(format: "queue      depthPeak %d  activePeak %d/%d  wait avg %.1f ms  max %.1f ms  hit %.3f",
               queuedPeak, activePeak, maxConcurrency, averageWaitMilliseconds,
               maxWaitMilliseconds, hitRatio)
    }
}

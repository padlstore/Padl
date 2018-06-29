// The MIT License (MIT)
//
// Copyright (c) 2015-2018 Alexander Grebenyuk (github.com/kean).

import Foundation

// MARK: - Lock

extension NSLock {
    func sync<T>(_ closure: () -> T) -> T {
        lock(); defer { unlock() }
        return closure()
    }
}

// MARK: - RateLimiter

/// Controls the rate at which the work is executed. Uses the classic [token
/// bucket](https://en.wikipedia.org/wiki/Token_bucket) algorithm.
///
/// The main use case for rate limiter is to support large (infinite) collections
/// of images by preventing trashing of underlying systems, primary URLSession.
///
/// The implementation supports quick bursts of requests which can be executed
/// without any delays when "the bucket is full". This is important to prevent
/// rate limiter from affecting "normal" requests flow.
internal final class RateLimiter {
    private let bucket: TokenBucket
    private let queue: DispatchQueue
    private var pending = LinkedList<Task>() // fast append, fast remove first
    private var isExecutingPendingTasks = false

    private typealias Task = (_CancellationToken, () -> Void)

    /// Initializes the `RateLimiter` with the given configuration.
    /// - parameter queue: Queue on which to execute pending tasks.
    /// - parameter rate: Maximum number of requests per second. 80 by default.
    /// - parameter burst: Maximum number of requests which can be executed without
    /// any delays when "bucket is full". 25 by default.
    init(queue: DispatchQueue, rate: Int = 80, burst: Int = 25) {
        self.queue = queue
        self.bucket = TokenBucket(rate: Double(rate), burst: Double(burst))
    }

    func execute(token: _CancellationToken, _ closure: @escaping () -> Void) {
        let task = Task(token, closure)
        if !pending.isEmpty || !_execute(task) {
            pending.append(task)
            _setNeedsExecutePendingTasks()
        }
    }

    private func _execute(_ task: Task) -> Bool {
        guard !task.0.isCancelling else {
            return true // No need to execute
        }
        return bucket.execute(task.1)
    }

    private func _setNeedsExecutePendingTasks() {
        guard !isExecutingPendingTasks else { return }
        isExecutingPendingTasks = true
        // Compute a delay such that by the time the closure is executed the
        // bucket is refilled to a point that is able to execute at least one
        // pending task. With a rate of 100 tasks we expect a refill every 10 ms.
        let delay = Int(1.15 * (1000 / bucket.rate)) // 14 ms for rate 80 (default)
        let bounds = max(100, min(5, delay)) // Make the delay is reasonable
        queue.asyncAfter(deadline: .now() + .milliseconds(bounds), execute: _executePendingTasks)
    }

    private func _executePendingTasks() {
        while let node = pending.first, _execute(node.value) {
            pending.remove(node)
        }
        isExecutingPendingTasks = false
        if !pending.isEmpty { // Not all pending items were executed
            _setNeedsExecutePendingTasks()
        }
    }

    private final class TokenBucket {
        let rate: Double
        private let burst: Double // maximum bucket size
        private var bucket: Double
        private var timestamp: TimeInterval // last refill timestamp

        /// - parameter rate: Rate (tokens/second) at which bucket is refilled.
        /// - parameter burst: Bucket size (maximum number of tokens).
        init(rate: Double, burst: Double) {
            self.rate = rate
            self.burst = burst
            self.bucket = burst
            self.timestamp = CFAbsoluteTimeGetCurrent()
        }

        /// Returns `true` if the closure was executed, `false` if dropped.
        func execute(_ closure: () -> Void) -> Bool {
            refill()
            guard bucket >= 1.0 else {
                return false // bucket is empty
            }
            bucket -= 1.0
            closure()
            return true
        }

        private func refill() {
            let now = CFAbsoluteTimeGetCurrent()
            bucket += rate * max(0, now - timestamp) // rate * (time delta)
            timestamp = now
            if bucket > burst { // prevent bucket overflow
                bucket = burst
            }
        }
    }
}

// MARK: - Operation

internal final class Operation: Foundation.Operation {
    enum State { case executing, finished }

    // `queue` here is basically to make TSan happy. In reality the calls to
    // `_setState` are guaranteed to never run concurrently in different ways.
    private var _state: State?
    private func _setState(_ newState: State) {
        willChangeValue(forKey: "isExecuting")
        if newState == .finished {
            willChangeValue(forKey: "isFinished")
        }
        queue.sync(flags: .barrier) {
            _state = newState
        }
        didChangeValue(forKey: "isExecuting")
        if newState == .finished {
            didChangeValue(forKey: "isFinished")
        }
    }

    override var isExecuting: Bool {
        return queue.sync { _state == .executing }
    }
    override var isFinished: Bool {
        return queue.sync { _state == .finished }
    }

    typealias Starter = (_ fulfill: @escaping () -> Void) -> Void
    private let starter: Starter
    private let queue = DispatchQueue(label: "com.github.kean.Nuke.Operation", attributes: .concurrent)

    init(starter: @escaping Starter) {
        self.starter = starter
    }

    override func start() {
        guard !isCancelled else {
            _setState(.finished)
            return
        }
        _setState(.executing)
        starter { [weak self] in
            DispatchQueue.main.async { self?._finish() }
        }
    }

    // Calls to _finish() are syncrhonized on the main thread. This way we
    // guarantee that `starter` doesn't finish operation more than once.
    // Other paths are also guaranteed to be safe.
    private func _finish() {
        guard _state != .finished else { return }
        _setState(.finished)
    }
}

// MARK: - LinkedList

/// A doubly linked list.
internal final class LinkedList<Element> {
    // first <-> node <-> ... <-> last
    private(set) var first: Node?
    private(set) var last: Node?

    deinit {
        removeAll()
    }

    var isEmpty: Bool {
        return last == nil
    }

    /// Adds an element to the end of the list.
    @discardableResult func append(_ element: Element) -> Node {
        let node = Node(value: element)
        append(node)
        return node
    }

    /// Adds a node to the end of the list.
    func append(_ node: Node) {
        if let last = last {
            last.next = node
            node.previous = last
            self.last = node
        } else {
            last = node
            first = node
        }
    }

    func remove(_ node: Node) {
        node.next?.previous = node.previous // node.previous is nil if node=first
        node.previous?.next = node.next // node.next is nil if node=last
        if node === last {
            last = node.previous
        }
        if node === first {
            first = node.next
        }
        node.next = nil
        node.previous = nil
    }

    func removeAll() {
        // avoid recursive Nodes deallocation
        var node = first
        while let next = node?.next {
            node?.next = nil
            next.previous = nil
            node = next
        }
        last = nil
        first = nil
    }

    final class Node {
        let value: Element
        fileprivate var next: Node?
        fileprivate var previous: Node?

        init(value: Element) {
            self.value = value
        }
    }
}

// MARK: - CancellationTokenSource

/// Manages cancellation tokens and signals them when cancellation is requested.
///
/// All `CancellationTokenSource` methods are thread safe.
internal final class _CancellationTokenSource {
    /// Returns `true` if cancellation has been requested.
    var isCancelling: Bool {
        return _lock.sync { _observers == nil }
    }

    /// Creates a new token associated with the source.
    var token: _CancellationToken {
        return _CancellationToken(source: self)
    }

    private var _observers: ContiguousArray<() -> Void>? = []

    /// Initializes the `CancellationTokenSource` instance.
    init() {}

    fileprivate func register(_ closure: @escaping () -> Void) {
        if !_register(closure) {
            closure()
        }
    }

    private func _register(_ closure: @escaping () -> Void) -> Bool {
        _lock.lock(); defer { _lock.unlock() }
        _observers?.append(closure)
        return _observers != nil
    }

    /// Communicates a request for cancellation to the managed tokens.
    func cancel() {
        if let observers = _cancel() {
            observers.forEach { $0() }
        }
    }

    private func _cancel() -> ContiguousArray<() -> Void>? {
        _lock.lock(); defer { _lock.unlock() }
        let observers = _observers
        _observers = nil // transition to `isCancelling` state
        return observers
    }
}

// We use the same lock across different tokens because the design of CTS
// prevents potential issues. For example, closures registered with a token
// are never executed inside a lock.
private let _lock = NSLock()

/// Enables cooperative cancellation of operations.
///
/// You create a cancellation token by instantiating a `CancellationTokenSource`
/// object and calling its `token` property. You then pass the token to any
/// number of threads, tasks, or operations that should receive notice of
/// cancellation. When the owning object calls `cancel()`, the `isCancelling`
/// property on every copy of the cancellation token is set to `true`.
/// The registered objects can respond in whatever manner is appropriate.
///
/// All `CancellationToken` methods are thread safe.
internal struct _CancellationToken {
    fileprivate let source: _CancellationTokenSource? // no-op when `nil`

    /// Returns `true` if cancellation has been requested for this token.
    var isCancelling: Bool {
        return source?.isCancelling ?? false
    }

    /// Registers the closure that will be called when the token is canceled.
    /// If this token is already cancelled, the closure will be run immediately
    /// and synchronously.
    func register(_ closure: @escaping () -> Void) {
        source?.register(closure)
    }

    /// Special no-op token which does nothing.
    static var noOp: _CancellationToken {
        return _CancellationToken(source: nil)
    }
}

// MARK: - CancellationSource

/// Lightweight variant of _CancellationTokenSource with a single handler
/// and struct instead of a class.
internal struct _CancellationSource {
    /// Returns `true` if cancellation has been requested.
    var isCancelling: Bool {
        return _lock.sync { _isCancelling }
    }

    private var _isCancelling: Bool = false
    private var _observer: (() -> Void)?

    mutating func register(_ closure: @escaping () -> Void) {
        if !_register(closure) {
            closure()
        }
    }

    private mutating func _register(_ closure: @escaping () -> Void) -> Bool {
        _lock.lock(); defer { _lock.unlock() }
        guard !_isCancelling else { return false }
        assert(_observer == nil)
        _observer = closure
        return true
    }

    /// Communicates a request for cancellation to the managed tokens.
    mutating func cancel() {
        if let observer = _cancel() {
            observer()
        }
    }

    private mutating func _cancel() -> (() -> Void)? {
        _lock.lock(); defer { _lock.unlock() }
        guard !_isCancelling else { return nil }
        _isCancelling = true
        defer { _observer = nil }
        return _observer
    }
}

// MARK: - ResumableData

/// Resumable data support. For more info see:
/// - https://developer.apple.com/library/content/qa/qa1761/_index.html
internal struct ResumableData {
    let data: Data
    let validator: String // Either Last-Modified or ETag

    init?(response: URLResponse, data: Data) {
        // Check if "Accept-Ranges" is present and the response is valid.
        guard !data.isEmpty,
            let response = response as? HTTPURLResponse,
            response.statusCode == 200 /* OK */ || response.statusCode == 206, /* Partial Content */
            let acceptRanges = response.allHeaderFields["Accept-Ranges"] as? String,
            acceptRanges.lowercased() == "bytes",
            let validator = ResumableData._validator(from: response) else {
                return nil
        }

        // NOTE: https://developer.apple.com/documentation/foundation/httpurlresponse/1417930-allheaderfields
        // HTTP headers are case insensitive. To simplify your code, certain
        // header field names are canonicalized into their standard form.
        // For example, if the server sends a content-length header,
        // it is automatically adjusted to be Content-Length.

        self.data = data; self.validator = validator
    }

    private static func _validator(from response: HTTPURLResponse) -> String? {
        if let entityTag = response.allHeaderFields["ETag"] as? String {
            return entityTag // Prefer ETag
        }
        // There seems to be a bug with ETag where HTTPURLResponse would canonicalize
        // it to Etag instead of ETag
        // https://bugs.swift.org/browse/SR-2429
        if let entityTag = response.allHeaderFields["Etag"] as? String {
            return entityTag // Prefer ETag
        }
        if let lastModified = response.allHeaderFields["Last-Modified"] as? String {
            return lastModified
        }
        return nil
    }

    func resume(request: inout URLRequest) {
        var headers = request.allHTTPHeaderFields ?? [:]
        // "bytes=1000-" means bytes from 1000 up to the end (inclusive)
        headers["Range"] = "bytes=\(data.count)-"
        headers["If-Range"] = validator
        request.allHTTPHeaderFields = headers
    }

    // Check if the server decided to resume the response.
    static func isResumedResponse(_ response: URLResponse) -> Bool {
        // "206 Partial Content" (server accepted "If-Range")
        return (response as? HTTPURLResponse)?.statusCode == 206
    }

    // MARK: Storing Resumable Data

    /// Shared between multiple pipelines. Thread safe. In the future version we
    /// might feature more customization options.
    static var _cache = _Cache<String, ResumableData>(costLimit: 32 * 1024 * 1024, countLimit: 100) // internal only for testing purposes

    static func removeResumableData(for request: URLRequest) -> ResumableData? {
        guard let url = request.url?.absoluteString else { return nil }
        return _cache.removeValue(forKey: url)
    }

    static func storeResumableData(_ data: ResumableData, for request: URLRequest) {
        guard let url = request.url?.absoluteString else { return }
        _cache.set(data, forKey: url, cost: data.data.count)
    }
}

// MARK: - Printer

/// Helper type for printing nice debug descriptions.
internal struct Printer {
    private(set) internal var _out = String()

    private let timelineFormatter: DateFormatter

    init(_ string: String = "") {
        self._out = string

        timelineFormatter = DateFormatter()
        timelineFormatter.dateFormat = "HH:mm:ss.SSS"
    }

    func output(indent: Int = 0) -> String {
        return _out.components(separatedBy: .newlines)
            .map { $0.isEmpty ? "" : String(repeating: " ", count: indent) + $0 }
            .joined(separator: "\n")
    }

    mutating func string(_ str: String) {
        _out.append(str)
    }

    mutating func line(_ str: String) {
        _out.append(str)
        _out.append("\n")
    }

    mutating func value(_ key: String, _ value: CustomStringConvertible?) {
        let val = value.map { String(describing: $0) }
        line(key + " - " + (val ?? "nil"))
    }

    /// For producting nicely formatted timelines like this:
    ///
    /// 11:45:52.737 - Data Loading Start Date
    /// 11:45:52.739 - Data Loading End Date
    /// nil          - Decoding Start Date
    mutating func timeline(_ key: String, _ date: Date?) {
        let value = date.map { timelineFormatter.string(from: $0) }
        self.value((value ?? "nil         "), key) // Swtich key with value
    }

    mutating func timeline(_ key: String, _ start: Date?, _ end: Date?, isReversed: Bool = true) {
        let duration = _duration(from: start, to: end)
        let value = "\(_string(from: start)) – \(_string(from: end)) (\(duration))"
        if isReversed {
            self.value(value.padding(toLength: 36, withPad: " ", startingAt: 0), key)
        } else {
            self.value(key, value)
        }
    }

    mutating func section(title: String, _ closure: (inout Printer) -> Void) {
        _out.append(contentsOf: title)
        _out.append(" {\n")
        var printer = Printer()
        closure(&printer)
        _out.append(printer.output(indent: 4))
        _out.append("}\n")
    }

    // MARK: Formatters

    private func _string(from date: Date?) -> String {
        return date.map { timelineFormatter.string(from: $0) } ?? "nil"
    }

    private func _duration(from: Date?, to: Date?) -> String {
        guard let from = from else { return "nil" }
        guard let to = to else { return "unknown" }
        return Printer.duration(to.timeIntervalSince(from)) ?? "nil"
    }

    static func duration(_ duration: TimeInterval?) -> String? {
        guard let duration = duration else { return nil }

        let m: Int = Int(duration) / 60
        let s: Int = Int(duration) % 60
        let ms: Int = Int(duration * 1000) % 1000

        var output = String()
        if m > 0 { output.append("\(m):") }
        output.append(output.isEmpty ? "\(s)." : String(format: "%02d.", s))
        output.append(String(format: "%03ds", ms))
        return output
    }
}

// MARK: - Misc

final class NoOpCancellable: Cancellable {
    func cancel() {
        return // Do nothing
    }
}

extension DispatchWorkItem: Cancellable {}

struct TaskMetrics {
    var startDate: Date? = nil
    var endDate: Date? = nil
    mutating func start() {
        self.startDate = Date()
    }
    mutating func end() {
        self.endDate = Date()
    }
}

final class DisposableOperation: Hashable {
    // When all registered tasks remove references to image processing
    // session the wrapped operation gets deallocated.
    deinit {
        operation?.cancel()
    }

    weak var operation: Foundation.Operation?

    init(_ operation: Foundation.Operation) {
        self.operation = operation
    }

    // MARK: - Hashable

    public static func == (lhs: DisposableOperation, rhs: DisposableOperation) -> Bool {
        return ObjectIdentifier(lhs) == ObjectIdentifier(rhs)
    }

    public var hashValue: Int {
        return ObjectIdentifier(self).hashValue
    }
}

/// A simple observable property. Not thread safe.
final class Property<T> {
    var value: T {
        didSet {
            for observer in observers {
                observer(value)
            }
        }
    }

    init(value: T) {
        self.value = value
    }

    private var observers = [(T) -> Void]()

    func observe(_ closure: @escaping (T) -> Void) {
        observers.append(closure)
    }
}
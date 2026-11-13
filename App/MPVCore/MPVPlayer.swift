import Foundation
import QuartzCore
import os
import Libmpv

struct MPVError: Error, CustomStringConvertible {
    let code: Int32
    let context: String

    var description: String {
        "\(context): \(String(cString: mpv_error_string(code)))"
    }
}

/// Thin wrapper over one libmpv client handle.
///
/// Every method may be called from any thread and **never blocks** on the mpv core:
/// commands and property writes use libmpv's async API, and there are no synchronous
/// property reads (observe properties instead). This matters because mpv's render thread
/// synchronously waits on the main thread (e.g. to enable EDR on the layer); a blocking
/// call from the main thread while the core waits on the render thread deadlocks.
///
/// Events are drained on a private serial queue and published through `events`.
final class MPVPlayer: @unchecked Sendable {
    let events: AsyncStream<MPVEvent>

    private let handle: OpaquePointer
    private let continuation: AsyncStream<MPVEvent>.Continuation
    private let eventQueue = DispatchQueue(label: "com.hankunyu.Yoru.mpv.events", qos: .userInitiated)
    // Guards public API calls against use after `destroy()`.
    private let alive = OSAllocatedUnfairLock(initialState: true)
    // Custom URL schemes; mpv calls into these until the handle is destroyed.
    private var streamProtocols: [MPVStreamProtocol] = []

    /// Creates and initializes an mpv instance rendering into `layer`.
    ///
    /// - Parameters:
    ///   - layer: The Metal layer mpv's MoltenVK context presents into. The caller keeps it alive.
    ///   - configDirectory: mpv's `config-dir`; `mpv.conf`, `input.conf` and `scripts/` are read from it.
    ///   - options: App defaults applied before the config file, so `mpv.conf` can override any of them.
    ///   - streamProtocols: URL schemes served by the app instead of mpv's own stream layer.
    init(
        layer: CAMetalLayer,
        configDirectory: URL,
        options: [(name: String, value: String)],
        streamProtocols: [String: MPVStreamOpener] = [:]
    ) throws(MPVError) {
        guard let handle = mpv_create() else {
            throw MPVError(code: MPV_ERROR_NOMEM.rawValue, context: "mpv_create")
        }
        self.handle = handle
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)

        var layerPointer = Int64(Int(bitPattern: Unmanaged.passUnretained(layer).toOpaque()))
        try Self.check(mpv_set_option(handle, "wid", MPV_FORMAT_INT64, &layerPointer), "wid")
        for (name, value) in options {
            try Self.check(mpv_set_option_string(handle, name, value), "option \(name)")
        }
        // libmpv skips config files unless asked; both must be set before initialize.
        try Self.check(mpv_set_option_string(handle, "config-dir", configDirectory.path), "config-dir")
        try Self.check(mpv_set_option_string(handle, "config", "yes"), "config")

        mpv_request_log_messages(handle, "info")
        mpv_set_wakeup_callback(handle, { context in
            guard let context else { return }
            Unmanaged<MPVPlayer>.fromOpaque(context).takeUnretainedValue().scheduleDrain()
        }, Unmanaged.passUnretained(self).toOpaque())

        // On any failure above or here, deinit runs `destroy()` and releases the handle.
        try Self.check(mpv_initialize(handle), "mpv_initialize")
        self.streamProtocols = streamProtocols.map { scheme, opener in
            MPVStreamProtocol.register(scheme, opener: opener, on: handle)
        }
    }

    deinit {
        destroy()
    }

    /// Shuts mpv down (equivalent to the `quit` command, so `save-position-on-quit` applies).
    /// Blocks only the private event queue, never the caller; `completion` runs there once
    /// mpv is gone.
    func destroy(completion: (@Sendable () -> Void)? = nil) {
        let wasAlive = alive.withLock { isAlive in
            defer { isAlive = false }
            return isAlive
        }
        guard wasAlive else { return }
        let handle = handle
        let continuation = continuation
        let streamProtocols = streamProtocols
        eventQueue.async {
            mpv_set_wakeup_callback(handle, nil, nil)
            // mpv closes its streams while shutting down, so their protocols must outlive it.
            withExtendedLifetime(streamProtocols) {
                mpv_terminate_destroy(handle)
            }
            continuation.finish()
            completion?()
        }
    }

    // MARK: - Commands and properties

    /// Queues a command. Failures are logged when mpv replies.
    func command(_ arguments: String...) {
        command(arguments)
    }

    /// Queues a command. Failures are logged when mpv replies.
    func command(_ arguments: [String]) {
        _ = withHandle { handle in
            var cArguments: [UnsafePointer<CChar>?] = arguments.map { UnsafePointer(strdup($0)) }
            cArguments.append(nil)
            defer {
                for pointer in cArguments {
                    free(UnsafeMutablePointer(mutating: pointer))
                }
            }
            return report(mpv_command_async(handle, 0, &cArguments), "command \(arguments.first ?? "")")
        }
    }

    /// Queues a property write. Failures are logged when mpv replies.
    func setProperty(_ name: String, _ value: String) {
        _ = withHandle { handle in
            var cValue: UnsafePointer<CChar>? = UnsafePointer(strdup(value))
            defer { free(UnsafeMutablePointer(mutating: cValue)) }
            // libmpv copies the value before returning.
            return report(mpv_set_property_async(handle, 0, name, MPV_FORMAT_STRING, &cValue), "set \(name)")
        }
    }

    /// Queues a write of a structured value (a list or a map). Failures are logged when
    /// mpv replies.
    func setProperty(_ name: String, node value: MPVValue) {
        _ = withHandle { handle in
            var allocations: [UnsafeMutableRawPointer] = []
            defer { allocations.forEach { $0.deallocate() } }
            var node = Self.node(for: value, allocations: &allocations)
            // libmpv copies the value before returning.
            return report(mpv_set_property_async(handle, 0, name, MPV_FORMAT_NODE, &node), "set \(name)")
        }
    }

    /// Lays `value` out as libmpv's node tree. Everything it points at is added to
    /// `allocations`, which the caller frees once libmpv has taken its copy.
    static func node(for value: MPVValue, allocations: inout [UnsafeMutableRawPointer]) -> mpv_node {
        func string(_ text: String) -> UnsafeMutablePointer<CChar> {
            let bytes = Array(text.utf8CString)
            let pointer = UnsafeMutablePointer<CChar>.allocate(capacity: bytes.count)
            pointer.initialize(from: bytes, count: bytes.count)
            allocations.append(UnsafeMutableRawPointer(pointer))
            return pointer
        }
        func list(_ values: [MPVValue], keys: [String]?) -> UnsafeMutablePointer<mpv_node_list> {
            let list = UnsafeMutablePointer<mpv_node_list>.allocate(capacity: 1)
            allocations.append(UnsafeMutableRawPointer(list))
            let nodes = UnsafeMutablePointer<mpv_node>.allocate(capacity: max(values.count, 1))
            allocations.append(UnsafeMutableRawPointer(nodes))
            for (index, value) in values.enumerated() {
                nodes[index] = node(for: value, allocations: &allocations)
            }
            var keyPointers: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
            if let keys {
                let pointers = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: max(keys.count, 1))
                allocations.append(UnsafeMutableRawPointer(pointers))
                for (index, key) in keys.enumerated() {
                    pointers[index] = string(key)
                }
                keyPointers = pointers
            }
            list.initialize(to: mpv_node_list(num: Int32(values.count), values: nodes, keys: keyPointers))
            return list
        }
        var result = mpv_node()
        switch value {
        case .none:
            result.format = MPV_FORMAT_NONE
        case .flag(let flag):
            result.format = MPV_FORMAT_FLAG
            result.u.flag = flag ? 1 : 0
        case .int(let number):
            result.format = MPV_FORMAT_INT64
            result.u.int64 = number
        case .double(let number):
            result.format = MPV_FORMAT_DOUBLE
            result.u.double_ = number
        case .string(let text):
            result.format = MPV_FORMAT_STRING
            result.u.string = string(text)
        case .array(let values):
            result.format = MPV_FORMAT_NODE_ARRAY
            result.u.list = list(values, keys: nil)
        case .map(let map):
            let keys = map.keys.sorted()
            result.format = MPV_FORMAT_NODE_MAP
            result.u.list = list(keys.map { map[$0]! }, keys: keys)
        }
        return result
    }

    func observe(_ name: String, format: MPVFormat) {
        _ = withHandle { handle in
            report(mpv_observe_property(handle, 0, name, format.raw), "observe \(name)")
        }
    }

    // MARK: - Private

    private func withHandle<T>(_ body: (OpaquePointer) -> T) -> T? {
        // The lock is held across the call so `destroy()` cannot interleave with it.
        alive.withLockUnchecked { isAlive in
            isAlive ? body(handle) : nil
        }
    }

    private func scheduleDrain() {
        eventQueue.async { [self] in
            drainEvents()
        }
    }

    // Runs on `eventQueue`, which also performs the final destroy, so the handle stays valid here.
    private func drainEvents() {
        guard alive.withLock({ $0 }) else { return }
        while let event = mpv_wait_event(handle, 0)?.pointee, event.event_id != MPV_EVENT_NONE {
            if event.event_id == MPV_EVENT_COMMAND_REPLY || event.event_id == MPV_EVENT_SET_PROPERTY_REPLY {
                report(event.error, String(cString: mpv_event_name(event.event_id)))
            }
            if let decoded = MPVEvent(event) {
                continuation.yield(decoded)
            }
            if event.event_id == MPV_EVENT_SHUTDOWN {
                return
            }
        }
    }

    @discardableResult
    private func report(_ status: Int32, _ context: String) -> Bool {
        if status < 0 {
            Log.mpv.error("\(MPVError(code: status, context: context).description, privacy: .public)")
            return false
        }
        return true
    }

    private static func check(_ status: Int32, _ context: String) throws(MPVError) {
        if status < 0 {
            throw MPVError(code: status, context: context)
        }
    }
}

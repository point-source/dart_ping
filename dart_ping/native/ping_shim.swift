//
//  ping_shim.swift
//  dart_ping  (native FFI code-asset path)
//
//  Thin, hand-written `@_cdecl` shim that fronts the audited Swift `PingEngine`
//  (§spec:swift-icmp-engine) with the flat C ABI declared in
//  `native/include/dart_ping_ffi.h`. This is "Layer B" of the iOS code-asset
//  path: it marshals the engine's Swift `Event`s into the flat `dart_ping_event`
//  struct and invokes the C `callback`, and converts the C start arguments into a
//  `PingEngine.Config` (§spec:ios-code-asset-build-hook, §spec:ios-ffi-binding).
//
//  No swift2objc / ffigen, no `objective_c` runtime bridge — the surface is just
//  start / stop / one event callback, carried by a flat C function pointer that a
//  `dart:ffi` `NativeCallable.listen` consumes on the Dart side (#28-2). The C
//  types used below come from `dart_ping_ffi.h`, imported into this file by the
//  build hook (WS3) via swiftc `-import-objc-header`; the `@_cdecl` signatures
//  here MUST match that header exactly.
//
//  EVENT LIFETIME (#28-2, §spec:ios-ffi-binding, §spec:ios-background-isolate):
//  each event is HEAP-ALLOCATED here and its ownership is TRANSFERRED to the Dart
//  receiver, which frees it via the `dart_ping_free_event` entry point after
//  copying the fields it needs (Swift frees what Swift allocated). This replaces
//  the earlier callback-scoped stack buffers, which would be freed before an
//  async `NativeCallable.listen` handler runs (use-after-free).
//
//  Compiled into the single iOS code asset alongside PingEngine.swift and
//  ICMPPacket.swift. iOS-only; not Linux-compilable (the engine imports Darwin
//  networking) and therefore NOT built on Linux CI — this shim is hand-verified
//  on macOS per native/README.md (the standalone swiftc command there).
//

import Foundation

// MARK: - Run box

/// Retains the `PingEngine` for the lifetime of a run. The opaque
/// `dart_ping_handle` returned by `dart_ping_start` is an `Unmanaged` reference
/// to one of these; `dart_ping_stop` recovers it, stops the engine, and lets the
/// box deallocate.
///
/// NOTE: the engine's `onEvent` closure captures the C `callback` and `context`
/// BY VALUE (they are a plain function pointer and an opaque pointer) — it does
/// NOT capture the box — so there is no retain cycle between the box and the
/// engine's closure.
private final class PingRun {
    let engine: PingEngine

    init(engine: PingEngine) {
        self.engine = engine
    }
}

// MARK: - Event marshalling

/// `strdup` the given Swift string into a C heap buffer (`malloc`-allocated,
/// NUL-terminated UTF-8). Returns a pointer that `dart_ping_free_event` later
/// releases with `free`. Allocator-symmetric: Swift frees what Swift allocated.
private func heapCopy(_ string: String) -> UnsafeMutablePointer<CChar> {
    return string.withCString { strdup($0) }
}

/// Marshal one `PingEngine.Event` into a HEAP-ALLOCATED `dart_ping_event` and
/// invoke the C `callback`, transferring ownership of the struct (and its `ip`
/// string and `errors` array) to the receiver.
///
/// LIFETIME (§spec:ios-ffi-binding, §spec:ios-background-isolate): the per-event
/// callback is consumed by a Dart `NativeCallable.listen`, so the C call returns
/// before the Dart handler runs. A callback-scoped stack buffer (the old
/// `withCString` / `withUnsafeBufferPointer` approach) would therefore be freed
/// out from under the async handler (use-after-free). Instead we `malloc` the
/// event and `strdup`/`malloc`-copy its `ip` and `errors` buffers, hand the
/// pointer to the callback, and DO NOT free — the receiver releases everything
/// via `dart_ping_free_event` after copying the fields it needs.
private func deliver(_ event: PingEngine.Event,
                     to callback: dart_ping_event_callback,
                     context: UnsafeMutableRawPointer?) {
    // Heap-allocate the event struct; zero-initialize so unspecified fields for
    // the active kind read as 0 / false / NULL. Ownership transfers to the
    // receiver, which frees it (and ip/errors) via dart_ping_free_event.
    let evPtr = UnsafeMutablePointer<dart_ping_event>.allocate(capacity: 1)
    evPtr.initialize(to: dart_ping_event())

    switch event {

    case let .response(seq, ttl, timeMicros, ip):
        // .response: seq always present; ttl nullable (v6 may lack hop limit);
        // ip always present (heap-copied so it outlives the async call).
        evPtr.pointee.kind = DART_PING_EVENT_RESPONSE
        evPtr.pointee.has_seq = true
        evPtr.pointee.seq = Int64(seq)
        evPtr.pointee.has_ttl = (ttl != nil)
        evPtr.pointee.ttl = Int64(ttl ?? 0)
        evPtr.pointee.time_micros = Int64(timeMicros)
        evPtr.pointee.has_ip = true
        evPtr.pointee.ip = UnsafePointer(heapCopy(ip))

    case let .error(kind, seq, ip):
        // .error: seq and ip both nullable. Heap-copy the ip when present;
        // leave ip NULL / has_ip false otherwise.
        evPtr.pointee.kind = DART_PING_EVENT_ERROR
        evPtr.pointee.error_kind = cErrorKind(kind)
        evPtr.pointee.has_seq = (seq != nil)
        evPtr.pointee.seq = Int64(seq ?? 0)
        if let ip = ip {
            evPtr.pointee.has_ip = true
            evPtr.pointee.ip = UnsafePointer(heapCopy(ip))
        } else {
            evPtr.pointee.has_ip = false
            evPtr.pointee.ip = nil
        }

    case let .summary(transmitted, received, timeMicros, errors):
        // .summary: carry the errors list as a heap-allocated contiguous Int32
        // buffer (NULL when empty) so it outlives the async call.
        evPtr.pointee.kind = DART_PING_EVENT_SUMMARY
        // Counts are realistically tiny, but use a non-trapping narrowing so an
        // extreme run can never crash the consuming app via an Int32 overflow
        // trap (security review #28-1). Int32 cannot hold > ~2.1B regardless.
        evPtr.pointee.transmitted = Int32(truncatingIfNeeded: transmitted)
        evPtr.pointee.received = Int32(truncatingIfNeeded: received)
        evPtr.pointee.time_micros = Int64(timeMicros)
        let codes: [Int32] = errors.map { Int32(cErrorKind($0).rawValue) }
        if codes.isEmpty {
            evPtr.pointee.errors = nil
            evPtr.pointee.errors_len = 0
        } else {
            let buf = UnsafeMutablePointer<Int32>.allocate(capacity: codes.count)
            buf.initialize(from: codes, count: codes.count)
            evPtr.pointee.errors = UnsafePointer(buf)
            evPtr.pointee.errors_len = Int32(truncatingIfNeeded: codes.count)
        }
    }

    // Hand ownership to the receiver; it frees via dart_ping_free_event.
    callback(context, evPtr)
}

/// Map a Swift `PingErrorKind` to its C enum counterpart.
private func cErrorKind(_ kind: PingErrorKind) -> dart_ping_error_kind {
    switch kind {
    case .requestTimedOut:    return DART_PING_ERROR_REQUEST_TIMED_OUT
    case .timeToLiveExceeded: return DART_PING_ERROR_TIME_TO_LIVE_EXCEEDED
    case .noReply:            return DART_PING_ERROR_NO_REPLY
    case .unknownHost:        return DART_PING_ERROR_UNKNOWN_HOST
    case .noRoute:            return DART_PING_ERROR_NO_ROUTE
    case .unknown:            return DART_PING_ERROR_UNKNOWN
    }
}

/// Map the C `family` argument to a Swift `IPFamily`. Any value other than the
/// explicit v6 discriminator falls back to v4 (the engine's default selection).
private func swiftFamily(_ family: Int32) -> IPFamily {
    return family == Int32(DART_PING_FAMILY_V6.rawValue) ? .v6 : .v4
}

// MARK: - C ABI entry points

/// Start a ping run. Converts the C arguments into a `PingEngine.Config`,
/// constructs the engine with the marshalling `onEvent`, starts it, boxes it, and
/// returns a retained opaque handle. Returns NULL on a NULL host or NULL callback.
@_cdecl("dart_ping_start")
public func dart_ping_start(_ host: UnsafePointer<CChar>?,
                            _ count: Int64,
                            _ interval_seconds: Double,
                            _ timeout_seconds: Double,
                            _ ttl: Int64,
                            _ family: Int32,
                            _ nat64_synthesis: Bool,
                            _ callback: dart_ping_event_callback?,
                            _ context: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer? {
    // A NULL host or NULL callback is a programming error on the Dart side; fail
    // closed with a NULL handle rather than crashing.
    guard let host = host, let callback = callback else { return nil }

    let config = PingEngine.Config(
        host: String(cString: host),
        count: count < 0 ? nil : Int(count),   // count < 0 => unlimited (Swift nil)
        interval: TimeInterval(interval_seconds),
        timeout: TimeInterval(timeout_seconds),
        ttl: Int(ttl),
        family: swiftFamily(family),
        nat64Synthesis: nat64_synthesis
    )

    // The closure captures `callback` and `context` BY VALUE (a function pointer
    // and an opaque pointer) — NOT the box — so there is no retain cycle.
    let engine = PingEngine(config: config) { event in
        deliver(event, to: callback, context: context)
    }
    engine.start()

    let box = PingRun(engine: engine)
    return Unmanaged.passRetained(box).toOpaque()
}

/// Stop a ping run and release its handle. Recovers the box, calls the engine's
/// `stop()`, and lets the box (and engine) deallocate. NULL is ignored.
///
/// LIFECYCLE BOUNDARY (finalized by #28-2, §spec:ios-ffi-binding): after `stop()`
/// the engine may still deliver an already-queued event on its background queue
/// (e.g. the terminal summary). This shim does NOT guard against a post-stop
/// callback — keeping the Dart-side `NativeCallable` alive until the terminal
/// summary / stream close is the isolate/threading model owned by #28-2
/// (§spec:ios-background-isolate).
@_cdecl("dart_ping_stop")
public func dart_ping_stop(_ handle: UnsafeMutableRawPointer?) {
    guard let handle = handle else { return }
    let box = Unmanaged<PingRun>.fromOpaque(handle).takeRetainedValue()
    box.engine.stop()
}

/// Free a heap-allocated event previously delivered to the callback
/// (§spec:ios-ffi-binding). Allocator-symmetric with `deliver`'s `malloc` /
/// `strdup`: frees the event's `ip` string and `errors` buffer (each if
/// non-NULL), then the event struct itself. A NULL event is ignored. The Dart
/// receiver calls this once it has copied the fields it needs out of the
/// (async, ownership-transferred) event.
@_cdecl("dart_ping_free_event")
public func dart_ping_free_event(_ event: UnsafePointer<dart_ping_event>?) {
    guard let event = event else { return }
    // `ip` (strdup) and `errors` (malloc) are C heap allocations; free with
    // `free` to match. Cast away const for `free`, which takes `void *`.
    if let ip = event.pointee.ip {
        free(UnsafeMutableRawPointer(mutating: ip))
    }
    if let errors = event.pointee.errors {
        free(UnsafeMutableRawPointer(mutating: errors))
    }
    free(UnsafeMutableRawPointer(mutating: event))
}

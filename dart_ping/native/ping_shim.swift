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
//  Compiled into the single iOS code asset alongside PingEngine.swift and
//  ICMPPacket.swift. iOS-only; not Linux-compilable (the engine imports Darwin
//  networking). See native/README.md for the macOS hand-verification command.
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

/// Marshal one `PingEngine.Event` into a flat `dart_ping_event` and invoke the C
/// `callback`. All pointers handed to the callback (the event's `ip` string and
/// the summary's `errors` array) are valid ONLY for the duration of the
/// `callback` call — they live on the stack / in `withCString` /
/// `withUnsafeBufferPointer` scopes that close the instant the callback returns,
/// matching the lifetime contract documented in `dart_ping_ffi.h`.
private func deliver(_ event: PingEngine.Event,
                     to callback: dart_ping_event_callback,
                     context: UnsafeMutableRawPointer?) {
    switch event {

    case let .response(seq, ttl, timeMicros, ip):
        // .response: seq always present; ttl nullable (v6 may lack hop limit);
        // ip always present. The `ip` C-string is valid only inside withCString.
        ip.withCString { ipPtr in
            var ev = dart_ping_event()
            ev.kind = DART_PING_EVENT_RESPONSE
            ev.has_seq = true
            ev.seq = Int64(seq)
            ev.has_ttl = (ttl != nil)
            ev.ttl = Int64(ttl ?? 0)
            ev.time_micros = Int64(timeMicros)
            ev.has_ip = true
            ev.ip = ipPtr
            callback(context, &ev)
        }

    case let .error(kind, seq, ip):
        // .error: seq and ip both nullable. Build the event, then optionally
        // wrap the ip in a withCString scope so its pointer stays valid for the
        // callback; when ip is nil we pass a NULL pointer and has_ip == false.
        var ev = dart_ping_event()
        ev.kind = DART_PING_EVENT_ERROR
        ev.error_kind = cErrorKind(kind)
        ev.has_seq = (seq != nil)
        ev.seq = Int64(seq ?? 0)
        if let ip = ip {
            ip.withCString { ipPtr in
                ev.has_ip = true
                ev.ip = ipPtr
                callback(context, &ev)
            }
        } else {
            ev.has_ip = false
            ev.ip = nil
            callback(context, &ev)
        }

    case let .summary(transmitted, received, timeMicros, errors):
        // .summary: carry the errors list as a contiguous Int32 buffer whose
        // pointer is valid only inside withUnsafeBufferPointer.
        let codes: [Int32] = errors.map { Int32(cErrorKind($0).rawValue) }
        codes.withUnsafeBufferPointer { buf in
            var ev = dart_ping_event()
            ev.kind = DART_PING_EVENT_SUMMARY
            // Counts are realistically tiny, but use a non-trapping narrowing so an
            // extreme run can never crash the consuming app via an Int32 overflow
            // trap (security review #28-1). Int32 cannot hold > ~2.1B regardless.
            ev.transmitted = Int32(truncatingIfNeeded: transmitted)
            ev.received = Int32(truncatingIfNeeded: received)
            ev.time_micros = Int64(timeMicros)
            ev.errors = buf.baseAddress
            ev.errors_len = Int32(truncatingIfNeeded: buf.count)
            callback(context, &ev)
        }
    }
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

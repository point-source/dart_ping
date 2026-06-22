// dart_ping — pure `dart:ffi` bindings to the iOS native code asset.
//
// This is "Layer C" of the iOS code-asset path (§spec:ios-ffi-binding): the
// `dart:ffi` surface that binds the flat C ABI declared in
// `native/include/dart_ping_ffi.h` and implemented by the `@_cdecl` shim in
// `native/ping_shim.swift`. It defines:
//
//   * [DartPingEvent] — a `Struct` mirroring the C `dart_ping_event`
//     field-for-field, in declaration order;
//   * the enum integer constants the C header defines (event kind, error kind,
//     address family), so callers never hardcode magic numbers;
//   * the native callback typedef [DartPingEventCallbackNative]; and
//   * the three `@Native` entry points ([dartPingStart], [dartPingStop],
//     [dartPingFreeEvent]) keyed on the `package:dart_ping/dart_ping_ffi`
//     code asset emitted by `hook/build.dart`.
//
// IMPORTANT — platform & lifetime:
//
//   * The code asset is LINKED only at iOS app-build time and the native
//     functions are CALLABLE only on iOS. These `@Native` declarations analyze
//     fine on every platform (the asset is resolved at link time), but the
//     functions MUST NOT be called off iOS — they would fail to link. Tests on
//     Linux therefore only inspect the struct/constants, never call the
//     functions.
//   * Per §spec:ios-background-isolate the per-event callback is delivered
//     asynchronously (a `NativeCallable.listen`) on the owning isolate's event
//     loop, so the C call returns before the Dart handler runs. The shim
//     therefore HEAP-ALLOCATES each [DartPingEvent] (and its `ip` / `errors`
//     buffers) and transfers ownership to the Dart receiver. After copying the
//     fields it needs, the receiver MUST call [freeNativeEvent] (the
//     `dart_ping_free_event` C entry point) so Swift frees what Swift allocated.
//     See the lifetime docs in `native/include/dart_ping_ffi.h`.

import 'dart:ffi';

import 'package:ffi/ffi.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Enum integer values (mirror native/include/dart_ping_ffi.h exactly).
//
// These are plain `const int`s so the values are usable directly as FFI struct
// field reads without an enum-lookup allocation. `test/ios_bindings_test.dart`
// guards them against drift from the header.
// ─────────────────────────────────────────────────────────────────────────────

/// `dart_ping_event_kind` — the active case of a [DartPingEvent], read first.
abstract final class DartPingEventKind {
  /// `.response` — fields: seq, has_ttl/ttl, time_micros, ip.
  static const response = 0;

  /// `.error` — fields: error_kind, has_seq/seq, has_ip/ip.
  static const error = 1;

  /// `.summary` — fields: transmitted, received, time_micros, errors/errors_len.
  static const summary = 2;
}

/// `dart_ping_error_kind` — the error classification carried by a `.error`
/// event's `errorKind`, and the element type of a summary's `errors` array.
abstract final class DartPingErrorKind {
  /// Per-probe timeout (`.requestTimedOut`).
  static const requestTimedOut = 0;

  /// TTL / hop limit exceeded (`.timeToLiveExceeded`).
  static const timeToLiveExceeded = 1;

  /// Run-level: nothing came back (`.noReply`).
  static const noReply = 2;

  /// Name resolution miss (`.unknownHost`).
  static const unknownHost = 3;

  /// Address-family / route problem (`.noRoute`).
  static const noRoute = 4;

  /// Catch-all (`.unknown`).
  static const unknown = 5;
}

/// `dart_ping_family` — the IP address family a run resolves and sends for,
/// passed into [dartPingStart] as the `family` argument.
abstract final class DartPingFamily {
  /// `.v4`.
  static const v4 = 0;

  /// `.v6`.
  static const v6 = 1;
}

// ─────────────────────────────────────────────────────────────────────────────
// The flat event struct (mirrors `dart_ping_event`, field-for-field, in order).
// ─────────────────────────────────────────────────────────────────────────────

/// A single ping event, flattened from the engine's `Event`. Exactly one of the
/// three cases is active, selected by [kind]; read [kind] first and then only
/// the fields documented for that case.
///
/// This mirrors the C `dart_ping_event` struct in
/// `native/include/dart_ping_ffi.h` field-for-field, in the SAME ORDER — do not
/// reorder fields. The struct (and its [ip] / [errors] buffers) is heap-owned by
/// the receiver after delivery; free it with [freeNativeEvent].
final class DartPingEvent extends Struct {
  /// Which case is active (a [DartPingEventKind] value).
  @Int32()
  external int kind;

  /// Whether [seq] is present (false for run-level errors).
  @Bool()
  external bool hasSeq;

  /// Sequence number (valid per [hasSeq] / always valid for `.response`).
  @Int64()
  external int seq;

  /// Whether [ttl] is present (a v6 reply may lack a hop limit).
  @Bool()
  external bool hasTtl;

  /// Reply hop limit, only for `.response`.
  @Int64()
  external int ttl;

  /// Microsecond magnitude: RTT for `.response`, session duration for
  /// `.summary` (unspecified for `.error`).
  @Int64()
  external int timeMicros;

  /// Whether [ip] is present / non-NULL.
  @Bool()
  external bool hasIp;

  /// Source IP as a NUL-terminated UTF-8 string (may be NULL when [hasIp] is
  /// false).
  external Pointer<Utf8> ip;

  /// Error classification (a [DartPingErrorKind] value), only meaningful when
  /// [kind] == [DartPingEventKind.error].
  @Int32()
  external int errorKind;

  /// Total probes sent (`.summary`).
  @Int32()
  external int transmitted;

  /// Total replies matched (`.summary`).
  @Int32()
  external int received;

  /// Pointer to [errorsLen] contiguous `Int32` error codes (each a
  /// [DartPingErrorKind]); may be NULL when [errorsLen] is 0 (`.summary`).
  external Pointer<Int32> errors;

  /// Length of the [errors] array (`.summary`).
  @Int32()
  external int errorsLen;
}

// ─────────────────────────────────────────────────────────────────────────────
// Native callback typedef.
// ─────────────────────────────────────────────────────────────────────────────

/// The native signature of the per-event callback
/// (`dart_ping_event_callback`): `void (*)(void *context, const
/// dart_ping_event *event)`. WS2 wraps a Dart handler of this shape in a
/// `NativeCallable.listen` and passes its `nativeFunction` to [dartPingStart].
typedef DartPingEventCallbackNative =
    Void Function(Pointer<Void> context, Pointer<DartPingEvent> event);

// ─────────────────────────────────────────────────────────────────────────────
// C entry points, bound to the `package:dart_ping/dart_ping_ffi` code asset.
//
// Do NOT call these off iOS — the asset is only linked at iOS app-build time.
// ─────────────────────────────────────────────────────────────────────────────

/// Start a ping run (`dart_ping_start`). Returns an opaque handle, or
/// `nullptr` if `host` or `callback` is NULL.
@Native<
  Pointer<Void> Function(
    Pointer<Utf8> host,
    Int64 count,
    Double intervalSeconds,
    Double timeoutSeconds,
    Int64 ttl,
    Int32 family,
    Bool nat64Synthesis,
    Pointer<NativeFunction<DartPingEventCallbackNative>> callback,
    Pointer<Void> context,
  )
>(assetId: 'package:dart_ping/dart_ping_ffi', symbol: 'dart_ping_start')
external Pointer<Void> dartPingStart(
  Pointer<Utf8> host,
  int count,
  double intervalSeconds,
  double timeoutSeconds,
  int ttl,
  int family,
  bool nat64Synthesis,
  Pointer<NativeFunction<DartPingEventCallbackNative>> callback,
  Pointer<Void> context,
);

/// Stop a ping run and release its handle (`dart_ping_stop`). NULL is ignored;
/// after this call the handle is invalid.
@Native<Void Function(Pointer<Void> handle)>(
  assetId: 'package:dart_ping/dart_ping_ffi',
  symbol: 'dart_ping_stop',
)
external void dartPingStop(Pointer<Void> handle);

/// Free a heap-allocated event delivered to the callback
/// (`dart_ping_free_event`). Frees the event's `ip` / `errors` buffers and the
/// struct itself; NULL is ignored. Call after copying the fields you need.
@Native<Void Function(Pointer<DartPingEvent> event)>(
  assetId: 'package:dart_ping/dart_ping_ffi',
  symbol: 'dart_ping_free_event',
)
external void dartPingFreeEvent(Pointer<DartPingEvent> event);

/// Release a delivered [event] back to the shim's allocator. WS2 calls this once
/// it has copied the fields it needs out of the heap-transferred event.
void freeNativeEvent(Pointer<DartPingEvent> event) => dartPingFreeEvent(event);

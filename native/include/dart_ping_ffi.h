/*
 * dart_ping_ffi.h
 * dart_ping — flat C ABI over the native Swift ICMP engine.
 *
 * This header is the STABLE COMPILE CONTRACT between three layers of the
 * iOS code-asset path (§spec:ios-code-asset-build-hook, §spec:ios-ffi-binding):
 *
 *   1. The native Swift engine (PingEngine.swift / ICMPPacket.swift) — the
 *      audited ICMP implementation (§spec:swift-icmp-engine).
 *   2. The `@_cdecl` Swift shim (ping_shim.swift) — marshals the engine's
 *      Swift types to/from the flat C types declared here. The shim imports
 *      THIS header (via swiftc `-import-objc-header`), so the C signatures
 *      below must EXACTLY match the shim's `@_cdecl` signatures.
 *   3. The Dart FFI binding (LATER batch #28-2, §spec:ios-ffi-binding) — opens
 *      the compiled code asset and calls these symbols over `dart:ffi`.
 *
 * Design: the engine emits three kinds of events (response / error / summary)
 * over a single callback. This header carries them as ONE flat event struct
 * with a `kind` discriminator and `has_*` flags for the nullable fields, so a
 * single C function-pointer type drives every event (the cleanest carrier for a
 * `dart:ffi` `NativeCallable.listen`, §spec:ios-code-asset-build-hook).
 *
 * No Objective-C: this is plain C. The native surface is exactly three entry
 * points — start, stop, one event callback.
 */

#ifndef DART_PING_FFI_H
#define DART_PING_FFI_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Error kinds, mirroring Swift `PingEngine.PingErrorKind`
 * (§spec:address-family-error-honesty). Used both as `event.error_kind` and as
 * the element type of the summary's `errors` array.
 */
typedef enum {
  DART_PING_ERROR_REQUEST_TIMED_OUT    = 0, /* per-probe timeout (.requestTimedOut)     */
  DART_PING_ERROR_TIME_TO_LIVE_EXCEEDED = 1, /* TTL/hop limit exceeded (.timeToLiveExceeded) */
  DART_PING_ERROR_NO_REPLY             = 2, /* run-level: nothing came back (.noReply)  */
  DART_PING_ERROR_UNKNOWN_HOST         = 3, /* name resolution miss (.unknownHost)      */
  DART_PING_ERROR_NO_ROUTE             = 4, /* address-family/route problem (.noRoute)  */
  DART_PING_ERROR_UNKNOWN              = 5  /* catch-all (.unknown)                     */
} dart_ping_error_kind;

/*
 * The IP address family a run resolves AND sends for, mirroring Swift
 * `IPFamily`. Passed into `dart_ping_start` as the `family` argument.
 */
typedef enum {
  DART_PING_FAMILY_V4 = 0, /* .v4 */
  DART_PING_FAMILY_V6 = 1  /* .v6 */
} dart_ping_family;

/*
 * Discriminator for the flat event struct: which `PingEngine.Event` case this
 * event carries. Read this FIRST, then read only the fields documented for that
 * kind (other fields are unspecified).
 */
typedef enum {
  DART_PING_EVENT_RESPONSE = 0, /* .response — fields: seq, has_ttl/ttl, time_micros, ip      */
  DART_PING_EVENT_ERROR    = 1, /* .error    — fields: error_kind, has_seq/seq, has_ip/ip     */
  DART_PING_EVENT_SUMMARY  = 2  /* .summary  — fields: transmitted, received, time_micros,
                                 *             errors/errors_len                              */
} dart_ping_event_kind;

/*
 * A single ping event, flattened from `PingEngine.Event`. Exactly one of the
 * three cases is active, selected by `kind`. Nullable Swift fields are carried
 * as a `has_*` boolean plus the value (or a possibly-NULL pointer for `ip`).
 *
 * LIFETIME (finalized by #28-2, §spec:ios-ffi-binding, §spec:ios-background-isolate):
 * each event is HEAP-ALLOCATED by the shim and OWNED BY THE RECEIVER. The shim
 * `malloc`s the struct and heap-copies its `ip` string and `errors` buffer, then
 * hands the pointer to the callback and does NOT free it. The receiver MUST copy
 * any fields it needs and then call `dart_ping_free_event` (below) to release
 * the struct and its `ip`/`errors` buffers — Swift frees what Swift allocated.
 *
 * This ownership transfer is what makes the asynchronous `NativeCallable.listen`
 * delivery in #28-2 safe: under `.listen` the C call returns immediately (the
 * event is queued) and the Dart handler runs LATER, so the payload must outlive
 * the call rather than living in a callback-scoped stack buffer.
 */
typedef struct {
  dart_ping_event_kind kind; /* which case is active (read this first) */

  /* ── .response (and shared with .error for `seq`/`ip`) ─────────────────── */

  /* Sequence number.
   *   .response: always present (the probe's seq), `seq` holds it.
   *   .error:    `has_seq` is false for run-level errors (resolution / socket /
   *              noReply with seq == nil); true for per-probe errors, with the
   *              probe's seq in `seq`. (For .response treat `seq` as always valid.)
   */
  bool    has_seq;
  int64_t seq;

  /* Reply hop limit (TTL for v4 / hop limit for v6), ONLY for .response.
   * Nullable because a v6 reply may lack an IPV6_HOPLIMIT cmsg: `has_ttl` is
   * false then ("unknown"), true otherwise with the value in `ttl`. */
  bool    has_ttl;
  int64_t ttl;

  /* Microsecond magnitude:
   *   .response: round-trip time (microseconds), full resolution preserved
   *              across the seam (§spec:stats-precision).
   *   .summary:  engine-measured session wall-clock duration (microseconds) —
   *              NOT a sum of RTTs (§spec:stats-event-model).
   * Unspecified for .error. */
  int64_t time_micros;

  /* Source IP as a NUL-terminated UTF-8 C string.
   *   .response: the responder's address, always present.
   *   .error:    `has_ip` is false (and `ip` may be NULL) for errors with no
   *              source address (e.g. timeouts, resolution failures); true with
   *              a non-NULL `ip` when a source is known (e.g. a Time Exceeded
   *              from an intermediate hop).
   * The pointer (when non-NULL) is valid only for the callback's duration. */
  bool        has_ip;
  const char *ip;

  /* ── .error ───────────────────────────────────────────────────────────── */

  /* The error classification; only meaningful when kind == DART_PING_EVENT_ERROR. */
  dart_ping_error_kind error_kind;

  /* ── .summary ─────────────────────────────────────────────────────────── */

  int32_t transmitted; /* total probes sent                                    */
  int32_t received;    /* total replies matched                                */

  /* Every error kind emitted during the run, in emission order (the Swift
   * `summary(errors:)` array). `errors` points at `errors_len` contiguous
   * `int32_t` values, each a `dart_ping_error_kind`. `errors` may be NULL when
   * `errors_len` is 0. Valid only for the callback's duration. */
  const int32_t *errors;
  int32_t        errors_len;
} dart_ping_event;

/*
 * Event callback. Invoked from the engine's BACKGROUND dispatch queue, once per
 * emitted event, in emission order, terminated by a single .summary event.
 *
 *   context: the opaque pointer passed to dart_ping_start, forwarded verbatim.
 *   event:   a pointer to a HEAP-ALLOCATED dart_ping_event whose OWNERSHIP is
 *            transferred to the receiver (see the struct's LIFETIME note). The
 *            receiver MUST copy what it needs and then call
 *            `dart_ping_free_event(event)` to release the struct and its
 *            `ip`/`errors` buffers. The pointer remains valid until then.
 *
 * The Dart side (#28-2) bridges this to its isolate via a
 * `NativeCallable.listen` (§spec:ios-background-isolate, §spec:ios-ffi-binding),
 * which is why ownership is transferred rather than scoped to the call.
 */
typedef void (*dart_ping_event_callback)(void *context, const dart_ping_event *event);

/*
 * Free a heap-allocated event previously delivered to a dart_ping_event_callback
 * (§spec:ios-ffi-binding). The receiver calls this once it has copied the fields
 * it needs: it frees the event's `ip` string (if non-NULL) and `errors` buffer
 * (if non-NULL), then the event struct itself. Allocator-symmetric with the
 * shim's `malloc`/`strdup`. A NULL event is ignored. After this call the event
 * pointer (and its `ip`/`errors` pointers) are INVALID — do not reuse them.
 */
void dart_ping_free_event(const dart_ping_event *event);

/*
 * Opaque handle to a running ping. Returned by dart_ping_start, passed to
 * dart_ping_stop. NULL signals a failed start (see below).
 */
typedef void *dart_ping_handle;

/*
 * Start a ping run. Builds a PingEngine.Config from these arguments, constructs
 * the engine with a marshalling onEvent that drives `callback`, starts it, and
 * returns a retained handle. Events begin arriving on `callback` (background
 * queue) before this returns or shortly after.
 *
 *   host:            target host or IP literal, NUL-terminated UTF-8. Must be
 *                    non-NULL (a NULL host returns a NULL handle).
 *   count:           number of probes; < 0 means UNLIMITED (maps to Swift
 *                    Config.count == nil — run until dart_ping_stop).
 *   interval_seconds: seconds between probes (Swift TimeInterval).
 *   timeout_seconds:  seconds to wait for each reply (Swift TimeInterval).
 *   ttl:             outgoing hop limit (IP_TTL / IPV6_UNICAST_HOPS).
 *   family:          a dart_ping_family value selecting the resolve/send family.
 *   nat64_synthesis: when true, relaxes #69's pinned resolve for an IPv4-literal
 *                    host so the platform may synthesize a NAT64 address
 *                    (§spec:nat64-literal-synthesis / §spec:nat64-option).
 *   callback:        the per-event callback. Must be non-NULL (a NULL callback
 *                    returns a NULL handle).
 *   context:         opaque pointer forwarded to every `callback` invocation.
 *
 * Returns an opaque handle, or NULL if `host` or `callback` is NULL.
 */
dart_ping_handle dart_ping_start(const char *host,
                                 int64_t count,
                                 double interval_seconds,
                                 double timeout_seconds,
                                 int64_t ttl,
                                 int32_t family,
                                 bool nat64_synthesis,
                                 dart_ping_event_callback callback,
                                 void *context);

/*
 * Stop a ping run and release its handle. Calls the engine's stop() (which still
 * emits a terminal .summary for what completed) and deallocates the handle's
 * retained box. After this call the handle is INVALID — do not reuse it. NULL is
 * ignored.
 *
 * LIFECYCLE CAVEAT (finalized by #28-2, §spec:ios-ffi-binding): the engine may
 * still deliver an ALREADY-QUEUED event on its background queue after stop()
 * returns (e.g. the terminal summary). This shim does NOT guard against a
 * post-stop callback — the Dart side must keep its NativeCallable alive until it
 * observes the terminal summary / closes the stream.
 */
void dart_ping_stop(dart_ping_handle handle);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* DART_PING_FFI_H */

import 'package:dart_ping/dart_ping.dart';

/// Which native event case this DTO carries (mirrors `dart_ping_event_kind`).
enum NativeEventKind { response, error, summary }

/// Native error classification (mirrors `dart_ping_error_kind` / [ErrorType]).
enum NativeErrorKind {
  requestTimedOut,
  timeToLiveExceeded,
  noReply,
  unknownHost,
  noRoute,
  unknown,
}

/// Decoded, FFI-free view of one native ping event. WS2 builds this from the
/// `DartPingEvent` C struct; this seam stays pure Dart so it is unit-testable
/// without a native asset (§spec:ios-ffi-binding).
///
/// Fields mirror the C ABI's optional flags: [seq] is null when the struct's
/// `has_seq` is false, [ttl] is null when `has_ttl` is false (responses only),
/// and [ip] is null when `has_ip` is false. [timeMicros] carries the round-trip
/// time in microseconds for a response, or the session duration in microseconds
/// for a summary (§spec:stats-precision). [transmitted]/[received]/[errors] are
/// summary-only; [errorKind] is error-only.
///
/// Unlike the old channel `Map`, there is no `message` field: the C ABI carries
/// only an error *kind*, so [PingError.message] is null on this path.
class NativePingEvent {
  final NativeEventKind kind;

  final int? seq; // null when the C struct's has_seq is false
  final int? ttl; // null when has_ttl is false (response only)
  final int timeMicros; // response: RTT µs; summary: session µs
  final String? ip; // null when has_ip is false
  final NativeErrorKind? errorKind; // error events only
  final int transmitted; // summary only
  final int received; // summary only
  final List<NativeErrorKind> errors; // summary only, in emission order

  const NativePingEvent({
    required this.kind,
    this.seq,
    this.ttl,
    this.timeMicros = 0,
    this.ip,
    this.errorKind,
    this.transmitted = 0,
    this.received = 0,
    this.errors = const [],
  });
}

/// Direct 1:1 map from the native error kind to the cross-platform [ErrorType].
///
/// There is no message-string parsing here (the old channel path inferred the
/// type from a native string via `ErrorType.fromMessage`); the typed enum
/// carries the classification directly, so the mapping is exhaustive and total.
/// A `noRoute` kind stays [ErrorType.noRoute] — distinct from
/// [ErrorType.unknownHost] — so the honest NAT64 / address-family error survives
/// (§spec:nat64-error-fallback, §spec:address-family-error-honesty).
ErrorType _errorTypeFor(NativeErrorKind kind) {
  switch (kind) {
    case .requestTimedOut:
      return .requestTimedOut;

    case .timeToLiveExceeded:
      return .timeToLiveExceeded;

    case .noReply:
      return .noReply;

    case .unknownHost:
      return .unknownHost;

    case .noRoute:
      return .noRoute;

    case .unknown:
      return .unknown;
  }
}

/// Pure, testable mapping seam between a decoded native FFI event and the sealed
/// [PingEvent] union.
///
/// Translates a single [NativePingEvent] DTO — built by WS2 from the
/// `DartPingEvent` C struct — into the corresponding cross-platform [PingEvent]
/// variant ([PingResponse], [PingError], or [PingSummary]).
///
/// The round-trip / session [timeMicros] is carried in **microseconds** and
/// converted with full precision; it is never rounded to whole milliseconds
/// (§spec:stats-precision).
///
/// A `response` event maps to a [PingResponse]. An `error` event maps to a
/// single [PingError]: because [PingError] carries `seq`/`ip` natively, a
/// timed-out or TTL-exceeded probe is one [PingError] with its `seq`/`ip`
/// populated — there is no combined response+error pairing. This mirrors how the
/// core subprocess parser emits per-probe errors (§spec:ios-error-parity,
/// §spec:ios-ttl). [PingError.message] is always null here: the C ABI carries
/// only an error kind, not a message string.
///
/// A `summary` event maps to a [PingSummary] whose `errors` list is the decoded
/// `errors` in emission order. The session time is treated as **absent (null)
/// when [NativePingEvent.timeMicros] is 0** — the engine reports a real session
/// duration, so a zero effectively means "no time".
///
/// Unlike the old channel mapper, this never returns null: there is no
/// unknown-`type` escape, because [NativeEventKind] makes an unmappable event
/// unrepresentable. This produces a BARE event with no `stats`; the running
/// [RoundTripStats] snapshot is layered on by [NativeEventStatsMapper].
PingEvent mapNativeEvent(NativePingEvent ev) {
  switch (ev.kind) {
    case .response:
      return PingResponse(
        seq: ev.seq,
        ttl: ev.ttl,
        time: Duration(microseconds: ev.timeMicros),
        ip: ev.ip,
      );

    case .error:
      // A per-probe timeout / TTL-exceeded error is a single PingError that
      // identifies its own probe via seq/ip. There is no message on the FFI
      // wire, so PingError.message stays null. An `.error` event always carries
      // an errorKind by the native ABI's contract.
      // ignore: avoid-non-null-assertion
      return PingError(_errorTypeFor(ev.errorKind!), seq: ev.seq, ip: ev.ip);

    case .summary:
      return PingSummary(
        transmitted: ev.transmitted,
        received: ev.received,
        // timeMicros == 0 means the engine reported no session duration.
        time: ev.timeMicros == 0 ? null : Duration(microseconds: ev.timeMicros),
        errors: ev.errors.map((k) => PingError(_errorTypeFor(k))).toList(),
      );
  }
}

/// Stateful seam that layers a running [RoundTripStats] snapshot onto each
/// mapped native event, reusing the core [RoundTripStatsAccumulator]
/// (§spec:stats-ios / §spec:stats-cross-platform).
///
/// Create one per run. [map] calls [mapNativeEvent] to get a bare [PingEvent],
/// then mirrors `BasePing._onListen` EXACTLY: it feeds each successful reply's
/// round-trip time into the accumulator and stamps every probe event and the
/// terminal summary with `_acc.snapshot()`. Because the live snapshot and the
/// summary's final figures both come from this one accumulator — the same type
/// and math the core subprocess path uses — iOS round-trip statistics match
/// core by construction (no parallel computation). Errors do NOT contribute to
/// the RTT figures, matching the core path.
///
/// This is a pure, FFI-free seam: it has no Flutter/native dependency, so it can
/// be unit-tested directly by feeding it [NativePingEvent] DTOs.
class NativeEventStatsMapper {
  final _acc = RoundTripStatsAccumulator();

  /// Maps one decoded native event to a [PingEvent] carrying the running stats
  /// snapshot. Never returns null — [NativeEventKind] is exhaustive.
  PingEvent map(NativePingEvent ev) {
    final event = mapNativeEvent(ev);
    switch (event) {
      case PingResponse r:
        // Successful reply: fold its RTT into the accumulator FIRST so the
        // snapshot (and thus the terminal summary, built from the same
        // accumulator) includes this reply (§spec:stats-live).
        final rtt = r.time;
        if (rtt != null) _acc.add(rtt);

        return r.copyWith(stats: _acc.snapshot());

      case PingError e:
        // Errors don't contribute to RTT figures; stamp the current snapshot.
        return e.copyWith(stats: _acc.snapshot());

      case PingSummary s:
        // Finalize the terminal summary's stats from the same accumulator.
        return s.copyWith(stats: _acc.snapshot());
    }
  }
}

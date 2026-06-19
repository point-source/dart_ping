import 'package:dart_ping/dart_ping.dart';

/// Pure, testable mapping seam between native channel events and the sealed
/// [PingEvent] union.
///
/// Translates a single Map event emitted by the native Swift ICMP engine
/// (over the `dart_ping_ios/events` [EventChannel]) into the corresponding
/// cross-platform [PingEvent] variant ([PingResponse], [PingError], or
/// [PingSummary]).
///
/// The native event keys (`seq`/`ttl`/`time`/`ip`, `transmitted`/`received`,
/// `error`/`errors`) deliberately match the `fromMap` contract of the
/// `dart_ping` models, so each branch delegates to the variant's own factory
/// rather than re-implementing the parsing/coercion here. The `time` field is
/// carried in **microseconds** on the channel, exactly as `PingResponse.fromMap`
/// / `PingSummary.fromMap` decode it (§spec:stats-precision).
///
/// A `response` event maps to a [PingResponse]. An `error` event maps to a
/// single [PingError]: because [PingError] now carries `seq`/`ip` natively, a
/// timed-out or TTL-exceeded probe is one [PingError] with its `seq`/`ip`
/// populated — there is no longer a combined response+error pairing. This
/// mirrors how the core subprocess parser emits per-probe errors
/// (§spec:ios-error-parity).
///
/// A `summary` event passes its `errors` list straight through to
/// [PingSummary.fromMap], which builds the accumulated [PingError] list.
///
/// Returns `null` for events that cannot be mapped (unknown `type`), so
/// callers can simply drop them. This produces a BARE event with no `stats`;
/// the running [RoundTripStats] snapshot is layered on by
/// [NativeEventStatsMapper].
PingEvent? mapNativeEvent(Map<dynamic, dynamic> event) {
  // Channel codecs deliver Map<dynamic, dynamic>; the model factories expect
  // Map<String, dynamic>. Channel keys are always strings, so this is safe.
  final map = Map<String, dynamic>.from(event);
  switch (map['type']) {
    case 'response':
      return PingResponse.fromMap(map);
    case 'error':
      // PingError.fromMap reads `seq`/`ip`/`message`/`error`, so a per-probe
      // timeout / TTL-exceeded error is a single PingError that identifies its
      // own probe.
      return PingError.fromMap(map);
    case 'summary':
      // The platform codec delivers the nested `errors` entries as
      // Map<Object?, Object?>, but PingError.fromMap (reached via
      // PingSummary.fromMap) requires Map<String, dynamic>. The top-level
      // Map.from above is shallow, so deep-convert each error entry here;
      // otherwise any summary carrying an error throws a TypeError.
      final errors = map['errors'];
      if (errors is List) {
        map['errors'] = errors
            .map<Map<String, dynamic>>(
                (e) => Map<String, dynamic>.from(e as Map))
            .toList();
      }
      return PingSummary.fromMap(map);
    default:
      return null;
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
/// This is a pure, channel-free seam: it has no Flutter/channel dependency, so
/// it can be unit-tested directly by feeding it raw native maps.
class NativeEventStatsMapper {
  final RoundTripStatsAccumulator _acc = RoundTripStatsAccumulator();

  /// Maps one native event map to a [PingEvent] carrying the running stats
  /// snapshot, or `null` when the event cannot be mapped.
  PingEvent? map(Map<dynamic, dynamic> event) {
    final ev = mapNativeEvent(event);
    switch (ev) {
      case PingResponse r:
        // Successful reply: fold its RTT into the accumulator FIRST so the
        // snapshot (and thus the terminal summary, built from the same
        // accumulator) includes this reply (§spec:stats-live).
        if (r.time != null) _acc.add(r.time!);
        return r.copyWith(stats: _acc.snapshot());
      case PingError e:
        // Errors don't contribute to RTT figures; stamp the current snapshot.
        return e.copyWith(stats: _acc.snapshot());
      case PingSummary s:
        // Finalize the terminal summary's stats from the same accumulator.
        return s.copyWith(stats: _acc.snapshot());
      case null:
        return null;
    }
  }
}

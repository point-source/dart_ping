library;

import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:dart_ping/src/models/round_trip_stats.dart';

part 'ping_response.dart';
part 'ping_error.dart';
part 'ping_summary.dart';

/// Sealed union of everything a ping run emits on its stream: a successful
/// probe [PingResponse], a probe/run [PingError], or the terminal [PingSummary].
/// Consumers branch with an exhaustive `switch`; the terminal summary is the
/// final event and is identifiable by type alone (`is PingSummary`).
sealed class PingEvent {
  /// Round-trip statistics associated with this event, or null when none apply.
  ///
  /// On a probe event ([PingResponse] / [PingError]) this is the **running**
  /// snapshot over all successful replies seen so far in the run
  /// (§spec:stats-live); on the terminal [PingSummary] it is the run's final
  /// figures (§spec:stats-summary). Exposing it on the base lets a consumer
  /// read `event.stats` off any event without a type switch — and because the
  /// last probe snapshot equals the summary's, the figures are consistent
  /// throughout the run. Null on events not produced by a live run path (e.g. a
  /// bare parsed/deserialized event).
  RoundTripStats? get stats;

  const PingEvent();

  /// Reconstructs the correct variant from its serialized form using the
  /// `'type'` discriminator each variant writes.
  factory PingEvent.fromMap(Map<String, dynamic> map) {
    switch (map['type']) {
      case 'response':
        return PingResponse.fromMap(map);

      case 'error':
        return PingError.fromMap(map);

      case 'summary':
        return PingSummary.fromMap(map);

      default:
        throw ArgumentError('Unknown PingEvent type: ${map['type']}');
    }
  }

  factory PingEvent.fromJson(String source) {
    // `json.decode` returns `dynamic`; the typed local is an implicit downcast
    // (it still throws on a non-object payload) without an explicit `as` cast.
    final Map<String, dynamic> map = json.decode(source);

    return PingEvent.fromMap(map);
  }

  /// Serializes this event to a map. Each variant writes a `'type'`
  /// discriminator (`'response'` / `'error'` / `'summary'`) so
  /// [PingEvent.fromMap] can reconstruct the correct variant.
  Map<String, dynamic> toMap();

  String toJson() => json.encode(toMap());
}

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
  const PingEvent();

  /// Serializes this event to a map. Each variant writes a `'type'`
  /// discriminator (`'response'` / `'error'` / `'summary'`) so
  /// [PingEvent.fromMap] can reconstruct the correct variant.
  Map<String, dynamic> toMap();

  String toJson() => json.encode(toMap());

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

  factory PingEvent.fromJson(String source) =>
      PingEvent.fromMap(json.decode(source) as Map<String, dynamic>);
}

/// Decodes a serialized round-trip duration (stored in **microseconds** to
/// preserve sub-millisecond precision) back into a [Duration], or null when the
/// field is absent. Shared by the [PingResponse] / [PingSummary] `fromMap`s so
/// the microsecond convention has a single home.
Duration? _durationFromMicros(dynamic value) =>
    value == null ? null : Duration(microseconds: (value as num).toInt());

import 'package:dart_ping/dart_ping.dart';

/// Pure, testable mapping seam between native channel events and [PingData].
///
/// Translates a single Map event emitted by the native Swift ICMP engine
/// (over the `dart_ping_ios/events` [EventChannel]) into the corresponding
/// cross-platform [PingData] model.
///
/// The native event keys (`seq`/`ttl`/`time`/`ip`, `transmitted`/`received`,
/// `error`) deliberately match the `fromMap` contract of the `dart_ping`
/// models, so each branch delegates to the model's own factory rather than
/// re-implementing the parsing/coercion here.
///
/// Returns `null` for events that cannot be mapped (unknown `type`), so
/// callers can simply drop them.
PingData? mapNativeEvent(Map<dynamic, dynamic> event) {
  // Channel codecs deliver Map<dynamic, dynamic>; the model factories expect
  // Map<String, dynamic>. Channel keys are always strings, so this is safe.
  final map = Map<String, dynamic>.from(event);
  switch (map['type']) {
    case 'response':
      return PingData(response: PingResponse.fromMap(map));
    case 'error':
      return PingData(error: PingError.fromMap(map));
    case 'summary':
      return PingData(summary: PingSummary.fromMap(map));
    default:
      return null;
  }
}

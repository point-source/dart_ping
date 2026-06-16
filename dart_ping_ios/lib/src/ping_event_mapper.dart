import 'package:dart_ping/dart_ping.dart';

/// Pure, testable mapping seam between native channel events and [PingData].
///
/// Translates a single Map event emitted by the native Swift ICMP engine
/// (over the `dart_ping_ios/events` [EventChannel]) into the corresponding
/// cross-platform [PingData] model.
///
/// The native event keys (`seq`/`ttl`/`time`/`ip`, `transmitted`/`received`,
/// `error`/`errors`) deliberately match the `fromMap` contract of the
/// `dart_ping` models, so each branch delegates to the model's own factory
/// rather than re-implementing the parsing/coercion here.
///
/// An `error` event that carries per-probe context (`seq` or `ip`) is mapped
/// to a combined response + error, mirroring how the CLI platforms emit a
/// single [PingData] with both a [PingResponse] and a [PingError] for
/// timeouts and TTL-exceeded probes. Errors without per-probe context (e.g.
/// `Unknown Host`, `Unknown Error`) map to an error-only [PingData].
///
/// A `summary` event passes its `errors` list straight through to
/// [PingSummary.fromMap], which builds the accumulated [PingError] list.
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
      final hasResponse = map['seq'] != null || map['ip'] != null;
      return PingData(
        response: hasResponse ? PingResponse.fromMap(map) : null,
        error: PingError.fromMap(map),
      );
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
      return PingData(summary: PingSummary.fromMap(map));
    default:
      return null;
  }
}

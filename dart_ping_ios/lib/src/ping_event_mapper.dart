import 'package:dart_ping/dart_ping.dart';

/// Pure, testable mapping seam between native channel events and [PingData].
///
/// Translates a single Map event emitted by the native Swift ICMP engine
/// (over the `dart_ping_ios/events` [EventChannel]) into the corresponding
/// cross-platform [PingData] model.
///
/// Returns `null` for events that cannot be mapped (unknown `type`, or
/// missing required fields), so callers can simply drop them.
PingData? mapNativeEvent(Map<dynamic, dynamic> event) {
  final type = event['type'];
  switch (type) {
    case 'response':
      return PingData(
        response: PingResponse(
          seq: _asInt(event['seq']),
          ttl: _asInt(event['ttl']),
          time: event['time'] != null
              ? Duration(milliseconds: _asInt(event['time'])!)
              : null,
          ip: event['ip'] as String?,
        ),
      );
    case 'error':
      return PingData(
        error: PingError(
          ErrorType.fromMessage(event['error'] as String? ?? ''),
        ),
      );
    case 'summary':
      return PingData(
        summary: PingSummary(
          transmitted: _asInt(event['transmitted']) ?? 0,
          received: _asInt(event['received']) ?? 0,
          time: event['time'] != null
              ? Duration(milliseconds: _asInt(event['time'])!)
              : null,
        ),
      );
    default:
      return null;
  }
}

/// Defensively coerce a channel-supplied numeric value to an `int`.
///
/// Method/event channel codecs may deliver numbers as `int` (the common
/// case) or, in some configurations, `double`; both are handled here.
int? _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return null;
}

import 'package:dart_ping/dart_ping.dart';
import 'package:dart_ping_ios/src/ping_event_mapper.dart';
import 'package:test/test.dart';

void main() {
  group('mapNativeEvent', () {
    test('maps a response event to PingData.response', () {
      final data = mapNativeEvent({
        'id': 'run-1',
        'type': 'response',
        'seq': 3,
        'ttl': 55,
        'time': 12,
        'ip': '1.2.3.4',
      });

      expect(data, isNotNull);
      expect(data!.error, isNull);
      expect(data.summary, isNull);

      final response = data.response!;
      expect(response.seq, 3);
      expect(response.ttl, 55);
      expect(response.time, const Duration(milliseconds: 12));
      expect(response.ip, '1.2.3.4');
    });

    test('maps a requestTimedOut error event with a response (seq)', () {
      final data = mapNativeEvent({
        'id': 'run-1',
        'type': 'error',
        'error': 'Request Timed Out',
        'seq': 4,
      });

      expect(data, isNotNull);
      expect(data!.error!.error, ErrorType.requestTimedOut);
      // A timed-out probe still carries a sequence, so a response is attached.
      expect(data.response, isNotNull);
      expect(data.response!.seq, 4);
    });

    test('maps a timeToLiveExceeded error event with a response (seq, ip)',
        () {
      final data = mapNativeEvent({
        'id': 'run-1',
        'type': 'error',
        'error': 'Time To Live Exceeded',
        'seq': 7,
        'ip': '10.0.0.1',
      });

      expect(data, isNotNull);
      expect(data!.error!.error, ErrorType.timeToLiveExceeded);
      expect(data.response, isNotNull);
      expect(data.response!.seq, 7);
      expect(data.response!.ip, '10.0.0.1');
      // TTL-exceeded carries no round-trip time.
      expect(data.response!.time, isNull);
    });

    test('maps an unknownHost error event without a response', () {
      final data = mapNativeEvent({
        'id': 'run-1',
        'type': 'error',
        'error': 'Unknown Host',
      });

      expect(data, isNotNull);
      expect(data!.error!.error, ErrorType.unknownHost);
      // No per-probe context (no seq/ip), so no response is attached.
      expect(data.response, isNull);
    });

    test('maps an unknown error event via the catch-all', () {
      final data = mapNativeEvent({
        'id': 'run-1',
        'type': 'error',
        'error': 'Unknown Error',
      });

      expect(data, isNotNull);
      expect(data!.error!.error, ErrorType.unknown);
    });

    test('maps a summary event WITH a time', () {
      final data = mapNativeEvent({
        'id': 'run-1',
        'type': 'summary',
        'transmitted': 5,
        'received': 4,
        'time': 5000,
      });

      expect(data, isNotNull);
      final summary = data!.summary!;
      expect(summary.transmitted, 5);
      expect(summary.received, 4);
      expect(summary.time, const Duration(milliseconds: 5000));
      expect(summary.errors, isEmpty);
    });

    test('maps a summary event WITHOUT a time (null)', () {
      final data = mapNativeEvent({
        'id': 'run-1',
        'type': 'summary',
        'transmitted': 2,
        'received': 0,
        'time': null,
      });

      expect(data, isNotNull);
      final summary = data!.summary!;
      expect(summary.transmitted, 2);
      expect(summary.received, 0);
      expect(summary.time, isNull);
      expect(summary.errors, isEmpty);
    });

    test('maps a summary event carrying a noReply error', () {
      final data = mapNativeEvent({
        'id': 'run-1',
        'type': 'summary',
        'transmitted': 3,
        'received': 2,
        'time': 3000,
        'errors': [
          {'error': 'No Reply', 'message': null},
        ],
      });

      expect(data, isNotNull);
      final summary = data!.summary!;
      expect(summary.errors, hasLength(1));
      expect(summary.errors.first.error, ErrorType.noReply);
    });

    test('maps a summary event carrying a mix of errors', () {
      final data = mapNativeEvent({
        'id': 'run-1',
        'type': 'summary',
        'transmitted': 5,
        'received': 3,
        'time': 5000,
        'errors': [
          {'error': 'Request Timed Out', 'message': null},
          {'error': 'No Reply', 'message': null},
        ],
      });

      expect(data, isNotNull);
      final summary = data!.summary!;
      expect(summary.transmitted, 5);
      expect(summary.received, 3);
      expect(summary.errors, hasLength(2));
      expect(
        summary.errors.map((e) => e.error),
        containsAll(<ErrorType>[
          ErrorType.requestTimedOut,
          ErrorType.noReply,
        ]),
      );
    });

    test('returns null for an unknown type', () {
      final data = mapNativeEvent({
        'id': 'run-1',
        'type': 'something-else',
      });

      expect(data, isNull);
    });

    // --- §spec:ios-error-parity: standalone error-event ErrorType coverage ---

    test('maps a standalone noReply error event without a response', () {
      // 'No Reply' rounds out the full ErrorType set as a standalone `error`
      // event (the existing suite only exercised it inside a summary).
      final data = mapNativeEvent({
        'id': 'run-1',
        'type': 'error',
        'error': 'No Reply',
      });

      expect(data, isNotNull);
      expect(data!.error!.error, ErrorType.noReply);
      // No per-probe context (no seq/ip), so no response is attached.
      expect(data.response, isNull);
    });

    test('carries the native message string through to PingError.message', () {
      // The mapper delegates to PingError.fromMap, which preserves `message`.
      final data = mapNativeEvent({
        'id': 'run-1',
        'type': 'error',
        'error': 'Unknown Error',
        'message': 'socket failure',
      });

      expect(data, isNotNull);
      expect(data!.error!.error, ErrorType.unknown);
      expect(data.error!.message, 'socket failure');
    });

    // --- §spec:ios-error-parity: combined response + error edge cases ---

    test('error event with ip but no seq still attaches a response', () {
      // hasResponse is `seq != null || ip != null`, so an ip alone is enough
      // to attach a (seq-less) response alongside the error.
      final data = mapNativeEvent({
        'id': 'run-1',
        'type': 'error',
        'error': 'Time To Live Exceeded',
        'ip': '192.168.1.1',
      });

      expect(data, isNotNull);
      expect(data!.error!.error, ErrorType.timeToLiveExceeded);
      expect(data.response, isNotNull);
      expect(data.response!.ip, '192.168.1.1');
      expect(data.response!.seq, isNull);
    });

    test('error event with seq but no ip attaches a response with null ip', () {
      final data = mapNativeEvent({
        'id': 'run-1',
        'type': 'error',
        'error': 'Request Timed Out',
        'seq': 9,
      });

      expect(data, isNotNull);
      expect(data!.error!.error, ErrorType.requestTimedOut);
      expect(data.response, isNotNull);
      expect(data.response!.seq, 9);
      // No ip provided, so the attached response carries a null ip.
      expect(data.response!.ip, isNull);
    });

    // --- response event optional-field handling (PingResponse.fromMap) ---

    test('maps a response event missing ttl/time/ip without throwing', () {
      // PingResponse.fromMap tolerates absent optional fields, producing nulls.
      final data = mapNativeEvent({
        'id': 'run-1',
        'type': 'response',
        'seq': 1,
      });

      expect(data, isNotNull);
      final response = data!.response!;
      expect(response.seq, 1);
      expect(response.ttl, isNull);
      expect(response.time, isNull);
      expect(response.ip, isNull);
    });

    test('maps a response event with explicit null optional fields', () {
      final data = mapNativeEvent({
        'id': 'run-1',
        'type': 'response',
        'seq': 2,
        'ttl': null,
        'time': null,
        'ip': null,
      });

      expect(data, isNotNull);
      final response = data!.response!;
      expect(response.seq, 2);
      expect(response.ttl, isNull);
      expect(response.time, isNull);
      expect(response.ip, isNull);
    });

    // --- §spec:ios-tests: summary errors-list population ---

    test('maps a summary carrying the full mixed ErrorType set in order', () {
      final data = mapNativeEvent({
        'id': 'run-1',
        'type': 'summary',
        'transmitted': 5,
        'received': 0,
        'time': 5000,
        'errors': [
          {'error': 'Time To Live Exceeded', 'message': null},
          {'error': 'Request Timed Out', 'message': null},
          {'error': 'Unknown Host', 'message': null},
          {'error': 'No Reply', 'message': null},
          {'error': 'Unknown Error', 'message': null},
        ],
      });

      expect(data, isNotNull);
      final summary = data!.summary!;
      expect(summary.errors, hasLength(5));
      // Order is preserved straight from the native errors list.
      expect(
        summary.errors.map((e) => e.error).toList(),
        <ErrorType>[
          ErrorType.timeToLiveExceeded,
          ErrorType.requestTimedOut,
          ErrorType.unknownHost,
          ErrorType.noReply,
          ErrorType.unknown,
        ],
      );
    });

    test('maps a summary with an explicitly empty errors list to []', () {
      // An empty list is still a List, so it hits the parsing branch and
      // yields an empty (not null) errors list.
      final data = mapNativeEvent({
        'id': 'run-1',
        'type': 'summary',
        'transmitted': 3,
        'received': 3,
        'time': 3000,
        'errors': <dynamic>[],
      });

      expect(data, isNotNull);
      final summary = data!.summary!;
      expect(summary.errors, isNotNull);
      expect(summary.errors, isEmpty);
    });

    // --- Map<dynamic, dynamic> -> Map<String, dynamic> coercion path ---

    test('coerces a genuine Map<dynamic, dynamic> event from the codec', () {
      // Channel codecs deliver dynamic-keyed maps; mapNativeEvent must coerce
      // them. Build a real Map<dynamic, dynamic> (not an inferred String map).
      final Map<dynamic, dynamic> event = <dynamic, dynamic>{
        'id': 'run-1',
        'type': 'response',
        'seq': 6,
        'ttl': 64,
        'time': 21,
        'ip': '8.8.8.8',
      };

      final data = mapNativeEvent(event);

      expect(data, isNotNull);
      final response = data!.response!;
      expect(response.seq, 6);
      expect(response.ttl, 64);
      expect(response.time, const Duration(milliseconds: 21));
      expect(response.ip, '8.8.8.8');
    });
  });
}

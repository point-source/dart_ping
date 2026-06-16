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
  });
}

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

    test('maps a requestTimedOut error event', () {
      final data = mapNativeEvent({
        'id': 'run-1',
        'type': 'error',
        'error': 'Request Timed Out',
        'seq': 4,
      });

      expect(data, isNotNull);
      expect(data!.error!.error, ErrorType.requestTimedOut);
    });

    test('maps an unknownHost error event', () {
      final data = mapNativeEvent({
        'id': 'run-1',
        'type': 'error',
        'error': 'Unknown Host',
      });

      expect(data, isNotNull);
      expect(data!.error!.error, ErrorType.unknownHost);
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

    test('returns null for an unknown type', () {
      final data = mapNativeEvent({
        'id': 'run-1',
        'type': 'something-else',
      });

      expect(data, isNull);
    });
  });
}

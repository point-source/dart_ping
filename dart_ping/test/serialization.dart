import 'package:dart_ping/dart_ping.dart';
import 'package:test/test.dart';

void main() {
  group('Serialization', () {
    final pingError = PingError(ErrorType.requestTimedOut, message: 'Test');
    final pingResponse = PingResponse(
      seq: 2,
      ttl: 5,
      time: Duration(milliseconds: 8),
      ip: '127.0.0.1',
    );
    final pingSummary = PingSummary(
      transmitted: 43,
      received: 8,
      time: Duration(milliseconds: 3957),
      errors: [pingError],
    );

    test('PingError', () {
      final json = pingError.toJson();
      expect(json, equals('{"error":"Request Timed Out","message":"Test"}'));
      final deserialized = PingError.fromJson(json);
      expect(deserialized, equals(pingError));
    });
    test('PingResponse to JSON', () {
      final json = pingResponse.toJson();
      expect(json, equals('{"seq":2,"ttl":5,"time":8,"ip":"127.0.0.1"}'));
      final deserialized = PingResponse.fromJson(json);
      expect(deserialized, equals(pingResponse));
    });
    test('PingSummary to JSON', () {
      final json = pingSummary.toJson();
      expect(
        json,
        equals(
          '{"transmitted":43,"received":8,"time":3957,"errors":[{"error":"Request Timed Out","message":"Test"}]}',
        ),
      );
      final deserialized = PingSummary.fromJson(json);
      expect(deserialized, equals(pingSummary));
    });
    test('PingData to JSON', () {
      final pingData = PingData(
        response: pingResponse,
        summary: pingSummary,
        error: pingError,
      );
      final json = pingData.toJson();
      expect(
        json,
        equals(
          '{"response":{"seq":2,"ttl":5,"time":8,"ip":"127.0.0.1"},"summary":{"transmitted":43,"received":8,"time":3957,"errors":[{"error":"Request Timed Out","message":"Test"}]},"error":{"error":"Request Timed Out","message":"Test"}}',
        ),
      );
      final deserialized = PingData.fromJson(json);
      expect(deserialized, equals(pingData));
    });
  });
}

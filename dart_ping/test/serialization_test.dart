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
      expect(
        json,
        equals(
          '{"type":"error","error":"Request Timed Out","message":"Test","seq":null,"ip":null,"stats":null}',
        ),
      );
      final deserialized = PingError.fromJson(json);
      expect(deserialized, equals(pingError));
    });

    test('PingError with seq/ip', () {
      final err = PingError(
        ErrorType.timeToLiveExceeded,
        seq: 3,
        ip: '10.0.0.1',
      );
      final roundTripped = PingError.fromJson(err.toJson());
      expect(roundTripped, equals(err));
      expect(roundTripped.seq, 3);
      expect(roundTripped.ip, '10.0.0.1');
    });

    test('PingResponse to JSON', () {
      final json = pingResponse.toJson();
      expect(
        json,
        equals(
          '{"type":"response","seq":2,"ttl":5,"time":8,"ip":"127.0.0.1","stats":null}',
        ),
      );
      final deserialized = PingResponse.fromJson(json);
      expect(deserialized, equals(pingResponse));
    });

    test('PingSummary to JSON', () {
      final json = pingSummary.toJson();
      expect(
        json,
        equals(
          '{"type":"summary","transmitted":43,"received":8,"time":3957,"stats":null,"errors":[{"type":"error","error":"Request Timed Out","message":"Test","seq":null,"ip":null,"stats":null}]}',
        ),
      );
      final deserialized = PingSummary.fromJson(json);
      expect(deserialized, equals(pingSummary));
    });

    test('PingSummary with stats round-trips', () {
      final stats = RoundTripStats.fromSamples([
        const Duration(milliseconds: 1),
        const Duration(milliseconds: 3),
      ]);
      final summary = PingSummary(
        transmitted: 2,
        received: 2,
        stats: stats,
      );
      final deserialized = PingSummary.fromJson(summary.toJson());
      expect(deserialized, equals(summary));
      expect(deserialized.stats, equals(stats));
    });

    test('PingEvent.fromJson dispatches across variants', () {
      expect(PingEvent.fromJson(pingResponse.toJson()), isA<PingResponse>());
      expect(PingEvent.fromJson(pingError.toJson()), isA<PingError>());
      expect(PingEvent.fromJson(pingSummary.toJson()), isA<PingSummary>());
    });
  });
}
